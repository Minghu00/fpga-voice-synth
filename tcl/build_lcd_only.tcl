open_project lcd_only.gprj
set_option -top_module top_lcd
set_option -synthesis_tool gowinsynthesis
# lcd_r2 lands on N9 (SSPI_CS_N) and lcd_dclk on R9 (FASTRD_N), both are
# dual purpose configuration pins; the Sipeed example for this panel does
# the same, so release them for general I/O use
set_option -use_sspi_as_gpio 1
run all
exit
