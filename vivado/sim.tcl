# ============================================================================
# sim.tcl  -  Run a Solvyr-3 testbench in Vivado's xsim (alternative to Icarus)
#
#   vivado -mode batch -source vivado/sim.tcl                # system test
#   vivado -mode batch -source vivado/sim.tcl -tclargs accel # accelerator test
#
# Equivalent to ./run_sim.sh but using xsim. Test programs (tb/*.hex) are
# produced by tools/rv32i.py; run that first if they are missing.
# ============================================================================
set WHICH [expr {[llength $argv] > 0 ? [lindex $argv 0] : "system"}]

set RTL {
    rtl/alu.v rtl/regfile.v rtl/imm_gen.v rtl/decoder.v rtl/control_unit.v
    rtl/forwarding_unit.v rtl/hazard_unit.v rtl/branch_unit.v
    rtl/load_store_unit.v rtl/pipeline_regs.v rtl/csr_file.v
    rtl/imem_bram.v rtl/dmem_bram.v rtl/dpram_be.v rtl/dsp_mac.v
    rtl/mm_interconnect.v rtl/gpio.v rtl/timer.v rtl/uart_rx_core.v rtl/uart.v
    rtl/dir_accel.v rtl/prog_loader.v rtl/solvyr3_core.v rtl/solvyr3_soc.v
}
array set TB {
    system  tb/tb_system.v   csr tb/tb_csr.v   irq tb/tb_irq.v
    gpio    tb/tb_gpio.v     timer tb/tb_timer.v  uart tb/tb_uart.v
    accel   tb/tb_dir_accel.v  prim tb/tb_primitives.v
}
array set TOP {
    system tb_system  csr tb_csr  irq tb_irq  gpio tb_gpio
    timer  tb_timer   uart tb_uart  accel tb_dir_accel  prim tb_primitives
}

foreach f $RTL { read_verilog -include_dirs rtl $f }
read_verilog -include_dirs rtl $TB($WHICH)

set_property top $TOP($WHICH) [current_fileset -simset]
launch_simulation
run all
