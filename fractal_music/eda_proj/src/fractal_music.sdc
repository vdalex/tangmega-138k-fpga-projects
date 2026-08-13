// One PLL, one clock domain for everything - audio included. The I2S rates
// are divided down from the pixel clock so there is no crossing to constrain.

create_clock -name clk_50   -period 20    -waveform {0 10} [get_ports {clk}]
create_clock -name pixel_clk -period 13.333 [get_nets {pixel_clock}]
create_clock -name serial_clk -period 2.667 [get_nets {serial_clock}]

// Kept on one line: this parser does not accept backslash continuations.
set_clock_groups -asynchronous -group [get_clocks {clk_50}] -group [get_clocks {pixel_clk serial_clk}]

// The DAC and the LEDs are slow outputs; nothing samples them synchronously.
set_false_path -to [get_ports {HP_BCK HP_WS HP_DIN PA_EN}]
set_false_path -to [get_ports {led[*]}]
