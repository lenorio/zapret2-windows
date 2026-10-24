param(
    [Parameter(Mandatory = $true)][string]$StrategyId,
    [switch]$RenderOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $root 'bin\winws2.exe'
$catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$strategy = @($catalog | Where-Object { $_.id -ceq $StrategyId })
if ($strategy.Count -ne 1) { throw "Unknown strategy: $StrategyId" }
$strategy = $strategy[0]

foreach ($path in @($binary, (Join-Path $PSScriptRoot 'base.conf.in'),
        (Join-Path $root 'lists\list-exclude-safe.txt'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing file: $path" }
}

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'base.conf.in') -Raw -Encoding UTF8
$configText = $template.Replace('{{ROOT}}', $root).
    Replace('{{YOUTUBE_TLS}}', ($strategy.youtubeTls -join "`r`n")).
    Replace('{{GENERAL_TLS}}', ($strategy.generalTls -join "`r`n"))
if ($configText -match '\{\{[^}]+\}\}') { throw 'Config contains an unresolved placeholder.' }
$runtime = Join-Path $root 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$config = Join-Path $runtime ("manual-$StrategyId.conf")
[IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
Write-Host "Strategy: $($strategy.source)"
Write-Host "Config: $config"
if ($RenderOnly) { return }

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -StrategyId "' + $StrategyId + '"'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $root -ArgumentList $arguments
    return
}

$existing = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'")
if ($existing.Count -gt 0) {
    Write-Host 'Bypass (winws2.exe) is RUNNING.' -ForegroundColor Yellow
    Write-Host 'Stop the existing instance with its original manager before starting this strategy.'
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

[Console]::Title = 'Zapret2 - ' + $strategy.source
Write-Host 'Bypass (winws2.exe) is NOT RUNNING.'
Write-Host 'Starting in this console. Press Ctrl+C to stop.' -ForegroundColor Green
try {
    & $binary ('@"' + $config + '"')
    $exitCode = $LASTEXITCODE
    Write-Host "winws2.exe exited with code $exitCode"
    Read-Host 'Press Enter to close' | Out-Null
    exit $exitCode
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
