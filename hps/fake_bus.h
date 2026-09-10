/* Software model of de1soc/iq_avalon_fifo.sv, so iq_streamd builds and runs
 * without a board. Serves a deterministic ramp in place of the datapath;
 * hps/run_check.sh decodes it on the far end. */

#ifndef FAKE_BUS_H
#define FAKE_BUS_H

/* Pairs handed out per LEVEL read, standing in for a filling FIFO. */
#define FAKE_BURST 64

static uint32_t fake_ctrl;
static uint32_t fake_phase;
static uint32_t fake_status;
static long     fake_produced;

static int  bus_open(void)  { return 0; }
static void bus_close(void) { }

static uint32_t fake_next_word(void)
{
    uint16_t i = (uint16_t)(int16_t)(fake_produced % 1000);
    uint16_t q = (uint16_t)(int16_t)(-(fake_produced % 1000));
    fake_produced++;
    return ((uint32_t)i << 16) | q;
}

static inline uint32_t reg_read(int r)
{
    switch (r) {
    case IQ_REG_ID:        return IQ_ID_CODE;
    case IQ_REG_CTRL:      return fake_ctrl;
    case IQ_REG_PHASE_INC: return fake_phase;
    case IQ_REG_LEVEL:     return (fake_ctrl & IQ_CTRL_ENABLE) ? FAKE_BURST : 0u;
    case IQ_REG_STATUS:    return fake_status;
    case IQ_REG_DATA:      return fake_next_word();
    default:               return 0u;
    }
}

static inline void reg_write(int r, uint32_t v)
{
    switch (r) {
    case IQ_REG_CTRL:
        if (v & IQ_CTRL_FLUSH) {
            fake_produced = 0;
            fake_status   = 0;
        }
        fake_ctrl = v & (IQ_CTRL_TAP_FULL | IQ_CTRL_ENABLE);
        break;
    case IQ_REG_PHASE_INC:
        fake_phase = v & ((1u << IQ_PHASE_BITS) - 1u);
        break;
    default:
        break;
    }
}

#endif
