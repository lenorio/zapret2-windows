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
$Strategies = Get-Content -LiteralPath (Join-Path $Root 'strategies.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-Strategy([string]$Id) {
    $match = @($Strategies | Where-Object { $_.id -eq $Id })
    if ($match.Count -ne 1) { throw "Unknown strategy: $Id" }
    return $match[0]
}

function Get-ConfigText([string]$Id) {
    $strategy = Get-Strategy $Id
    $template = Get-Content -LiteralPath (Join-Path $Root 'config\base.conf.in') -Raw -Encoding UTF8
    $text = $template.Replace('{{ROOT}}', $Root).Replace('{{YOUTUBE_TLS}}', ($strategy.youtubeTls -join "`r`n"))
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
        'config\base.conf.in', 'strategies.json'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    if ($missing.Count) { throw ('Missing files: ' + ($missing -join ', ')) }
    $exclusions = @(Get-Content -LiteralPath (Join-Path $Root 'lists\list-exclude-safe.txt') |
        ForEach-Object { $_.Trim().ToLowerInvariant() })
    foreach ($domain in @('openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com')) {
        if ($exclusions -notcontains $domain) { throw "Missing Codex exclusion: $domain" }
    }
    foreach ($strategy in $Strategies) {
        if (-not $strategy.id -or @($strategy.youtubeTls).Count -lt 1) { throw 'Invalid strategy entry.' }
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
    Write-Host "Strategy: $($state.active)"
    Write-Host "Autostart task: $(if ($task) { $task.State } else { 'not installed' })"
    Write-Host "winws2 processes: $(@(Get-WinwsProcesses).Count)"
    if ($state.recommended) { Write-Host "Last recommendation: $($state.recommended)" }
}

function Show-Strategies {
    $state = Get-State
    foreach ($item in $Strategies) {
        $mark = if ($item.id -eq $state.active) { '*' } else { ' ' }
        Write-Host " $mark $($item.id.PadRight(20)) $($item.name)"
    }
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

function Invoke-Probe([string]$Url) {
    $ErrorActionPreference = 'Continue'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $output = & curl.exe --noproxy '*' --http1.1 -I -L -sS -o NUL -w '%{http_code}' --connect-timeout 4 --max-time 9 $Url 2>$null
    $exitCode = $LASTEXITCODE
    $timer.Stop()
    $code = [string]($output | Select-Object -Last 1)
    return [pscustomobject]@{
        url = $Url
        ok = ($exitCode -eq 0 -and $code -match '^[234]\d\d$')
        code = $code
        exitCode = $exitCode
        ms = $timer.ElapsedMilliseconds
    }
}

function Test-Strategies {
    [void](Test-Package)
    Assert-NoOtherWinws
    Assert-NoOtherAutostart
    $task = Get-ManagedTask
    $wasRunning = ($task -and $task.State -eq 'Running')
    if (-not (Confirm-Plan 'Temporarily stop the managed task, test three candidate YouTube TLS profiles, then restore its original state.' 'The finally block stops test processes and restarts the original task if it was running. The active configuration is unchanged.')) { return }
    $results = [System.Collections.Generic.List[object]]::new()
    $targets = @('https://www.youtube.com/', 'https://i.ytimg.com/', 'https://www.google.com/', 'https://discord.com/')
    try {
        if ($wasRunning) { Stop-ScheduledTask -TaskName $TaskName; Wait-Task 'Ready' }
        if (@(Get-WinwsProcesses).Count -ne 0) { throw 'A winws2 process remained after stopping the task.' }
        foreach ($strategy in $Strategies) {
            $candidatePath = Join-Path $Root ('runtime\candidate-' + $strategy.id + '.conf')
            Write-Config $strategy.id $candidatePath
            Write-Host "`nTesting $($strategy.id)..." -ForegroundColor Cyan
            $process = $null
            try {
                $process = Start-Process -FilePath $Binary -ArgumentList ('@"' + $candidatePath + '"') -PassThru -WindowStyle Hidden
                Start-Sleep -Milliseconds 1500
                $process.Refresh()
                if ($process.HasExited) { throw "Candidate exited with code $($process.ExitCode)." }
                $probes = @($targets | ForEach-Object { Invoke-Probe $_ })
                $score = @($probes | Where-Object { $_.ok }).Count
                $ms = ($probes | Measure-Object -Property ms -Sum).Sum
                foreach ($probe in $probes) {
                    Write-Host "  $($probe.url): $(if ($probe.ok) { 'OK' } else { 'FAIL' }) HTTP $($probe.code), $($probe.ms) ms"
                }
                $results.Add([pscustomobject]@{ id = $strategy.id; score = $score; total = $probes.Count; ms = $ms; probes = $probes })
            } catch {
                Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
                $results.Add([pscustomobject]@{ id = $strategy.id; score = 0; total = $targets.Count; ms = 999999; error = $_.Exception.Message })
            } finally {
                if ($process) {
                    $process.Refresh()
                    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                    [void]$process.WaitForExit(5000)
                }
                Start-Sleep -Milliseconds 500
            }
        }
        $state = Get-State
        $ranked = @($results | Sort-Object @{Expression = { -$_.score }}, @{Expression = { if ($_.id -eq $state.active) { 0 } else { 1 } }}, @{Expression = { $_.ms }})
        $best = if ($ranked.Count -and $ranked[0].score -gt 0) { $ranked[0].id } else { $null }
        $state.recommended = $best
        Save-State $state
        $report = Join-Path $Root ('runtime\results-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report -Encoding UTF8
        Write-Host "`nRecommended: $(if ($best) { $best } else { 'none' })"
        Write-Host "Report: $report"
        Write-Host 'HTTP reachability is only a first check. Verify video playback and Codex after applying.'
    } finally {
        if (@(Get-WinwsProcesses).Count -ne 0) {
            Write-Warning 'A winws2 process remains; original task was not restarted to avoid a conflict.'
        } elseif ($wasRunning) {
            Start-ScheduledTask -TaskName $TaskName
            Wait-Task 'Running'
            Write-Host 'Original task restored.' -ForegroundColor Green
        }
    }
}

function Select-Strategy {
    [void](Test-Package)
    Show-Strategies
    $id = Read-Host 'Strategy ID'
    [void](Get-Strategy $id)
    $task = Get-ManagedTask
    Assert-NoOtherWinws
    if (-not (Confirm-Plan "Select $id and restart the managed task if running." 'The previous active.conf is backed up; if restart fails, it is restored. Select the old ID to revert later.')) { return }
    $state = Get-State
    $oldId = $state.active
    $backup = Join-Path $Root 'runtime\active.previous.conf'
    if (Test-Path -LiteralPath $ActiveConfig) { Copy-Item -LiteralPath $ActiveConfig -Destination $backup -Force }
    try {
        Write-Config $id $ActiveConfig
        if ($task -and $task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName
            Wait-Task 'Ready'
            Start-ScheduledTask -TaskName $TaskName
            Wait-Task 'Running'
        }
        $state.active = $id
        Save-State $state
        Write-Host "Selected: $id" -ForegroundColor Green
    } catch {
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $ActiveConfig -Force }
        $state.active = $oldId
        Save-State $state
        if ($task -and (Get-ManagedTask).State -ne 'Running') {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Show-Menu {
    Write-Host 'ZAPRET2 WINDOWS MANAGER'
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
    Write-Host '   6. Test all strategies'
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
