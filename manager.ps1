param(
    [ValidateSet('menu', 'preview', 'selftest', 'status', 'list')]
    [string]$Command = 'menu'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$TaskName = 'Zapret2-Windows'
$Binary = Join-Path $Root 'bin\winws2.exe'
$ActiveConfig = Join-Path $Root 'runtime\active.conf'
$StateFile = Join-Path $Root 'runtime\state.json'
$Strategies = Get-Content -LiteralPath (Join-Path $Root 'strategies\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-Strategy([string]$Id) {
    $match = @($Strategies | Where-Object { $_.id -eq $Id })
    if ($match.Count -ne 1) { throw "Unknown strategy: $Id" }
    return $match[0]
}

function Get-ConfigText([string]$Id) {
    $strategy = Get-Strategy $Id
    $templateName = if ($strategy.configTemplate) { [string]$strategy.configTemplate } else { 'base.conf.in' }
    if ($templateName -notmatch '^[a-zA-Z0-9_-]+\.conf\.in$') { throw 'Invalid config template name.' }
    $template = Get-Content -LiteralPath (Join-Path $Root ('strategies\' + $templateName)) -Raw -Encoding UTF8
    $text = $template.Replace('{{ROOT}}', $Root)
    if (-not $strategy.configTemplate) {
        $text = $text.Replace('{{YOUTUBE_TLS}}', ($strategy.youtubeTls -join "`r`n")).
            Replace('{{GENERAL_TLS}}', ($strategy.generalTls -join "`r`n"))
    }
    if ($text -match '\{\{[^}]+\}\}') { throw 'Config has unresolved placeholders.' }
    return $text
}

function Test-Package {
    $required = @(
        'bin\winws2.exe', 'bin\WinDivert.dll', 'bin\WinDivert64.sys', 'bin\cygwin1.dll',
        'lua\zapret-lib.lua', 'lua\zapret-antidpi.lua',
        'data\windivert_part.quic_initial_ietf.txt',
        'data\quic_initial_www_google_com.bin', 'data\minecraft-seqovl.bin',
        'lists\list-youtube.txt', 'lists\list-all-safe.txt', 'lists\list-exclude-safe.txt',
        'strategies\base.conf.in', 'strategies\catalog.json',
        'strategies\targets.txt', 'strategies\test.ps1'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    if ($missing.Count) { throw ('Missing files: ' + ($missing -join ', ')) }
    $exclusions = @(Get-Content -LiteralPath (Join-Path $Root 'lists\list-exclude-safe.txt') |
        ForEach-Object { $_.Trim().ToLowerInvariant() })
    foreach ($domain in @('openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com')) {
        if ($exclusions -notcontains $domain) { throw "Missing Codex exclusion: $domain" }
    }
    foreach ($strategy in $Strategies) {
        if (-not $strategy.id -or -not $strategy.source -or
            (-not $strategy.configTemplate -and
             (@($strategy.youtubeTls).Count -lt 1 -or @($strategy.generalTls).Count -lt 1))) {
            throw 'Invalid strategy entry.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Root ('strategies\' + $strategy.source)) -PathType Leaf)) {
            throw "Missing launcher: $($strategy.source)"
        }
        [void](Get-ConfigText $strategy.id)
    }
    return $true
}

function Get-State {
    if (Test-Path -LiteralPath $StateFile) {
        return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return [pscustomobject]@{ active = 'split-overlap'; recommended = $null }
}

function Save-State($state) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $StateFile) -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Write-Config([string]$Id, [string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, (Get-ConfigText $Id), [Text.UTF8Encoding]::new($false))
}

function Get-ManagedTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    $expectedArgs = '@"' + $ActiveConfig + '"'
    if ($task.Actions.Count -ne 1 -or
        $task.Actions[0].Execute -ine $Binary -or
        $task.Actions[0].Arguments -ine $expectedArgs) {
        throw "Task $TaskName uses a different command. Refusing to manage it."
    }
    return $task
}

function Get-WinwsProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'")
}

function Assert-NoOtherWinws {
    $task = Get-ManagedTask
    $processes = @(Get-WinwsProcesses)
    foreach ($process in $processes) {
        $expected = $task -and $task.State -eq 'Running' -and
            $process.CommandLine -and $process.CommandLine.Contains($ActiveConfig) -and
            $process.ExecutablePath -ieq $Binary
        if (-not $expected) {
            throw "Another winws2.exe (PID $($process.ProcessId)) is active. Stop it by its original manager first."
        }
    }
}

function Assert-NoOtherAutostart {
    $others = @(Get-ScheduledTask | Where-Object {
        $_.TaskName -ne $TaskName -and $_.Settings.Enabled -and
        ($_.TaskName -match 'zapret|winws' -or
         @($_.Actions | Where-Object { $_.Execute -match 'winws|zapret' -or $_.Arguments -match 'winws|zapret' }).Count -gt 0)
    })
    if ($others.Count) {
        throw ('Other enabled zapret startup tasks exist: ' + (($others | ForEach-Object TaskName) -join ', '))
    }
}

function Wait-Task([string]$Wanted) {
    for ($i = 0; $i -lt 30; $i++) {
        if ((Get-ManagedTask).State.ToString() -eq $Wanted) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Task did not enter $Wanted state."
}

function Wait-NoWinws {
    for ($i = 0; $i -lt 40; $i++) {
        if (@(Get-WinwsProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'winws2.exe did not stop.'
}

function Confirm-Plan([string]$Action, [string]$Rollback) {
    Write-Host "Action: $Action" -ForegroundColor Yellow
    Write-Host "Rollback: $Rollback" -ForegroundColor Yellow
    return ((Read-Host 'Type YES to continue') -ceq 'YES')
}

function Show-Status {
    $task = Get-ManagedTask
    $state = Get-State
    if (@(Get-WinwsProcesses).Count -gt 0) {
        Write-Host 'Bypass (winws2.exe) is RUNNING.'
    } else {
        Write-Host 'Bypass (winws2.exe) is NOT RUNNING.'
    }
    Write-Host "Current strategy: $($state.active)"
    Write-Host "Autostart task: $(if ($task) { $task.State } else { 'not installed' })"
    Write-Host "winws2 processes: $(@(Get-WinwsProcesses).Count)"
    if ($state.recommended) { Write-Host "Last recommendation: $($state.recommended)" }
}

function Show-Strategies {
    $state = Get-State
    foreach ($item in $Strategies) {
        $mark = if ($item.id -eq $state.active) { '*' } else { ' ' }
        Write-Host " $mark $($item.id.PadRight(24)) $($item.source)"
    }
    Write-Host '* = selected in service; current-custom = snapshot of original active.conf'
}

function Install-Autostart {
    [void](Test-Package)
    if (Get-ManagedTask) { Write-Host 'Autostart already installed.'; return }
    Assert-NoOtherWinws
    Assert-NoOtherAutostart
    if (-not (Confirm-Plan 'Install the Zapret2-Windows startup task and start it.' 'Menu option 3 stops it; option 4 removes the task.')) { return }
    $state = Get-State
    Write-Config $state.active $ActiveConfig
    $action = New-ScheduledTaskAction -Execute $Binary -Argument ('@"' + $ActiveConfig + '"')
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    try {
        Start-ScheduledTask -TaskName $TaskName
        Wait-Task 'Running'
        Write-Host 'Autostart installed and started.' -ForegroundColor Green
    } catch {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        throw
    }
}

function Stop-Bypass {
    $task = Get-ManagedTask
    if (-not $task -or $task.State -ne 'Running') { Write-Host 'Managed task is not running.'; return }
    if (-not (Confirm-Plan 'Stop the managed zapret2 task.' 'Menu option 2 starts it again.')) { return }
    Stop-ScheduledTask -TaskName $TaskName
    Wait-Task 'Ready'
    Write-Host 'Stopped.' -ForegroundColor Green
}

function Start-Bypass {
    [void](Test-Package)
    $task = Get-ManagedTask
    if (-not $task) { throw 'Install autostart first.' }
    if ($task.State -eq 'Running') { Write-Host 'Already running.'; return }
    Assert-NoOtherWinws
    if (-not (Confirm-Plan 'Start the managed zapret2 task.' 'Menu option 3 stops it.')) { return }
    Start-ScheduledTask -TaskName $TaskName
    Wait-Task 'Running'
    Write-Host 'Started.' -ForegroundColor Green
}

function Remove-Autostart {
    $task = Get-ManagedTask
    if (-not $task) { Write-Host 'Autostart is not installed.'; return }
    if (-not (Confirm-Plan 'Stop and remove the Zapret2-Windows startup task.' 'Menu option 1 reinstalls it using the selected strategy.')) { return }
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName; Wait-Task 'Ready' }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host 'Autostart removed.' -ForegroundColor Green
}

function Test-Strategies {
    [void](Test-Package)
    & (Join-Path $Root 'strategies\test.ps1') -Root $Root
}

function Select-Strategy {
    [void](Test-Package)
    Show-Strategies
    $id = Read-Host 'Strategy ID'
    [void](Get-Strategy $id)
    $task = Get-ManagedTask
    $processes = @(Get-WinwsProcesses)
    if ($processes.Count -gt 1) { throw 'Multiple winws2.exe processes exist. Refusing to switch.' }
    $originalArgument = $null
    if ($processes.Count -eq 1) {
        $process = $processes[0]
        if (-not $process.ExecutablePath -or $process.ExecutablePath -ine $Binary -or
            -not $process.CommandLine -or $process.CommandLine -notmatch '@"([^"]+)"') {
            throw 'Cannot verify the current winws2.exe and its config. Refusing to switch.'
        }
        $originalConfig = [IO.Path]::GetFullPath($Matches[1])
        if (-not $originalConfig.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $originalConfig -PathType Leaf)) {
            throw 'Current winws2.exe config is outside this installation or missing.'
        }
        $originalArgument = '@"' + $originalConfig + '"'
    }
    $taskWasRunning = [bool]($task -and $task.State -eq 'Running')
    if (-not (Confirm-Plan "Select $id and restart the current bypass if running." 'The previous active.conf and strategy selection are backed up. On failure, the original task or process is restored.')) { return }
    $state = Get-State
    $oldId = $state.active
    $backup = Join-Path $Root 'runtime\active.previous.conf'
    if (Test-Path -LiteralPath $ActiveConfig) { Copy-Item -LiteralPath $ActiveConfig -Destination $backup -Force }
    $startedProcess = $null
    $stoppedOriginal = $false
    try {
        Write-Config $id $ActiveConfig
        if ($taskWasRunning) {
            Stop-ScheduledTask -TaskName $TaskName
            $stoppedOriginal = $true
            Wait-Task 'Ready'
            Wait-NoWinws
            Start-ScheduledTask -TaskName $TaskName
            Wait-Task 'Running'
        } elseif ($processes.Count -eq 1) {
            Stop-Process -Id $process.ProcessId -Force
            $stoppedOriginal = $true
            Wait-NoWinws
            $startedProcess = Start-Process -FilePath $Binary -ArgumentList ('@"' + $ActiveConfig + '"') -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 1200
            $startedProcess.Refresh()
            if ($startedProcess.HasExited) { throw "Selected strategy exited with code $($startedProcess.ExitCode)." }
        }
        $state.active = $id
        Save-State $state
        Write-Host "Selected: $id" -ForegroundColor Green
    } catch {
        $selectionError = $_
        if ($startedProcess) {
            $startedProcess.Refresh()
            if (-not $startedProcess.HasExited) { Stop-Process -Id $startedProcess.Id -Force -ErrorAction SilentlyContinue }
        }
        if ($taskWasRunning -and (Get-ManagedTask).State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        try { Wait-NoWinws } catch { Write-Warning $_.Exception.Message }
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $ActiveConfig -Force }
        $state.active = $oldId
        Save-State $state
        if ($stoppedOriginal -and @(Get-WinwsProcesses).Count -eq 0) {
            if ($taskWasRunning) {
                Start-ScheduledTask -TaskName $TaskName
                Wait-Task 'Running'
            } elseif ($originalArgument) {
                $restored = Start-Process -FilePath $Binary -ArgumentList $originalArgument -PassThru -WindowStyle Hidden
                Start-Sleep -Milliseconds 1200
                $restored.Refresh()
                if ($restored.HasExited) { throw 'Failed to restore the original bypass process.' }
            }
        }
        throw $selectionError
    }
}

function Show-Menu {
    Write-Host 'ZAPRET2 WINDOWS MANAGER'
    $state = Get-State
    Write-Host "Current strategy: $($state.active)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '------------------------------------------'
    Write-Host ''
    Write-Host ':: SERVICE'
    Write-Host '   1. Install autostart'
    Write-Host '   2. Start'
    Write-Host '   3. Stop'
    Write-Host '   4. Remove autostart'
    Write-Host '   5. Check status'
    Write-Host ''
    Write-Host ':: STRATEGIES'
    Write-Host '   6. Test all strategies (strategies/targets.txt)'
    Write-Host '   7. Show strategies'
    Write-Host '   8. Select strategy'
    Write-Host ''
    Write-Host ':: TOOLS'
    Write-Host '   9. Check files and exclusions'
    Write-Host '  10. Open lists folder'
    Write-Host ''
    Write-Host '------------------------------------------'
    Write-Host '   0. Exit'
    Write-Host ''
}

switch ($Command) {
    'preview' { Show-Menu; exit 0 }
    'selftest' { [void](Test-Package); Write-Host 'SELFTEST OK'; exit 0 }
    'status' { Show-Status; exit 0 }
    'list' { Show-Strategies; exit 0 }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $Root -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}

[Console]::Title = 'Zapret2'
[Console]::BackgroundColor = 'Black'
[Console]::ForegroundColor = 'Gray'

while ($true) {
    Clear-Host
    Show-Menu
    $choice = Read-Host 'Select option (0-10)'
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' { Install-Autostart }
            '2' { Start-Bypass }
            '3' { Stop-Bypass }
            '4' { Remove-Autostart }
            '5' { Show-Status }
            '6' { Test-Strategies }
            '7' { Show-Strategies }
            '8' { Select-Strategy }
            '9' { [void](Test-Package); Write-Host 'Files and exclusions: OK' -ForegroundColor Green }
            '10' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $Root 'lists') + '"') }
            default { Write-Host 'Unknown option.' }
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host 'Press Enter to return to the menu' | Out-Null
}
