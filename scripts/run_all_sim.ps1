# run_all_sim.ps1 -- compile and run every self-checking testbench
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_all_sim.ps1
$ErrorActionPreference = "Continue"
Set-Location D:\Gowin\voice

$IV  = "D:\Gowin\tools\iverilog\bin\iverilog.exe"
$VVP = "D:\Gowin\tools\iverilog\bin\vvp.exe"

# ---- RTL 路径（按板块分目录；改动目录结构时只改这一块） ----------------------
$RTL = @(
 "rtl/top/top_inst.v",
 "rtl/audio/frame_gen.v","rtl/input/ttp229_rx.v","rtl/input/keymap8.v",
 "rtl/audio/inc_lut.v","rtl/audio/sine_rom.v","rtl/audio/osc_bank.v",
 "rtl/audio/adsr.v","rtl/audio/mixer16.v","rtl/audio/i2s_tx.v","rtl/audio/audio_out.v",
 "rtl/audio/test_mode.v",
 "rtl/display/lcd_timing.v","rtl/display/wave_buf.v","rtl/display/lcd_scope.v"
)

$suites = @(
  @{ n="tb_i2s_tx";    f=@("rtl/audio/i2s_tx.v","sim/tb_i2s_tx.v") },
  @{ n="tb_audio_out"; f=@("rtl/audio/audio_out.v","rtl/audio/i2s_tx.v","sim/tb_audio_out.v") },
  @{ n="tb_adsr";      f=@("rtl/audio/adsr.v","sim/tb_adsr.v") },
  @{ n="tb_mixer16";   f=@("rtl/audio/mixer16.v","sim/tb_mixer16.v") },
  @{ n="tb_osc_bank";  f=@("rtl/audio/inc_lut.v","rtl/audio/sine_rom.v","rtl/audio/osc_bank.v","sim/tb_osc_bank.v") },
  @{ n="tb_ttp229_rx"; f=@("rtl/input/ttp229_rx.v","sim/ttp229_model.v","sim/tb_ttp229_rx.v") },
  @{ n="tb_test_mode"; f=@("rtl/audio/test_mode.v","sim/tb_test_mode.v") },
  @{ n="tb_inst";      f=($RTL + @("sim/pll_sys_sim.v","sim/ttp229_model.v","sim/tb_inst.v")) }
)

$fail = 0
foreach ($s in $suites) {
    $out = "sim/$($s.n).vvp"
    & $IV -g2005 -o $out @($s.f) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("COMPILE-FAIL {0}" -f $s.n) -ForegroundColor Red
        $fail++
        continue
    }
    $log = & $VVP $out 2>&1
    $bad = $log | Select-String -Pattern "^FAIL|FAILURES"
    $all = $log | Select-String -Pattern "ALL PASS"
    if ($bad -or -not $all) {
        Write-Host ("FAIL         {0}" -f $s.n) -ForegroundColor Red
        $bad | ForEach-Object { Write-Host ("   {0}" -f $_.Line) }
        $fail++
    } else {
        Write-Host ("PASS         {0}" -f $s.n) -ForegroundColor Green
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "== ALL TESTBENCHES PASS ==" -ForegroundColor Green }
else             { Write-Host ("== {0} SUITE(S) FAILED ==" -f $fail) -ForegroundColor Red }
