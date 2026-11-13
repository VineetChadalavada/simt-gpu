# Vivado out-of-context synthesis + place and route on the ZedBoard part.
#
#   vivado -mode batch -source synth/vivado_synth.tcl -tclargs <top> <period_ns> [NC]
#   top: gpu_top | sm_core | fma32
#
# Out-of-context: the ports are not FPGA pins, so the 1000+ bits of the
# memory and perf ports do not need I/O pads. Results go to
# synth/reports/<top>_*.rpt.
set top    [lindex $argv 0]
set period [lindex $argv 1]
set nc     [expr {[llength $argv] > 2 ? [lindex $argv 2] : 2}]
set part   xc7z020clg484-1

set root [file normalize [file join [file dirname [info script]] ..]]
set rep  [file join $root synth reports]
file mkdir $rep

read_verilog [glob [file join $root rtl core *.v]]
read_verilog [glob [file join $root rtl gpu *.v]]

set xdc [file join $rep clk_${top}.xdc]
set f [open $xdc w]
puts $f "create_clock -name clk -period $period \[get_ports clk\]"
close $f
read_xdc -mode out_of_context $xdc

set generics {}
if {$top eq "gpu_top"} { set generics [list -generic NC=$nc] }
synth_design -top $top -part $part -mode out_of_context \
    -include_dirs [file join $root rtl core] {*}$generics
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $rep ${top}_util_synth.rpt]

opt_design
place_design
route_design
report_utilization -file [file join $rep ${top}_util.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $rep ${top}_util_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $rep ${top}_timing.rpt]
report_timing -max_paths 1 -nworst 1 -file [file join $rep ${top}_worst_path.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set f [open [file join $rep ${top}_summary.txt] w]
puts $f "top=$top part=$part period_ns=$period wns_ns=$wns fmax_mhz=[format %.1f $fmax]"
close $f
puts "SUMMARY top=$top period_ns=$period wns_ns=$wns fmax_mhz=[format %.1f $fmax]"
