open_project inst.gprj
set_option -top_module top_inst
set_option -synthesis_tool gowinsynthesis
# the 480x272 panel wires R2 to N9, which is dual-purpose (SSPI) -- the
# Sipeed example for this exact panel does the same, so free it up
set_option -use_sspi_as_gpio 1
# WARNING: the default PnR target is 100 MHz (-global_freq 100.000), so the tool
# stops optimising as soon as the SDC's 108 MHz is met and the reported slack stays
# around +0.01 ns no matter what.  Asking for 118 MHz makes it actually optimise
# past the constraint, which is what turns met into met with margin.
set_option -global_freq 118
run all
exit
