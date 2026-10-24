open_project poly_synth.gprj
set_option -top_module top
set_option -synthesis_tool gowinsynthesis
# the 480x272 panel wires R2 to N9, which is dual-purpose (SSPI) -- the
# Sipeed example for this exact panel does the same, so free it up
set_option -use_sspi_as_gpio 1
run all
exit
