#=============================================================================
#  scripts/sim.ps1 -- build and run every testbench with Icarus Verilog
#
#  Usage (from the project root):
#      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim.ps1
#      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim.ps1 tb_top
#
#  Notes
#   * iverilog must be run from the project root, because wavetable_bank.v loads
#     "rtl/audio/wav_bank_4096.mem" with a relative path (the same path Gowin uses).
#   * pll_sys.v is replaced by sim/pll_sys_sim.v during simulation; the real
#     rPLL primitive cannot be simulated with Icarus.
#   * All RTL paths below follow the board layout:
#        rtl/top  rtl/clock  rtl/input  rtl/audio  rtl/display  rtl/legacy
#     Change paths here only; the RTL sources themselves are location-agnostic.
#=============================================================================
param(
    [string]$Only = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$iverilog = "D:\Gowin\tools\iverilog\bin\iverilog.exe"
$vvp      = "D:\Gowin\tools\iverilog\bin\vvp.exe"
if (-not (Test-Path $iverilog)) {
    Write-Host "iverilog not found at $iverilog" -ForegroundColor Red
    exit 1
}

# ---- 板块路径 ---------------------------------------------------------------
$A  = "rtl/audio"
$D  = "rtl/display"
$I  = "rtl/input"
$C  = "rtl/clock"

$rtl = @(
    "$A/frame_gen.v", "$I/ttp229_rx.v", "rtl/legacy/keymap.v", "$A/inc_lut.v",
    "$A/wavetable_bank.v", "$A/osc_bank.v", "$A/adsr.v", "$A/mixer16.v",
    "$A/i2s_tx.v", "rtl/legacy/lat_counter.v", "$D/lcd_timing.v", "$D/wave_buf.v",
    "rtl/legacy/lcd_panel.v", "$I/keymap8.v", "$D/lcd_scope.v", "$A/audio_out.v",
    "$A/test_mode.v"
)

$benches = @(
    @{ name = "tb_i2s_tx";    src = @("sim/tb_i2s_tx.v",    "$A/i2s_tx.v") },
    @{ name = "tb_adsr";      src = @("sim/tb_adsr.v",      "$A/adsr.v") },
    @{ name = "tb_mixer16";   src = @("sim/tb_mixer16.v",   "$A/mixer16.v") },
    @{ name = "tb_osc_bank";  src = @("sim/tb_osc_bank.v",  "$A/osc_bank.v", "$A/inc_lut.v", "$A/wavetable_bank.v") },
    @{ name = "tb_wavetable"; src = @("sim/tb_wavetable.v", "$A/wavetable_bank.v") },
    @{ name = "tb_audio_out"; src = @("sim/tb_audio_out.v", "$A/audio_out.v", "$A/i2s_tx.v") },
    @{ name = "tb_lcd";       src = @("sim/tb_lcd.v",       "rtl/legacy/lcd_panel.v", "$D/lcd_timing.v", "$D/wave_buf.v") },
    @{ name = "tb_ttp229_rx"; src = @("sim/tb_ttp229_rx.v", "$I/ttp229_rx.v", "sim/ttp229_model.v") },
    @{ name = "tb_test_mode"; src = @("sim/tb_test_mode.v", "$A/test_mode.v") },
    @{ name = "tb_fx_echo";   src = @("sim/tb_fx_echo.v",   "$A/fx_echo.v") },
 @{ name = "tb_fx_rvb_cho"; src = @("sim/tb_fx_rvb_cho.v", "$A/fx_echo.v") },
@{ name = "tb_liss";       src = @("sim/tb_liss.v",       "$D/liss_render.v") },
    @{ name = "tb_lcd_only";  src = @("sim/tb_lcd_only.v",  "sim/pll_sys_sim.v", "rtl/legacy/top_lcd.v", "$D/lcd_timing.v") },
    @{ name = "tb_lcd_test";  src = @("sim/tb_lcd_test.v",  "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/legacy/top_lcd_test.v", "$I/ttp229_rx.v", "$D/lcd_timing.v") },
    @{ name = "tb_inst";      src = @("sim/tb_inst.v", "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/top/top_inst.v", "$A/frame_gen.v", "$I/ttp229_rx.v", "$I/keymap8.v", "$A/inc_lut.v", "$A/wavetable_bank.v", "$A/osc_bank.v", "$A/adsr.v", "$A/mixer16.v", "$A/i2s_tx.v", "$D/lcd_timing.v", "$D/wave_buf.v", "$D/lcd_scope.v", "$A/audio_out.v", "$A/test_mode.v", "$A/fx_echo.v", "$D/spectrum16.v", "$D/liss_render.v") },
    @{ name = "tb_top";       src = @(@("sim/tb_top.v", "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/legacy/top.v") + $rtl) }
)

$pass = 0
$fail = 0
$failed = @()

foreach ($b in $benches) {
    if ($Only -ne "" -and $b.name -ne $Only) { continue }

    Write-Host ""
    Write-Host "==== $($b.name) ====" -ForegroundColor Cyan

    $vvpfile = "sim/$($b.name).vvp"
    & $iverilog -g2005 -o $vvpfile @($b.src) 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  COMPILE FAILED" -ForegroundColor Red
        $fail++; $failed += $b.name
        continue
    }

    $out = & $vvp $vvpfile 2>&1
    $out | Where-Object { $_ -match "PASS|FAIL|ALL PASS|FAILURE|fatal|error" } |
        ForEach-Object { Write-Host "  $_" }

    if ($out -match "ALL PASS") {
        $pass++
    } else {
        Write-Host "  *** NOT ALL PASS ***" -ForegroundColor Red
        $fail++; $failed += $b.name
    }
}

Write-Host ""
Write-Host "==================================================="
Write-Host (" testbenches passed : {0}" -f $pass)
Write-Host (" testbenches failed : {0}" -f $fail)
if ($fail -gt 0) {
    Write-Host (" failed: " + ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host " ALL SIMULATIONS PASS" -ForegroundColor Green
exit 0
