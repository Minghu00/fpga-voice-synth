param(
    [string]$GowinBin = "D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $env:TEMP "lcd_test_build"

Write-Output "project : $root"
Write-Output "workdir : $work"

if (Test-Path $work) {
    Remove-Item $work -Recurse -Force
}
New-Item -ItemType Directory -Force -Path "$work\rtl", "$work\constraints", "$work\tcl" | Out-Null

Copy-Item "$root\rtl\*" -Destination "$work\rtl" -Recurse -Force
Copy-Item "$root\constraints\*" -Destination "$work\constraints" -Force
Copy-Item "$root\lcd_test.gprj" -Destination $work -Force
Copy-Item "$root\tcl\build_lcd_test.tcl" -Destination "$work\tcl" -Force

Push-Location $work
try {
    & (Join-Path $GowinBin "gw_sh.exe") "tcl/build_lcd_test.tcl"
} finally {
    Pop-Location
}

if (Test-Path "$work\impl") {
    if (Test-Path "$root\impl_lcd_test") {
        Remove-Item "$root\impl_lcd_test" -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path "$root\impl_lcd_test" | Out-Null
    Copy-Item "$work\impl\*" -Destination "$root\impl_lcd_test" -Recurse -Force
    Write-Output "build artifacts copied to $root\impl_lcd_test"
} else {
    throw "build failed: impl directory not found"
}
