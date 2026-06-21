# ============================================================================
# solvyr3_artix7.xdc  -  Pin + timing constraints for the Solvyr-3 SoC
#
# Target: Digilent Nexys A7-100T  (Xilinx Artix-7  XC7A100T-1CSG324C).
# All board I/O is LVCMOS33. Adjust PACKAGE_PINs for a different Artix-7 board;
# the port names match solvyr3_top.v. The 100 MHz board oscillator drives the
# single system clock domain (no MMCM by default; see SOLVYR3_USE_MMCM).
# ============================================================================

# ---- System clock : 100 MHz -------------------------------------------------
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -add -name sys_clk -period 10.000 -waveform {0 5} [get_ports { CLK100MHZ }]

# ---- Reset push-button (CPU_RESETN, active low) -----------------------------
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { CPU_RESETN }]

# ---- Slide switches  SW[15:0] ----------------------------------------------
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports { SW[0] }]
set_property -dict { PACKAGE_PIN L16 IOSTANDARD LVCMOS33 } [get_ports { SW[1] }]
set_property -dict { PACKAGE_PIN M13 IOSTANDARD LVCMOS33 } [get_ports { SW[2] }]
set_property -dict { PACKAGE_PIN R15 IOSTANDARD LVCMOS33 } [get_ports { SW[3] }]
set_property -dict { PACKAGE_PIN R17 IOSTANDARD LVCMOS33 } [get_ports { SW[4] }]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports { SW[5] }]
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports { SW[6] }]
set_property -dict { PACKAGE_PIN R13 IOSTANDARD LVCMOS33 } [get_ports { SW[7] }]
set_property -dict { PACKAGE_PIN T8  IOSTANDARD LVCMOS18 } [get_ports { SW[8] }]
set_property -dict { PACKAGE_PIN U8  IOSTANDARD LVCMOS18 } [get_ports { SW[9] }]
set_property -dict { PACKAGE_PIN R16 IOSTANDARD LVCMOS33 } [get_ports { SW[10] }]
set_property -dict { PACKAGE_PIN T13 IOSTANDARD LVCMOS33 } [get_ports { SW[11] }]
set_property -dict { PACKAGE_PIN H6  IOSTANDARD LVCMOS33 } [get_ports { SW[12] }]
set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports { SW[13] }]
set_property -dict { PACKAGE_PIN U11 IOSTANDARD LVCMOS33 } [get_ports { SW[14] }]
set_property -dict { PACKAGE_PIN V10 IOSTANDARD LVCMOS33 } [get_ports { SW[15] }]

# ---- LEDs  LED[15:0] --------------------------------------------------------
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { LED[2] }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { LED[3] }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { LED[4] }]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { LED[5] }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { LED[6] }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { LED[7] }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { LED[8] }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { LED[9] }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { LED[10] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { LED[11] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { LED[12] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { LED[13] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { LED[14] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { LED[15] }]

# ---- Push-buttons  BTN[4:0] = {BTNR,BTNL,BTND,BTNU,BTNC} --------------------
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports { BTN[0] }] ;# BTNC
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports { BTN[1] }] ;# BTNU
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports { BTN[2] }] ;# BTND
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports { BTN[3] }] ;# BTNL
set_property -dict { PACKAGE_PIN M17 IOSTANDARD LVCMOS33 } [get_ports { BTN[4] }] ;# BTNR

# ---- USB-UART bridge --------------------------------------------------------
set_property -dict { PACKAGE_PIN C4  IOSTANDARD LVCMOS33 } [get_ports { UART_TXD_IN }]  ;# host -> FPGA
set_property -dict { PACKAGE_PIN D4  IOSTANDARD LVCMOS33 } [get_ports { UART_RXD_OUT }] ;# FPGA -> host

# ---- 7-segment display : segments {g,f,e,d,c,b,a}, anodes AN[7:0] -----------
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { SEG[0] }] ;# CA (a)
set_property -dict { PACKAGE_PIN R10 IOSTANDARD LVCMOS33 } [get_ports { SEG[1] }] ;# CB (b)
set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports { SEG[2] }] ;# CC (c)
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 } [get_ports { SEG[3] }] ;# CD (d)
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { SEG[4] }] ;# CE (e)
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { SEG[5] }] ;# CF (f)
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports { SEG[6] }] ;# CG (g)
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports { DP }]      ;# DP
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports { AN[0] }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports { AN[1] }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { AN[2] }]
set_property -dict { PACKAGE_PIN J14 IOSTANDARD LVCMOS33 } [get_ports { AN[3] }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { AN[4] }]
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { AN[5] }]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports { AN[6] }]
set_property -dict { PACKAGE_PIN U13 IOSTANDARD LVCMOS33 } [get_ports { AN[7] }]

# ---- Asynchronous I/O timing ------------------------------------------------
# Inputs (switches, buttons, UART RX) cross into sys_clk through synchronizers;
# the reset button is fully asynchronous.
set_input_delay -clock sys_clk 0.000 [get_ports { SW[*] BTN[*] UART_TXD_IN }]
set_false_path  -from [get_ports { CPU_RESETN }]

# Outputs LED / 7-seg / UART TX are asynchronous, with no sys_clk-synchronous
# receiver: the LEDs and the ~kHz multiplexed 7-seg are human-visible, and UART
# TX is serial data recovered by the host's OWN baud clock (bit period ~8.68 us
# at 115200 baud, >> the 10 ns system clock), so their exact clock-to-pin timing
# is irrelevant. They are excluded from timing rather than capping Fmax. (The
# genuine internal critical paths are fixed in RTL, never hidden behind this.)
set_false_path -to [get_ports { LED[*] SEG[*] DP AN[*] UART_RXD_OUT }]

# ---- Configuration ----------------------------------------------------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO    [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
