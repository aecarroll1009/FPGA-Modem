# Builds a top with Quartus and prints the two numbers that matter: Fmax and
# resource usage. Run from anywhere:
#
#   powershell -File syn/run_syn.ps1 [-Top rx_top] [-Device 5CEBA4F23C7]
#
# -Top rx_top           the FPGA RX chain (default)
# -Top tt_um_cordic_ddc the unit that tapes out, where the mixing direction is
#                       a live pin instead of a constant
#
# Quartus is Windows-only here, so this is PowerShell while the simulation
# scripts are bash under WSL. Both are driven from the same RTL.

param(
    [ValidateSet("rx_top", "tt_um_cordic_ddc")]
    [string]$Top = "rx_top",
    [string]$Device = "5CEBA4F23C7",
    [string]$QuartusRoot = "C:\intelFPGA_lite\17.0\quartus"
)

$ErrorActionPreference = "Stop"

$syn = Split-Path -Parent $MyInvocation.MyCommand.Path

$quartusSh = Join-Path $QuartusRoot "bin64\quartus_sh.exe"
if (-not (Test-Path $quartusSh)) {
    throw "quartus_sh not found at $quartusSh -- pass -QuartusRoot to point at your install"
}

Write-Host "building $Top for $Device ..." -ForegroundColor Cyan
& $quartusSh -t (Join-Path $syn "build.tcl") $Top $Device
if ($LASTEXITCODE -ne 0) { throw "Quartus build failed (exit $LASTEXITCODE)" }

$out = Join-Path $syn "output"
$fit = Join-Path $out "$Top.fit.rpt"
$sta = Join-Path $out "$Top.sta.rpt"

Write-Host "`n=== resources ===" -ForegroundColor Green
if (Test-Path $fit) {
    Select-String -Path $fit -Pattern 'Logic utilization|Total registers|Total pins|Total block memory bits|Total DSP Blocks|ALMs needed' |
        Select-Object -First 8 | ForEach-Object { ($_.Line -replace '^\s*;?\s*','' -replace '\s*;\s*$','') }
} else { Write-Host "no fit report at $fit" }

Write-Host "`n=== Fmax / slack (slow 1100mV 85C corner) ===" -ForegroundColor Green
if (Test-Path $sta) {
    $lines = Get-Content $sta
    # Anchor on the panel heading, not a bare 'Fmax Summary' -- that also
    # matches the report's table of contents.
    foreach ($panel in @('Fmax Summary', 'Setup Summary', 'Hold Summary')) {
        $m = Select-String -Path $sta -Pattern ("^; Slow 1100mV 85C Model " + [regex]::Escape($panel)) |
             Select-Object -First 1
        if ($m) {
            $lines[($m.LineNumber - 1)..([Math]::Min($m.LineNumber + 4, $lines.Count - 1))] |
                Where-Object { $_ -match '^\s*;' }
        }
    }
} else { Write-Host "no STA report at $sta" }

Write-Host "`nreports in $out" -ForegroundColor Cyan
