/*
 * dma_bist.c: AXI DMA loopback self-test for the KV260, interrupt driven
 *
 * Hardware: AXI DMA (simple mode) with M_AXIS_MM2S wired straight back to
 * S_AXIS_S2MM in fpga_top.vhd. Data path to DDR through S_AXI_HP0_FPD.
 * mm2s_introut and s2mm_introut go through a concat to pl_ps_irq0[1:0],
 * i.e. GIC IDs 121 and 122.
 *
 *   tx_buf (DDR) -> MM2S -> loopback (PL) -> S2MM -> rx_buf (DDR)
 *
 * Completion is signalled by the DMA interrupts: the handlers acknowledge
 * the DMA and set flags, the DMA registers are never polled for completion.
 *
 * Each test fills tx_buf with a pattern, sends it through the loopback and
 * checks that rx_buf holds the same bytes, that the S2MM channel reports the
 * right received length, that each channel raised exactly one completion
 * interrupt, and that nothing was written past the end of the buffer
 * (guard bytes).
 *
 * Tests:
 *   1. fixed lengths x fixed patterns
 *   2. soak: random lengths with random data
 *   3. throughput at the largest transfer size
 *   4. error interrupt: S2MM buffer shorter than the packet
 *   5. length sweep: separates the fixed cost per transfer from the
 *      streaming rate
 */

#include <string.h>
#include "xparameters.h"
#include "xaxidma.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xtime_l.h"

#define DMA_DEV_ID      XPAR_AXIDMA_0_DEVICE_ID
#define GIC_DEV_ID      XPAR_SCUGIC_0_DEVICE_ID
#define TX_IRQ_ID       XPAR_FABRIC_AXIDMA_0_MM2S_INTROUT_VEC_ID
#define RX_IRQ_ID       XPAR_FABRIC_AXIDMA_0_S2MM_INTROUT_VEC_ID

/* Largest transfer is set by the DMA's "Width of Buffer Length Register"
 * (MaxTransferLen = 2^width - 1). The buffers are sized for a 14-bit width;
 * raise BUF_BYTES if you widen the register in Vivado. */
#define BUF_BYTES       16384U
#define GUARD_BYTES     64U             /* canary area after the rx data */
#define CANARY          0xEEU

/* Interrupts used on both channels. In parentheses: the driver's
 * XAxiDma_IntrEnable() macro doesn't parenthesize its Mask argument. */
#define DMA_IRQS        (XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK)

#define TIMEOUT_US      100000U         /* per transfer */
#define SOAK_TRANSFERS  1000U
#define TPUT_TRANSFERS  100U
#define SWEEP_REPS      50U             /* transfers averaged per length */

/* Stream limit: 4 bytes/beat (32-bit tdata) x pl_clk0 (100 MHz). Update it
 * if you change the stream width or the PL clock. */
#define STREAM_LIMIT_MBPS 400U
#define MAX_MISMATCH_PRINT 4

/* 64-byte alignment = A53 cache line, so cache maintenance on these buffers
 * never touches other variables. */
static u8 tx_buf[BUF_BYTES] __attribute__((aligned(64)));
static u8 rx_buf[BUF_BYTES + GUARD_BYTES] __attribute__((aligned(64)));

static XAxiDma dma;
static XScuGic gic;
static u32 max_len;

/* Written by the interrupt handlers, read by the main code */
struct dma_chan_state {
	volatile u32 done;      /* completion (IOC) interrupt seen */
	volatile u32 err_sr;    /* DMASR when an error interrupt was seen, else 0 */
	volatile u32 irqs;      /* handler calls since the transfer started */
	volatile XTime t_irq;   /* timestamp of the last handler call */
};

static struct dma_chan_state tx_st, rx_st;
static volatile u32 spurious_irqs;

enum {
	ERR_OK = 0,
	ERR_START_RX,
	ERR_START_TX,
	ERR_TIMEOUT,
	ERR_DMA_STATUS,
	ERR_IRQ_COUNT,
	ERR_RX_LENGTH,
	ERR_DATA,
	ERR_GUARD,
};

static const char *err_name[] = {
	"ok", "S2MM start failed", "MM2S start failed", "timeout",
	"DMA error interrupt", "wrong interrupt count", "wrong S2MM length",
	"data mismatch", "write past end of buffer",
};

enum {
	PAT_INCR,       /* byte counter 00 01 02 ... */
	PAT_WALK1,      /* 32-bit walking one */
	PAT_ALT,        /* AAAAAAAA 55555555 ... */
	PAT_ZEROS,
	PAT_ONES,
	PAT_RANDOM,
	PAT_COUNT
};

static const char *pat_name[PAT_COUNT] = {
	"incr", "walk1", "alt", "zeros", "ones", "random",
};

/* xorshift32, good enough for test data */
static u32 rng_state = 0x12345678U;

static u32 rng_next(void)
{
	u32 x = rng_state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	rng_state = x;
	return x;
}

static void fill_pattern(u32 len, int pat)
{
	u32 *w = (u32 *)tx_buf;
	u32 words = (len + 3U) / 4U;
	u32 i;

	for (i = 0; i < words; i++) {
		switch (pat) {
		case PAT_INCR:
			w[i] = ((4U * i) & 0xFFU)
			     | (((4U * i + 1U) & 0xFFU) << 8)
			     | (((4U * i + 2U) & 0xFFU) << 16)
			     | (((4U * i + 3U) & 0xFFU) << 24);
			break;
		case PAT_WALK1:  w[i] = 1U << (i % 32U);                  break;
		case PAT_ALT:    w[i] = (i & 1U) ? 0x55555555U : 0xAAAAAAAAU; break;
		case PAT_ZEROS:  w[i] = 0x00000000U;                      break;
		case PAT_ONES:   w[i] = 0xFFFFFFFFU;                      break;
		default:         w[i] = rng_next();                       break;
		}
	}
}

static u32 dma_status(int direction)
{
	u32 off = (direction == XAXIDMA_DMA_TO_DEVICE) ? XAXIDMA_TX_OFFSET
						       : XAXIDMA_RX_OFFSET;
	return XAxiDma_ReadReg(dma.RegBase, off + XAXIDMA_SR_OFFSET);
}

/* ---------------------------------------------------------------------------
 * Interrupt handlers
 *
 * The DMA holds its introut line high until the IRQ bits in DMASR are
 * written back as 1 (write-1-to-clear), so every handler must ack, otherwise
 * it is entered again as soon as it returns.
 * ------------------------------------------------------------------------- */

static void dma_chan_isr(int direction, struct dma_chan_state *st)
{
	u32 sr = dma_status(direction);
	u32 irq = sr & XAXIDMA_IRQ_ALL_MASK;
	XTime now;

	XAxiDma_IntrAckIrq(&dma, irq, direction);

	if (!irq) {
		spurious_irqs++;
		return;
	}

	XTime_GetTime(&now);
	st->t_irq = now;
	st->irqs++;

	/* On an error the channel halts: record it and let the main code
	 * reset the DMA */
	if (irq & XAXIDMA_IRQ_ERROR_MASK)
		st->err_sr = sr;
	if (irq & XAXIDMA_IRQ_IOC_MASK)
		st->done = 1;
}

static void tx_isr(void *ref)
{
	(void)ref;
	dma_chan_isr(XAXIDMA_DMA_TO_DEVICE, &tx_st);
}

static void rx_isr(void *ref)
{
	(void)ref;
	dma_chan_isr(XAXIDMA_DEVICE_TO_DMA, &rx_st);
}

static int gic_setup(void)
{
	XScuGic_Config *cfg;

	cfg = XScuGic_LookupConfig(GIC_DEV_ID);
	if (!cfg || XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS)
		return XST_FAILURE;

	/* Route the CPU's IRQ exception to the GIC driver, which dispatches to
	 * the handler connected to each interrupt ID */
	Xil_ExceptionInit();
	Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
				     (Xil_ExceptionHandler)XScuGic_InterruptHandler,
				     &gic);

	/* priority 0xA0 (lower = more urgent), 0x3 = rising edge */
	XScuGic_SetPriorityTriggerType(&gic, TX_IRQ_ID, 0xA0, 0x3);
	XScuGic_SetPriorityTriggerType(&gic, RX_IRQ_ID, 0xA0, 0x3);

	if (XScuGic_Connect(&gic, TX_IRQ_ID, tx_isr, NULL) != XST_SUCCESS ||
	    XScuGic_Connect(&gic, RX_IRQ_ID, rx_isr, NULL) != XST_SUCCESS)
		return XST_FAILURE;

	XScuGic_Enable(&gic, TX_IRQ_ID);
	XScuGic_Enable(&gic, RX_IRQ_ID);

	Xil_ExceptionEnable();
	return XST_SUCCESS;
}

/* Reset both channels. The reset clears DMACR, so the interrupt enables are
 * set again afterwards. */
static int dma_reset(void)
{
	u32 n = 1000000U;

	XAxiDma_Reset(&dma);
	while (!XAxiDma_ResetIsDone(&dma)) {
		if (--n == 0U)
			return XST_FAILURE;
	}
	XAxiDma_IntrEnable(&dma, DMA_IRQS, XAXIDMA_DMA_TO_DEVICE);
	XAxiDma_IntrEnable(&dma, DMA_IRQS, XAXIDMA_DEVICE_TO_DMA);
	return XST_SUCCESS;
}

static void chan_state_clear(struct dma_chan_state *st)
{
	st->done = 0;
	st->err_sr = 0;
	st->irqs = 0;
	st->t_irq = 0;
}

/* Start a loopback transfer: tx_len bytes out of tx_buf, room for rx_len
 * bytes in rx_buf. Returns as soon as both channels are running. */
static int dma_start(u32 tx_len, u32 rx_len, XTime *t_start)
{
	/* tx data -> DDR, and make sure no dirty rx lines get evicted over the
	 * data the DMA is about to write */
	Xil_DCacheFlushRange((UINTPTR)tx_buf, tx_len);
	Xil_DCacheFlushRange((UINTPTR)rx_buf, sizeof(rx_buf));

	chan_state_clear(&tx_st);
	chan_state_clear(&rx_st);

	XTime_GetTime(t_start);

	/* Arm the receiver first, then start the sender */
	if (XAxiDma_SimpleTransfer(&dma, (UINTPTR)rx_buf, rx_len,
				   XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS)
		return ERR_START_RX;
	if (XAxiDma_SimpleTransfer(&dma, (UINTPTR)tx_buf, tx_len,
				   XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
		return ERR_START_TX;
	return ERR_OK;
}

/* Wait for both completion interrupts, an error interrupt or the timeout.
 *
 * Only the flags set by the handlers are checked here, not the DMA. In this
 * test the CPU has nothing else to do; in an application this is where it
 * would return to its main loop (or block on a semaphore under an RTOS) and
 * look at the flags later. */
static int dma_wait(XTime t_start)
{
	XTime deadline = t_start + (XTime)TIMEOUT_US * (COUNTS_PER_SECOND / 1000000U);
	XTime now;

	while (!(tx_st.done && rx_st.done)) {
		if (tx_st.err_sr || rx_st.err_sr)
			return ERR_DMA_STATUS;
		XTime_GetTime(&now);
		if (now > deadline)
			return ERR_TIMEOUT;
	}
	if (tx_st.err_sr || rx_st.err_sr)
		return ERR_DMA_STATUS;
	return ERR_OK;
}

/* One loopback transfer of len bytes from tx_buf to rx_buf.
 * elapsed = timer ticks from starting S2MM to the last completion interrupt. */
static int dma_transfer(u32 len, XTime *elapsed)
{
	XTime t0;
	u32 rx_len;
	int err;

	err = dma_start(len, len, &t0);
	if (err == ERR_OK)
		err = dma_wait(t0);

	/* Drop stale cache lines so the CPU reads what the DMA wrote */
	Xil_DCacheInvalidateRange((UINTPTR)rx_buf, sizeof(rx_buf));

	if (err != ERR_OK)
		return err;

	if (tx_st.irqs != 1U || rx_st.irqs != 1U) {
		xil_printf("    interrupts: MM2S %u, S2MM %u (expected 1 each)\r\n",
			   tx_st.irqs, rx_st.irqs);
		return ERR_IRQ_COUNT;
	}
	if (elapsed)
		*elapsed = ((tx_st.t_irq > rx_st.t_irq) ? tx_st.t_irq : rx_st.t_irq) - t0;

	/* In simple mode S2MM_LENGTH holds the number of bytes received */
	rx_len = XAxiDma_ReadReg(dma.RegBase,
				 XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET);
	if (rx_len != len) {
		xil_printf("    S2MM received %u bytes, expected %u\r\n", rx_len, len);
		return ERR_RX_LENGTH;
	}
	return ERR_OK;
}

static int check_guard(u32 from)
{
	u32 i;

	for (i = from; i < from + GUARD_BYTES; i++) {
		if (rx_buf[i] != CANARY) {
			xil_printf("    guard @%u overwritten: 0x%02x\r\n", i, rx_buf[i]);
			return ERR_GUARD;
		}
	}
	return ERR_OK;
}

static int check_rx(u32 len)
{
	u32 i, bad = 0;

	for (i = 0; i < len; i++) {
		if (rx_buf[i] != tx_buf[i]) {
			if (bad < MAX_MISMATCH_PRINT)
				xil_printf("    @%u: got 0x%02x, expected 0x%02x\r\n",
					   i, rx_buf[i], tx_buf[i]);
			bad++;
		}
	}
	if (bad) {
		xil_printf("    %u of %u bytes wrong\r\n", bad, len);
		return ERR_DATA;
	}
	return check_guard(len);
}

static void print_dma_state(const char *what)
{
	xil_printf("    %s: MM2S_DMASR=0x%08x S2MM_DMASR=0x%08x"
		   " (at error irq: 0x%08x / 0x%08x)\r\n",
		   what, dma_status(XAXIDMA_DMA_TO_DEVICE),
		   dma_status(XAXIDMA_DEVICE_TO_DMA), tx_st.err_sr, rx_st.err_sr);
}

/* Full test of one transfer: fill, send, check. On a DMA failure the
 * status registers are printed and the DMA is reset so later tests can run. */
static int run_one(u32 len, int pat, XTime *elapsed)
{
	int err;

	fill_pattern(len, pat);
	memset(rx_buf, CANARY, sizeof(rx_buf));

	err = dma_transfer(len, elapsed);
	if (err == ERR_OK)
		return check_rx(len);

	print_dma_state(err_name[err]);
	if (dma_reset() != XST_SUCCESS)
		xil_printf("    DMA reset did not complete\r\n");
	return err;
}

static u32 test_fixed(u32 *run)
{
	/* multiples of 4 = whole 32-bit beats; odd sizes exercise tkeep on the
	 * last beat */
	const u32 lens[] = { 4, 64, 1024, 4096, 0 /* max, aligned */, 1, 3, 1023 };
	const u32 n_lens = sizeof(lens) / sizeof(lens[0]);
	u32 failed = 0, l;
	int p, err;

	xil_printf("\r\n[1] fixed lengths x patterns\r\n");
	for (l = 0; l < n_lens; l++) {
		u32 len = lens[l] ? lens[l] : (max_len & ~3U);
		u32 len_failed = 0;

		for (p = 0; p < PAT_COUNT; p++) {
			err = run_one(len, p, NULL);
			(*run)++;
			if (err) {
				len_failed++;
				xil_printf("  FAIL len=%5u pat=%-6s (%s)\r\n",
					   len, pat_name[p], err_name[err]);
			}
		}
		xil_printf("  len=%5u  %s\r\n", len, len_failed ? "FAIL" : "ok");
		failed += len_failed;
	}
	return failed;
}

static u32 test_soak(u32 *run)
{
	u32 failed = 0, i;
	int err;

	xil_printf("\r\n[2] soak: %u transfers, random length and data\r\n",
		   SOAK_TRANSFERS);
	for (i = 0; i < SOAK_TRANSFERS; i++) {
		u32 len = 1U + (rng_next() % max_len);

		err = run_one(len, PAT_RANDOM, NULL);
		(*run)++;
		if (err) {
			failed++;
			xil_printf("  FAIL #%u len=%u (%s)\r\n", i, len, err_name[err]);
			if (failed >= 10U) {
				xil_printf("  too many failures, stopping soak\r\n");
				break;
			}
		}
	}
	xil_printf("  %u/%u ok\r\n", i - failed, i);
	return failed;
}

static u32 test_throughput(u32 *run)
{
	u32 len = max_len & ~3U;
	XTime t, total = 0;
	u64 mbps, us;
	u32 i;

	xil_printf("\r\n[3] throughput: %u x %u bytes\r\n", TPUT_TRANSFERS, len);
	for (i = 0; i < TPUT_TRANSFERS; i++) {
		(*run)++;
		if (run_one(len, PAT_RANDOM, &t) != ERR_OK) {
			xil_printf("  FAIL at transfer %u\r\n", i);
			return 1;
		}
		total += t;
	}

	/* MM2S and S2MM run at the same time, so this is the rate each way */
	us = (u64)total * 1000000U / COUNTS_PER_SECOND / TPUT_TRANSFERS;
	mbps = (u64)len * TPUT_TRANSFERS * COUNTS_PER_SECOND / total / 1000000U;
	xil_printf("  %u us per transfer (start to last interrupt), %u MB/s each direction\r\n",
		   (u32)us, (u32)mbps);
	xil_printf("  (stream limit %u MB/s)\r\n", STREAM_LIMIT_MBPS);
	return 0;
}

/* Send a packet longer than the S2MM buffer. S2MM must stop at the end of
 * its buffer, flag an error and raise its error interrupt; the DMA is then
 * reset and a normal transfer must work again. */
static u32 test_error_irq(u32 *run)
{
	const u32 tx_len = 4096U, rx_len = 1024U;
	XTime t0;
	u32 failed = 0;
	int err;

	xil_printf("\r\n[4] error interrupt: %u-byte packet into a %u-byte S2MM buffer\r\n",
		   tx_len, rx_len);

	fill_pattern(tx_len, PAT_RANDOM);
	memset(rx_buf, CANARY, sizeof(rx_buf));
	(*run)++;

	err = dma_start(tx_len, rx_len, &t0);
	if (err == ERR_OK)
		err = dma_wait(t0);
	Xil_DCacheInvalidateRange((UINTPTR)rx_buf, sizeof(rx_buf));

	if (err == ERR_DMA_STATUS && rx_st.err_sr) {
		xil_printf("  S2MM error interrupt ok, DMASR=0x%08x%s\r\n", rx_st.err_sr,
			   (rx_st.err_sr & XAXIDMA_ERR_INTERNAL_MASK) ? " (DMAIntErr)" : "");
		if (check_guard(rx_len) != ERR_OK) {
			xil_printf("  FAIL: S2MM wrote past its buffer\r\n");
			failed++;
		}
	} else {
		xil_printf("  FAIL: expected an S2MM error interrupt, got '%s'\r\n",
			   err_name[err]);
		print_dma_state("state");
		failed++;
	}

	if (dma_reset() != XST_SUCCESS) {
		xil_printf("  FAIL: DMA reset did not complete\r\n");
		return failed + 1U;
	}

	(*run)++;
	err = run_one(1024U, PAT_RANDOM, NULL);
	if (err) {
		xil_printf("  FAIL: transfer after reset (%s)\r\n", err_name[err]);
		failed++;
	} else {
		xil_printf("  recovery after reset ok\r\n");
	}
	return failed;
}

/* Time transfers of several lengths and fit a line through the averages:
 *
 *   t(len) = overhead + len / rate
 *
 * overhead is what every transfer costs regardless of its size (starting
 * both channels from software, DMA startup and the first DDR read latency,
 * interrupt latency); rate is how fast the data itself moves once it
 * flows. The residual column shows how far each point is from the line. */
static u32 test_sweep(u32 *run)
{
	const u32 lens[] = { 256, 512, 1024, 2048, 4096, 8192, 0 /* max */ };
	const u32 n = sizeof(lens) / sizeof(lens[0]);
	double x[sizeof(lens) / sizeof(lens[0])];
	double y[sizeof(lens) / sizeof(lens[0])];
	double sx = 0, sy = 0, sxx = 0, sxy = 0, slope, icept, ns_per_tick;
	XTime t, total;
	u32 i, r;

	ns_per_tick = 1e9 / (double)COUNTS_PER_SECOND;

	xil_printf("\r\n[5] length sweep: %u transfers per length\r\n", SWEEP_REPS);
	xil_printf("   bytes    time ns    MB/s  of limit   fit residual ns\r\n");

	for (i = 0; i < n; i++) {
		u32 len = lens[i] ? lens[i] : (max_len & ~3U);

		total = 0;
		for (r = 0; r < SWEEP_REPS; r++) {
			(*run)++;
			if (run_one(len, PAT_RANDOM, &t) != ERR_OK) {
				xil_printf("  FAIL at len=%u transfer %u\r\n", len, r);
				return 1;
			}
			total += t;
		}
		x[i] = (double)len;
		y[i] = (double)total / SWEEP_REPS * ns_per_tick;  /* ns */
		sx += x[i];
		sy += y[i];
		sxx += x[i] * x[i];
		sxy += x[i] * y[i];
	}

	/* least squares */
	slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);      /* ns per byte */
	icept = (sy - slope * sx) / n;                          /* ns */

	for (i = 0; i < n; i++) {
		u32 mbps = (u32)(x[i] * 1000.0 / y[i]);         /* bytes/ns = GB/s */

		xil_printf("  %6u  %9u  %6u  %6u %%  %14d\r\n",
			   (u32)x[i], (u32)y[i], mbps,
			   mbps * 100U / STREAM_LIMIT_MBPS,
			   (int)(y[i] - (icept + slope * x[i])));
	}

	xil_printf("  overhead per transfer : %u ns\r\n", (u32)(icept + 0.5));
	xil_printf("  streaming rate        : %u MB/s (%u %% of the %u MB/s stream limit)\r\n",
		   (u32)(1000.0 / slope + 0.5),
		   (u32)(100000.0 / slope / STREAM_LIMIT_MBPS + 0.5),
		   STREAM_LIMIT_MBPS);
	xil_printf("  half the stream rate is reached at %u bytes per transfer\r\n",
		   (u32)(icept / slope + 0.5));
	return 0;
}

int main(void)
{
	XAxiDma_Config *cfg;
	u32 run = 0, failed = 0;

	xil_printf("\r\n==== AXI DMA loopback BIST (interrupts) ====\r\n");

	cfg = XAxiDma_LookupConfig(DMA_DEV_ID);
	if (!cfg) {
		xil_printf("no config for DMA device %d\r\n", DMA_DEV_ID);
		return XST_FAILURE;
	}
	if (XAxiDma_CfgInitialize(&dma, cfg) != XST_SUCCESS) {
		xil_printf("DMA init failed\r\n");
		return XST_FAILURE;
	}
	if (XAxiDma_HasSg(&dma)) {
		xil_printf("DMA is in scatter-gather mode, this test needs simple mode\r\n");
		return XST_FAILURE;
	}

	/* Keep the DMA quiet while the GIC is set up */
	XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
	XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

	if (gic_setup() != XST_SUCCESS) {
		xil_printf("GIC setup failed\r\n");
		return XST_FAILURE;
	}
	if (dma_reset() != XST_SUCCESS) {
		xil_printf("DMA reset did not complete (PL clock/reset running?)\r\n");
		return XST_FAILURE;
	}

	max_len = dma.TxBdRing.MaxTransferLen;
	if (max_len > BUF_BYTES)
		max_len = BUF_BYTES;

	xil_printf("DMA @ 0x%08x, max transfer %u bytes, timer %u Hz\r\n",
		   (u32)cfg->BaseAddr, max_len, (u32)COUNTS_PER_SECOND);
	xil_printf("IRQ IDs: MM2S %u, S2MM %u\r\n", (u32)TX_IRQ_ID, (u32)RX_IRQ_ID);
	xil_printf("tx_buf @ 0x%08x, rx_buf @ 0x%08x\r\n",
		   (u32)(UINTPTR)tx_buf, (u32)(UINTPTR)rx_buf);

	failed += test_fixed(&run);
	failed += test_soak(&run);
	failed += test_throughput(&run);
	failed += test_error_irq(&run);
	failed += test_sweep(&run);

	if (spurious_irqs) {
		xil_printf("\r\n%u spurious interrupts (handler called with no IRQ bit set)\r\n",
			   spurious_irqs);
		failed++;
	}

	xil_printf("\r\n==== DMA BIST %s: %u transfers, %u failed ====\r\n",
		   failed ? "FAIL" : "PASS", run, failed);
	return failed ? XST_FAILURE : XST_SUCCESS;
}
