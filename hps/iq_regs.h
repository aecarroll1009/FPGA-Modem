/* Register map of de1soc/iq_avalon_fifo.sv, seen from the HPS through the
 * lightweight FPGA bridge. Keep in step with the RTL and docs/iq_format.md. */

#ifndef IQ_REGS_H
#define IQ_REGS_H

#include <stdint.h>

/* Lightweight HPS-to-FPGA bridge, and the slave's base within it. */
#define IQ_LWBRIDGE_BASE 0xFF200000u
#define IQ_LWBRIDGE_SPAN 0x00001000u
#define IQ_SLAVE_OFFSET  0x00000000u

/* Word indices into the slave. */
#define IQ_REG_ID        0
#define IQ_REG_CTRL      1
#define IQ_REG_PHASE_INC 2
#define IQ_REG_LEVEL     3
#define IQ_REG_STATUS    4
#define IQ_REG_DATA      5
#define IQ_REG_COUNT     6

#define IQ_ID_CODE       0x53445202u   /* "SDR", version 2 */

#define IQ_CTRL_TAP_FULL 0x1u          /* 1 = mixer rate, 0 = FIR rate */
#define IQ_CTRL_ENABLE   0x2u
#define IQ_CTRL_FLUSH    0x4u          /* self-clearing */

#define IQ_STATUS_DROPS(s)    ((uint16_t)((s) & 0xFFFFu))
#define IQ_STATUS_OVERFLOW(s) (((s) >> 16) & 1u)

/* The converter's rate. The NCO advances once per ADC sample, so a tuning
 * word is relative to this regardless of which tap is selected. */
#define IQ_FS_IN_HZ      400000.0
#define IQ_DECIM         8
#define IQ_PHASE_BITS    24

#endif
