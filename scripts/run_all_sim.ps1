# run_all_sim.ps1 -- compile and run every self-checking testbench
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_all_sim.ps1
$ErrorActionPreference = "Continue"
Set-Location D:\Gowin\voice

$IV  = "D:\Gowin\tools\iverilog\bin\iverilog.exe"
$VVP = "D:\Gowin\tools\iverilog\bin\vvp.exe"

$RTL = @(
 "rtl/top_inst.v","rtl/frame_gen.v","rtl/ttp229_rx.v","rtl/keymap8.v",
 "rtl/inc_lut.v","rtl/sine_rom.v","rtl/osc_bank.v","rtl/adsr.v","rtl/mixer16.v",
 "rtl/i2s_tx.v","rtl/audio_out.v","rtl/lcd_timing.v","rtl/wave_buf.v","rtl/lcd_scope.v"
)

$suites = @(
  @{ n="tb_i2s_tx";    f=@("rtl/i2s_tx.v","sim/tb_i2s_tx.v") },
  @{ n="tb_audio_out"; f=@("rtl/audio_out.v","rtl/i2s_tx.v","sim/tb_audio_out.v") },
  @{ n="tb_adsr";      f=@("rtl/adsr.v","sim/tb_adsr.v") },
  @{ n="tb_mixer16";   f=@("rtl/mixer16.v","sim/tb_mixer16.v") },
  @{ n="tb_osc_bank";  f=@("rtl/inc_lut.v","rtl/sine_rom.v","rtl/osc_bank.v","sim/tb_osc_bank.v") },
  @{ n="tb_ttp229_rx"; f=@("rtl/ttp229_rx.v","sim/ttp229_model.v","sim/tb_ttp229_rx.v") },
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
