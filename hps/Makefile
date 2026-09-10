# iq_streamd, for the board and for the software-only test.
#
#   make            cross-compile for the HPS (needs arm-linux-gnueabihf-gcc)
#   make check      build against fake_bus.h and verify the datagrams
#
# Copy the result to the board's rootfs and run it as root; it needs
# /dev/mem to reach the lightweight bridge.

CROSS  ?= arm-linux-gnueabihf-
CFLAGS ?= -O2 -Wall -Wextra -std=c11

all: iq_streamd

iq_streamd: iq_streamd.c iq_regs.h
	$(CROSS)gcc $(CFLAGS) -o $@ iq_streamd.c -lm

iq_streamd_fake: iq_streamd.c iq_regs.h fake_bus.h
	$(CC) $(CFLAGS) -DIQ_FAKE_BUS -o $@ iq_streamd.c -lm

check: iq_streamd_fake
	bash run_check.sh

clean:
	rm -f iq_streamd iq_streamd_fake

.PHONY: all check clean
