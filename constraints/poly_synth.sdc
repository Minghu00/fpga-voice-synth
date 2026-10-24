#=============================================================================
# poly_synth.sdc  --  timing constraints
#
#  clk27  : 27 MHz crystal on H11, the only external clock.
#           The rPLL turns it into clk_sys = 108 MHz; the Gowin flow derives
#           that generated clock automatically from the rPLL instance.
#  tp_sdo : asynchronous input from the TTP229 (its own scan clock),
#           synchronised inside ttp229_rx with a 2-FF synchroniser.
#  rst_n  : asynchronous button, released through a 2-FF synchroniser.
#=============================================================================

create_clock -name clk27 -period 37.037 -waveform {0 18.5185} [get_ports {clk27}]

set_false_path -from [get_ports {tp_sdo}]
set_false_path -from [get_ports {rst_n}]
