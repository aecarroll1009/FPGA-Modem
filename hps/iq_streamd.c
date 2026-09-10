/* Drains iq_avalon_fifo over the lightweight HPS-to-FPGA bridge and sends
 * the samples on as UDP datagrams of interleaved little-endian int16 IQ,
 * which GNU Radio's udp_source consumes directly.
 *
 * Built for the board with the ARM toolchain, or natively against a
 * software model of the slave for the test in hps/Makefile.
 *
 *   iq_streamd --host 192.168.1.10 --port 5000 [--lo-hz 85000]
 *              [--rate full|decimated] [--pairs N]
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include "iq_regs.h"

/* 360 pairs is 1440 bytes, under the 1472 an untagged datagram fits in a
 * 1500-byte MTU. */
#define PAIRS_PER_DATAGRAM 360
#define BYTES_PER_DATAGRAM (PAIRS_PER_DATAGRAM * 4)

static volatile sig_atomic_t stop_requested = 0;

static void on_signal(int sig) { (void)sig; stop_requested = 1; }

static void nap_us(long us)
{
    struct timespec ts = { .tv_sec = 0, .tv_nsec = us * 1000L };
    nanosleep(&ts, NULL);
}

/* -- the bus ------------------------------------------------------------- */

#ifdef IQ_FAKE_BUS
#include "fake_bus.h"
#else

#include <fcntl.h>
#include <sys/mman.h>

static volatile uint32_t *regs;
static void       *map_base;
static int         mem_fd = -1;

static int bus_open(void)
{
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        fprintf(stderr, "open /dev/mem: %s (run as root)\n", strerror(errno));
        return -1;
    }
    map_base = mmap(NULL, IQ_LWBRIDGE_SPAN, PROT_READ | PROT_WRITE,
                    MAP_SHARED, mem_fd, IQ_LWBRIDGE_BASE);
    if (map_base == MAP_FAILED) {
        fprintf(stderr, "mmap the lightweight bridge: %s\n", strerror(errno));
        close(mem_fd);
        return -1;
    }
    regs = (volatile uint32_t *)((char *)map_base + IQ_SLAVE_OFFSET);
    return 0;
}

static void bus_close(void)
{
    if (map_base) munmap(map_base, IQ_LWBRIDGE_SPAN);
    if (mem_fd >= 0) close(mem_fd);
}

static inline uint32_t reg_read(int i)             { return regs[i]; }
static inline void     reg_write(int i, uint32_t v) { regs[i] = v; }

#endif /* IQ_FAKE_BUS */

/* -- tuning --------------------------------------------------------------- */

/* Fraction of the input rate, in PHASE_BITS of resolution. Negative and
 * out-of-band frequencies wrap. */
uint32_t iq_phase_inc(double lo_hz)
{
    double turns = lo_hz / IQ_FS_IN_HZ;
    double scale = (double)(1u << IQ_PHASE_BITS);
    double word  = floor(turns * scale + 0.5);

    word = fmod(word, scale);
    if (word < 0.0) word += scale;
    return (uint32_t)word;
}

/* -- main ----------------------------------------------------------------- */

static void usage(void)
{
    fprintf(stderr,
        "usage: iq_streamd --host ADDR [--port N] [--lo-hz F]\n"
        "                  [--rate full|decimated] [--pairs N]\n");
}

int main(int argc, char **argv)
{
    const char *host = NULL;
    int         port = 5000;
    double      lo_hz = -1.0;
    int         full_rate = 1;
    long        want_pairs = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc)       host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc)  port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--lo-hz") && i + 1 < argc) lo_hz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--pairs") && i + 1 < argc) want_pairs = atol(argv[++i]);
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc)  full_rate = !strcmp(argv[++i], "full");
        else { usage(); return 2; }
    }
    if (!host) { usage(); return 2; }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (bus_open() != 0) return 1;

    uint32_t id = reg_read(IQ_REG_ID);
    if (id != IQ_ID_CODE) {
        fprintf(stderr, "ID reads %08x, expected %08x -- wrong bitstream, or "
                        "the bridge is held in reset\n", id, IQ_ID_CODE);
        bus_close();
        return 1;
    }

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        fprintf(stderr, "socket: %s\n", strerror(errno));
        bus_close();
        return 1;
    }

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &dst.sin_addr) != 1) {
        fprintf(stderr, "bad --host address '%s'\n", host);
        close(sock);
        bus_close();
        return 1;
    }

    if (lo_hz >= 0.0) reg_write(IQ_REG_PHASE_INC, iq_phase_inc(lo_hz));

    reg_write(IQ_REG_CTRL, IQ_CTRL_FLUSH);
    reg_write(IQ_REG_CTRL, IQ_CTRL_ENABLE | (full_rate ? IQ_CTRL_TAP_FULL : 0));

    fprintf(stderr, "streaming %s rate to %s:%d, tuning word %06x\n",
            full_rate ? "full" : "decimated", host, port,
            reg_read(IQ_REG_PHASE_INC));

    int16_t  payload[PAIRS_PER_DATAGRAM * 2];
    int      filled = 0;
    long     sent_pairs = 0;
    uint16_t last_drops = 0;

    while (!stop_requested && (want_pairs < 0 || sent_pairs < want_pairs)) {
        uint32_t level = reg_read(IQ_REG_LEVEL);

        if (level == 0) {
            /* Nothing ready; a datagram's worth takes about 0.9 ms at
             * the full rate. */
            nap_us(200);
            continue;
        }

        while (level-- > 0) {
            uint32_t w = reg_read(IQ_REG_DATA);

            payload[filled * 2]     = (int16_t)(w >> 16);
            payload[filled * 2 + 1] = (int16_t)(w & 0xFFFF);
            filled++;

            if (filled == PAIRS_PER_DATAGRAM) {
                if (sendto(sock, payload, BYTES_PER_DATAGRAM, 0,
                           (struct sockaddr *)&dst, sizeof dst) < 0)
                    fprintf(stderr, "sendto: %s\n", strerror(errno));
                sent_pairs += filled;
                filled = 0;

                if (want_pairs >= 0 && sent_pairs >= want_pairs) break;
            }
        }

        uint32_t status = reg_read(IQ_REG_STATUS);
        if (IQ_STATUS_DROPS(status) != last_drops) {
            last_drops = IQ_STATUS_DROPS(status);
            fprintf(stderr, "dropped %u pairs -- the reader is behind the FIFO\n",
                    last_drops);
        }
    }

    reg_write(IQ_REG_CTRL, 0);
    fprintf(stderr, "sent %ld pairs\n", sent_pairs);

    close(sock);
    bus_close();
    return 0;
}
