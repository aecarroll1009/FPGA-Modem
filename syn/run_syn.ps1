# Builds rx_top with Quartus and prints the two numbers that matter: Fmax and
# resource usage. Run from anywhere:
#
#   powershell -File syn/run_syn.ps1 [-Device 5CEBA4F23C7]
#
# Quartus is Windows-only here, so this is PowerShell while the simulation
# scripts are bash under WSL. Both are driven from the same RTL.

param(
    [string]$Device = "5CEBA4F23C7",
    [string]$QuartusRoot = "C:\intelFPGA_lite\17.0\quartus"
)

$ErrorActionPreference = "Stop"

$syn = Split-Path -Parent $MyInvocation.MyCommand.Path

$quartusSh = Join-Path $QuartusRoot "bin64\quartus_sh.exe"
if (-not (Test-Path $quartusSh)) {
    throw "quartus_sh not found at $quartusSh -- pass -QuartusRoot to point at your install"
}

Write-Host "building rx_top for $Device ..." -ForegroundColor Cyan
& $quartusSh -t (Join-Path $syn "build.tcl") $Device
if ($LASTEXITCODE -ne 0) { throw "Quartus build failed (exit $LASTEXITCODE)" }

$out = Join-Path $syn "output"
$fit = Join-Path $out "rx_top.fit.rpt"
$sta = Join-Path $out "rx_top.sta.rpt"

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
