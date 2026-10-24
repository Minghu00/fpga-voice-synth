#=============================================================================
#  lcd_test.sdc  --  timing constraints for the the LCD/touch bring-up build
#
#  clk27  : 27 MHz crystal on H11. The rPLL derives clk_sys = 108 MHz and the
#           Gowin flow analyses that generated clock automatically.
#  tp_sdo : asynchronous input from the TTP229, synchronised with 2 FFs.
#  rst_n  : asynchronous button, released through a 2-FF synchroniser.
#=============================================================================

create_clock -name clk27 -period 37.037 -waveform {0 18.5185} [get_ports {clk27}]

set_false_path -from [get_ports {tp_sdo}]
set_false_path -from [get_ports {rst_n}]
