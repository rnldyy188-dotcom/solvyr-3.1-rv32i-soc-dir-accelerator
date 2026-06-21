# ============================================================================
# build.tcl  -  Non-project Vivado batch flow for Solvyr-3 on Artix-7
#
# Synthesizes, implements, writes a bitstream, and dumps utilization + timing
# reports. Run from the repo root:
#
#   vivado -mode batch -source vivado/build.tcl
#
# Optional overrides (tcl args):
#   vivado -mode batch -source vivado/build.tcl -tclargs <part> <imem_hex> <use_loader>
#
# Default part is the Nexys A7-100T device; default program image is the demo
# (sw/demo.hex). The image is loaded into the instruction BRAM at synthesis via
# $readmemh (imem_bram INIT_FILE generic).
#
# <use_loader> (0/1, default 0): when 1, compiles in the UART boot loader so you
# can reload the program over UART (SW15=ON) WITHOUT rebuilding the bitstream.
# The official, timing-clean benchmark bitstream uses 0 (loader compiled out) --
# this keeps that result unchanged. The loader build is written to a separate
# file (solvyr3_loader.bit) so the two never collide.
# ============================================================================

set PART       [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a100tcsg324-1"}]
set IMEM_HEX   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "sw/demo.hex"}]
set USE_LOADER [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0}]
set TOP        solvyr3_top
set OUTDIR     vivado/out
set BITNAME    [expr {$USE_LOADER != 0 ? "solvyr3_loader" : "solvyr3"}]
set RPTSUF     [expr {$USE_LOADER != 0 ? "_loader" : ""}]
file mkdir $OUTDIR

# ---- Guard: the firmware image must exist and be non-empty ------------------
# A missing/empty IMEM_INIT silently fills instruction BRAM with NOPs -> the
# board powers up "alive" (heartbeat blinks) but runs nothing and UART is
# silent. Fail loudly here instead of shipping a blank bitstream.
if {![file exists $IMEM_HEX] || [file size $IMEM_HEX] == 0} {
    error "IMEM_INIT image '$IMEM_HEX' is missing or empty.\
           Build the firmware first (e.g. 'make -C sw' or 'make -C bench bench_c.hex')."
}
set imem_abs [file normalize $IMEM_HEX]
set imem_fh  [open $IMEM_HEX r]; set imem_first [gets $imem_fh]; close $imem_fh
puts "### Solvyr-3 build : part=$PART  top=$TOP  ->  $BITNAME.bit"
puts "###   IMEM_INIT  : $imem_abs ([file size $IMEM_HEX] bytes, first word: $imem_first)"
puts "###   USE_LOADER : $USE_LOADER"

# ---- Read sources -----------------------------------------------------------
set RTL {
    rtl/alu.v rtl/regfile.v rtl/imm_gen.v rtl/decoder.v rtl/control_unit.v
    rtl/forwarding_unit.v rtl/hazard_unit.v rtl/branch_unit.v
    rtl/load_store_unit.v rtl/pipeline_regs.v rtl/csr_file.v
    rtl/imem_bram.v rtl/dmem_bram.v rtl/dpram_be.v rtl/dsp_mac.v
    rtl/mm_interconnect.v rtl/gpio.v rtl/timer.v rtl/uart_rx_core.v rtl/uart.v
    rtl/dir_accel.v rtl/prog_loader.v rtl/clk_reset.v rtl/seven_seg.v
    rtl/solvyr3_core.v rtl/solvyr3_soc.v rtl/solvyr3_top.v
}
foreach f $RTL { read_verilog $f }
read_xdc constraints/solvyr3_artix7.xdc

# ---- Synthesis --------------------------------------------------------------
# Pass the program image into the instruction BRAM via the top-level generic, and
# the loader enable. USE_LOADER=0 leaves the loader fully compiled out (official
# build); USE_LOADER=1 instantiates rtl/prog_loader.v for UART program loading.
synth_design -top $TOP -part $PART \
    -generic IMEM_INIT=$IMEM_HEX -generic USE_LOADER=$USE_LOADER \
    -flatten_hierarchy rebuilt
write_checkpoint -force $OUTDIR/post_synth$RPTSUF.dcp
report_utilization -file $OUTDIR/post_synth_util$RPTSUF.rpt
report_timing_summary -file $OUTDIR/post_synth_timing$RPTSUF.rpt

# ---- Implementation ---------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $OUTDIR/post_route$RPTSUF.dcp

# ---- Post-route timing closure (the last sub-100 ps) ------------------------
# The v1.1 setup-critical path is route/fanout-dominated (a csrr->branch forward
# feeding the branch-redirect -> IF/ID-flush net). phys_opt_design is
# SLACK-DRIVEN: it commits only changes that improve WNS/TNS, so these passes can
# only help -- they never regress timing and never change logic or cycle
# behavior (the benchmark still reports 561988 / 8023 / 70.0x / match). Iterate
# until timing is met or no further gain.
proc _wns {} { return [get_property SLACK [lindex [get_timing_paths -setup -max_paths 1] 0]] }
for {set pass 1} {$pass <= 6} {incr pass} {
    set before [_wns]
    if {$before >= 0} { puts "### timing met before post-route pass $pass (WNS=$before ns)"; break }
    if {$pass == 1} { phys_opt_design -directive AggressiveExplore } \
    else            { phys_opt_design -directive Explore }
    set after [_wns]
    puts "### post-route phys_opt pass $pass : WNS $before -> $after ns"
    if {$after <= $before} { puts "### no further gain; stopping"; break }
}
puts "### final post-route WNS = [_wns] ns"
write_checkpoint -force $OUTDIR/post_route_physopt$RPTSUF.dcp

# ---- Reports : LUTs, FFs, BRAM, DSP48E1, timing (loader-specific when USE_LOADER=1)
report_utilization              -file $OUTDIR/post_route_util$RPTSUF.rpt
report_utilization -hierarchical -file $OUTDIR/post_route_util_hier$RPTSUF.rpt
report_timing_summary           -file $OUTDIR/post_route_timing$RPTSUF.rpt
report_drc                      -file $OUTDIR/post_route_drc$RPTSUF.rpt

# ---- Bitstream --------------------------------------------------------------
write_bitstream -force $OUTDIR/$BITNAME.bit

# ---- Console summary --------------------------------------------------------
puts "### Resource summary -------------------------------------------------"
report_utilization
puts "### Timing (WNS/TNS) -------------------------------------------------"
report_timing_summary -delay_type max -max_paths 1
puts "### Solvyr-3 build complete : $OUTDIR/$BITNAME.bit"
