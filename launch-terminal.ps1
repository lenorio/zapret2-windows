param([switch]$Classic)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$terminal = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
$manager = Join-Path $root 'manager.ps1'

if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
    throw "Manager script is missing: $manager"
}

if (-not $Classic -and (Test-Path -LiteralPath $terminal -PathType Leaf)) {
    $arguments = '-w new nt --title Zapret2 --suppressApplicationTitle --startingDirectory "' +
        $root + '" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $manager + '"'
    try {
        Start-Process -FilePath $terminal -Verb RunAs -WorkingDirectory $root -ArgumentList $arguments
        exit 0
    } catch {
        Write-Warning "Windows Terminal did not start: $($_.Exception.Message)"
    }
}

$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $manager + '"'
Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $root -ArgumentList $arguments
