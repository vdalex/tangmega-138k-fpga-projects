/*
 * Minimal register definitions for the Gowin/Andes AE350 subsystem.
 *
 * Addresses follow the AE350 platform map (Gowin RiscV_AE350_SOC hardware
 * manual + the standard AndeShape AE350 peripheral layout).
 */
#ifndef AE350_H
#define AE350_H

#include <stdint.h>

#define REG32(a)		(*(volatile uint32_t *)(a))

/* ---- memory regions (hardware manual, "Memory System") ---- */
#define AE350_IMEM_BASE	0x80000000u		/* instruction memory (our boot ROM) */
#define AE350_DMEM_BASE	0x00000000u		/* data memory (unused in stage 1)   */
#define AE350_ILM_BASE	0xA0000000u		/* core-internal, 64 KB              */
#define AE350_DLM_BASE	0xA0200000u		/* core-internal, 64 KB - our RAM    */
#define AE350_DLM_SIZE	0x00010000u

/* ---- APB peripherals ---- */
#define UART1_BASE		0xF0200000u
#define UART2_BASE		0xF0300000u		/* console, out via the BL616 bridge */
#define GPIO_BASE		0xF0700000u

/*
 * UART: Andes ATCUART100, 16C550A-compatible. The 16550 register block sits
 * at offset 0x20; below that are the controller's own ID/config registers.
 */
#define UART_OFF_IDREV	0x00
#define UART_OFF_CFG	0x10
#define UART_OFF_OSCR	0x14			/* over-sample control (8 or 16)     */
#define UART_OFF_RBR	0x20			/* read: RX  write: TX  (DLL if DLAB) */
#define UART_OFF_IER	0x24			/* DLM if DLAB                        */
#define UART_OFF_FCR	0x28
#define UART_OFF_LCR	0x2C
#define UART_OFF_MCR	0x30
#define UART_OFF_LSR	0x34

#define UART_LCR_DLAB	0x80
#define UART_LCR_8N1	0x03
#define UART_LSR_THRE	0x20			/* transmit holding register empty    */

#define UART_FCR_FIFOEN	0x01
#define UART_FCR_RXRST	0x02
#define UART_FCR_TXRST	0x04

/* GPIO (Andes ATCGPIO100) */
#define GPIO_OFF_DATAOUT	0x24
#define GPIO_OFF_CHANNELDIR	0x28		/* 1 = output                         */

/*
 * The UART is clocked from the APB bus, which top.v drives at 100 MHz.
 * divisor = APB_HZ / (oversample * baud); the reset default oversample is 16.
 */
#define APB_HZ			100000000u
#define UART_BAUD		115200u
#define UART_DIVISOR	(APB_HZ / (16u * UART_BAUD))	/* 54 -> 0.5% error   */

#endif /* AE350_H */
