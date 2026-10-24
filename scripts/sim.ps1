#=============================================================================
#  scripts/sim.ps1 -- build and run every testbench with Icarus Verilog
#
#  Usage (from the project root):
#      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim.ps1
#      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim.ps1 tb_top
#
#  Notes
#   * iverilog must be run from the project root, because sine_rom.v loads
#     "rtl/sine_1024.mem" with a relative path (the same path Gowin uses).
#   * pll_sys.v is replaced by sim/pll_sys_sim.v during simulation; the real
#     rPLL primitive cannot be simulated with Icarus.
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

$rtl = @(
    "rtl/frame_gen.v", "rtl/ttp229_rx.v", "rtl/keymap.v", "rtl/inc_lut.v",
    "rtl/sine_rom.v", "rtl/osc_bank.v", "rtl/adsr.v", "rtl/mixer16.v",
    "rtl/i2s_tx.v", "rtl/lat_counter.v", "rtl/lcd_timing.v", "rtl/wave_buf.v",
    "rtl/lcd_panel.v", "rtl/keymap8.v", "rtl/lcd_scope.v", "rtl/audio_out.v"
)

$benches = @(
    @{ name = "tb_i2s_tx";    src = @("sim/tb_i2s_tx.v",    "rtl/i2s_tx.v") },
    @{ name = "tb_adsr";      src = @("sim/tb_adsr.v",      "rtl/adsr.v") },
    @{ name = "tb_mixer16";   src = @("sim/tb_mixer16.v",   "rtl/mixer16.v") },
    @{ name = "tb_osc_bank";  src = @("sim/tb_osc_bank.v",  "rtl/osc_bank.v", "rtl/inc_lut.v", "rtl/sine_rom.v") },
    @{ name = "tb_lcd";       src = @("sim/tb_lcd.v",       "rtl/lcd_panel.v", "rtl/lcd_timing.v", "rtl/wave_buf.v") },
    @{ name = "tb_ttp229_rx"; src = @("sim/tb_ttp229_rx.v", "rtl/ttp229_rx.v", "sim/ttp229_model.v") },
    @{ name = "tb_lcd_only";  src = @("sim/tb_lcd_only.v",  "sim/pll_sys_sim.v", "rtl/top_lcd.v", "rtl/lcd_timing.v") },
    @{ name = "tb_lcd_test";  src = @("sim/tb_lcd_test.v",  "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/top_lcd_test.v", "rtl/ttp229_rx.v", "rtl/lcd_timing.v") },
    @{ name = "tb_inst";      src = @("sim/tb_inst.v", "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/top_inst.v", "rtl/frame_gen.v", "rtl/ttp229_rx.v", "rtl/keymap8.v", "rtl/inc_lut.v", "rtl/sine_rom.v", "rtl/osc_bank.v", "rtl/adsr.v", "rtl/mixer16.v", "rtl/i2s_tx.v", "rtl/lcd_timing.v", "rtl/wave_buf.v", "rtl/lcd_scope.v", "rtl/audio_out.v") },
    @{ name = "tb_top";       src = @(@("sim/tb_top.v", "sim/pll_sys_sim.v", "sim/ttp229_model.v", "rtl/top.v") + $rtl) }
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
