// Timing constraints - AE350 bring-up.
//
// The board oscillator is 50 MHz. The PLL derives every AE350 domain from it
// (VCO = 50/1*16 = 800 MHz): CORE 800, AHB 100, APB 100, DDR 50, RTC 10 - the
// tool propagates those through the PLL automatically. The 800 MHz core clock
// stays on the hard core's dedicated path and never enters the fabric.

create_clock -name clk_50 -period 20 -waveform {0 10} [get_ports {clk}]

// The button and the UART pins are asynchronous to everything.
set_false_path -from [get_ports {key_n}]
set_false_path -from [get_ports {uart_rx}]
set_false_path -to [get_ports {uart_tx}]
set_false_path -to [get_ports {led[*]}]

// Video domain: 150 MHz pixel clock and the 5x DDR bit clock, from the second
// PLL. The text buffer is the only path between this and the AE350 domain,
// and it is a dual-port RAM, so the two are otherwise unrelated.
create_clock -name pixel_clk -period 6.667 [get_nets {pixel_clock}]
create_clock -name serial_clk -period 1.333 [get_nets {serial_clock}]
set_clock_groups -asynchronous -group [get_clocks {clk_50}] -group [get_clocks {pixel_clk serial_clk}]
