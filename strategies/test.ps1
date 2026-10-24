param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
$binary = Join-Path $Root 'bin\winws2.exe'
$catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$targetFile = Join-Path $PSScriptRoot 'targets.txt'
$resultFolder = Join-Path $PSScriptRoot 'test results'
$taskName = 'Zapret2-Windows'
$activeConfig = Join-Path $Root 'runtime\active.conf'
$stateFile = Join-Path $Root 'runtime\state.json'

function Read-Targets {
    $items = [System.Collections.Generic.List[object]]::new()
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $number = 0
    foreach ($line in (Get-Content -LiteralPath $targetFile -Encoding UTF8)) {
        $number++
        $value = $line.Trim()
        if (-not $value -or $value.StartsWith('#')) { continue }
        if ($value -notmatch '^([A-Za-z][A-Za-z0-9_]*)\s*=\s*"([^"]+)"\s*$') {
            throw "Invalid target at ${targetFile}:${number}"
        }
        $name = $Matches[1]
        $address = $Matches[2]
        if (-not $names.Add($name)) { throw "Duplicate target: $name" }
        if ($address -match '^PING:(.+)$') {
            $items.Add([pscustomobject]@{ Name = $name; Url = $null; PingTarget = $Matches[1] })
            continue
        }
        $uri = $null
        if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https')) {
            throw "Invalid URL for ${name}: $address"
        }
        $items.Add([pscustomobject]@{ Name = $name; Url = $address; PingTarget = $uri.DnsSafeHost })
    }
    if ($items.Count -eq 0) { throw "No targets in $targetFile" }
    return $items.ToArray()
}

function Get-WinwsProcesses { return @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'") }

function Wait-NoWinws {
    for ($i = 0; $i -lt 40; $i++) {
        if (@(Get-WinwsProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'winws2.exe did not stop.'
}

function Get-OriginalState {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $expectedArg = '@"' + $activeConfig + '"'
        if ($task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine $binary -or
            $task.Actions[0].Arguments -ine $expectedArg) {
            throw "Task $taskName has an unexpected action. Test cancelled."
        }
    }
    $otherTasks = @(Get-ScheduledTask | Where-Object {
        $_.TaskName -ne $taskName -and $_.Settings.Enabled -and
        ($_.TaskName -match 'zapret|winws' -or
         @($_.Actions | Where-Object { $_.Execute -match 'winws|zapret' -or $_.Arguments -match 'winws|zapret' }).Count -gt 0)
    })
    if ($otherTasks.Count) { throw 'Another enabled zapret startup task exists. Test cancelled.' }
    $processes = @(Get-WinwsProcesses)
    if ($processes.Count -gt 1) { throw 'Multiple winws2.exe processes exist. Test cancelled.' }
    $originalArgument = $null
    $pidToStop = $null
    if ($processes.Count -eq 1) {
        $process = $processes[0]
        if (-not $process.ExecutablePath -or $process.ExecutablePath -ine $binary) {
            throw 'Cannot verify the running winws2.exe belongs to this installation. Test cancelled.'
        }
        if (-not $process.CommandLine -or $process.CommandLine -notmatch '@"([^"]+)"') {
            throw 'Cannot read the current winws2.exe config argument. Test cancelled.'
        }
        $currentConfig = $Matches[1]
        $fullConfig = [IO.Path]::GetFullPath($currentConfig)
        if (-not $fullConfig.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $fullConfig -PathType Leaf)) {
            throw 'Current config is outside this installation or missing. Test cancelled.'
        }
        $originalArgument = '@"' + $fullConfig + '"'
        $pidToStop = $process.ProcessId
    }
    return [pscustomobject]@{
        TaskRunning = [bool]($task -and $task.State -eq 'Running')
        PidToStop = $pidToStop
        Argument = $originalArgument
    }
}

$probeScript = {
    param($target, [int]$timeoutSeconds)
    $ErrorActionPreference = 'Continue'
    $protocols = @(
        @{ Name = 'HTTP'; Args = @('--http1.1') },
        @{ Name = 'TLS1.2'; Args = @('--tlsv1.2', '--tls-max', '1.2') },
        @{ Name = 'TLS1.3'; Args = @('--tlsv1.3', '--tls-max', '1.3') }
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $elapsed = 0L
    if ($target.Url) {
        foreach ($protocol in $protocols) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                $args = @('--noproxy', '*', '-I', '-L', '-sS', '-o', 'NUL', '-w', '%{http_code}',
                    '--connect-timeout', '2', '--max-time', [string]$timeoutSeconds) +
                    $protocol.Args + @($target.Url)
                $output = & curl.exe @args 2>&1
                $exitCode = $LASTEXITCODE
                $outputText = ($output | Out-String).Trim()
                $code = if ($outputText -match '(\d{3})\s*$') { $Matches[1] } else { '000' }
                $status = if ($exitCode -eq 0 -and $code -match '^[23]\d\d$') { 'OK' }
                    elseif ($exitCode -in @(51, 60)) { 'SSL' }
                    elseif ($exitCode -eq 4 -or $outputText -match 'not supported|unknown option|unrecognized option') { 'UNSUP' }
                    else { 'ERROR' }
            } catch {
                $code = '000'; $exitCode = -1; $status = 'ERROR'
            } finally {
                $timer.Stop()
                $elapsed += $timer.ElapsedMilliseconds
            }
            $checks.Add([pscustomobject]@{
                Name = $protocol.Name; Status = $status; Code = $code
                ExitCode = $exitCode; Ms = $timer.ElapsedMilliseconds
            })
        }
    }
    $pingText = 'n/a'
    if ($target.PingTarget) {
        $ping = [Net.NetworkInformation.Ping]::new()
        try {
            $reply = $ping.Send($target.PingTarget, 1000)
            if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                $pingText = "$($reply.RoundtripTime) ms"
            } else { $pingText = 'Timeout' }
        } catch { $pingText = 'Timeout' } finally { $ping.Dispose() }
    }
    return [pscustomobject]@{
        Name = $target.Name; Url = $target.Url; Checks = $checks.ToArray()
        Ping = $pingText; Ms = $elapsed
    }
}

function Invoke-Probes($targets) {
    $parallel = [Math]::Min(16, [Math]::Max(1, $targets.Count))
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $parallel)
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $targets) {
            $powershell = [PowerShell]::Create()
            [void]$powershell.AddScript($probeScript.ToString()).AddArgument($target).AddArgument(4)
            $powershell.RunspacePool = $pool
            $jobs.Add([pscustomobject]@{ PowerShell = $powershell; Handle = $powershell.BeginInvoke(); Target = $target })
        }
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($job in $jobs) {
            try {
                if (-not $job.Handle.AsyncWaitHandle.WaitOne(17000)) { $job.PowerShell.Stop() }
                $value = @($job.PowerShell.EndInvoke($job.Handle))
                if ($value.Count -ne 1) { throw 'No probe result.' }
                $results.Add($value[0])
            } catch {
                $results.Add([pscustomobject]@{
                    Name = $job.Target.Name; Url = $job.Target.Url; Checks = @(); Ping = 'Timeout'; Ms = 0
                })
            }
        }
        return $results.ToArray()
    } finally {
        foreach ($job in $jobs) { $job.PowerShell.Dispose() }
        $pool.Close(); $pool.Dispose()
    }
}

function Write-Check($result) {
    Write-Host ('  ' + $result.Name.PadRight(24)) -NoNewline
    foreach ($check in $result.Checks) {
        $color = switch ($check.Status) { 'OK' { 'Green' } 'UNSUP' { 'Yellow' } default { 'Red' } }
        Write-Host (" $($check.Name):$($check.Status)") -NoNewline -ForegroundColor $color
    }
    Write-Host ' | Ping: ' -NoNewline -ForegroundColor DarkGray
    Write-Host $result.Ping -ForegroundColor $(if ($result.Ping -match '^\d') { 'Cyan' } else { 'Yellow' })
}

function Save-Report($results, $best, $restore) {
    New-Item -ItemType Directory -Path $resultFolder -Force | Out-Null
    $path = Join-Path $resultFolder ('test_results_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.txt')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Zapret2 Windows strategy test')
    $lines.Add('Targets: ' + $targetFile)
    $lines.Add('Ranking: number of successful HTTP/TLS checks; ping is diagnostic only.')
    $lines.Add('')
    foreach ($item in $results) {
        $lines.Add("Config: $($item.Source) (ID: $($item.Id))")
        if ($item.Error) { $lines.Add('  Start error: ' + $item.Error) }
        foreach ($target in $item.Targets) {
            $tokens = @($target.Checks | ForEach-Object { "$($_.Name):$($_.Status)" }) -join ' '
            $lines.Add("  $($target.Name) : $tokens | Ping: $($target.Ping)")
        }
        $lines.Add("  Score: $($item.Score)/$($item.Possible); time: $($item.Ms) ms")
        $lines.Add('')
    }
    $lines.Add('=== ANALYTICS ===')
    foreach ($item in ($results | Sort-Object @{ Expression = { -$_.Score } }, @{ Expression = { $_.Ms } })) {
        $lines.Add("$($item.Source) : $($item.Score)/$($item.Possible) OK; $($item.Ms) ms")
    }
    $lines.Add('')
    $lines.Add('Best strategy: ' + $(if ($best) { $best.Source + ' (' + $best.Id + ')' } else { 'none' }))
    $lines.Add('Original bypass restoration: ' + $restore)
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($true))
    return $path
}

if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Missing $binary" }
if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { throw "Missing $targetFile" }
$targets = @(Read-Targets)
if ($catalog.Count -eq 0) { throw 'No strategies in catalog.json.' }
foreach ($strategy in $catalog) {
    & (Join-Path $PSScriptRoot 'run.ps1') -StrategyId $strategy.id -RenderOnly -Quiet
}
if ($PlanOnly) {
    Write-Host "Ready: $($catalog.Count) strategies, $($targets.Count) targets."
    Write-Host "Target file: $targetFile"
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run service.bat as administrator to test live strategies.'
}
$original = Get-OriginalState
Write-Host "Action: test $($catalog.Count) strategies against $($targets.Count) targets; current bypass will pause." -ForegroundColor Yellow
Write-Host 'Rollback: stop each candidate and restore the original task or process in finally.' -ForegroundColor Yellow
Write-Host 'The selected strategy and active.conf will not be changed.' -ForegroundColor Yellow

$results = [System.Collections.Generic.List[object]]::new()
$currentProcess = $null
$restoreStatus = 'not needed'
$started = $false
$failure = $null
try {
    if ($original.TaskRunning) {
        Stop-ScheduledTask -TaskName $taskName
        $started = $true
    } elseif ($original.PidToStop) {
        Stop-Process -Id $original.PidToStop -Force
        $started = $true
    }
    Wait-NoWinws
    foreach ($strategy in $catalog) {
        if (@(Get-WinwsProcesses).Count -ne 0) { throw 'Another winws2.exe appeared during the test.' }
        $config = Join-Path $Root ('runtime\manual-' + $strategy.id + '.conf')
        Write-Host "`nTesting $($strategy.source)..." -ForegroundColor Cyan
        $startError = $null
        $targetResults = @()
        $score = 0
        $possible = @($targets | Where-Object Url).Count * 3
        $ms = 0L
        try {
            $currentProcess = Start-Process -FilePath $binary -ArgumentList ('@"' + $config + '"') -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 1200
            $currentProcess.Refresh()
            if ($currentProcess.HasExited) { throw "winws2.exe exited with code $($currentProcess.ExitCode)." }
            $targetResults = @(Invoke-Probes $targets)
            foreach ($target in $targetResults) {
                Write-Check $target
                $score += @($target.Checks | Where-Object Status -eq 'OK').Count
                $ms += $target.Ms
            }
        } catch {
            $startError = $_.Exception.Message
            Write-Host "  Test failed: $startError" -ForegroundColor Red
        } finally {
            if ($currentProcess) {
                $currentProcess.Refresh()
                if (-not $currentProcess.HasExited) { Stop-Process -Id $currentProcess.Id -Force -ErrorAction SilentlyContinue }
                [void]$currentProcess.WaitForExit(5000)
                $currentProcess = $null
            }
            Wait-NoWinws
        }
        $results.Add([pscustomobject]@{
            Id = $strategy.id; Source = $strategy.source; Score = $score
            Possible = $possible; Ms = $ms; Targets = $targetResults; Error = $startError
        })
    }
} catch {
    $failure = $_
    Write-Host "Test interrupted: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($currentProcess) {
        $currentProcess.Refresh()
        if (-not $currentProcess.HasExited) { Stop-Process -Id $currentProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    try {
        Wait-NoWinws
        if ($original.TaskRunning) {
            Start-ScheduledTask -TaskName $taskName
            $restoreStatus = 'original scheduled task restarted'
        } elseif ($original.Argument -and $started) {
            $restored = Start-Process -FilePath $binary -ArgumentList $original.Argument -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 1200
            $restored.Refresh()
            if ($restored.HasExited) { throw "Original process exited with code $($restored.ExitCode)." }
            $restoreStatus = "original process restored (PID $($restored.Id))"
        }
    } catch {
        $restoreStatus = 'FAILED: ' + $_.Exception.Message
        Write-Host "Restore failed: $restoreStatus" -ForegroundColor Red
    }
    $state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $ranked = @($results | Where-Object { $_.Score -gt 0 } | Sort-Object
        @{ Expression = { -$_.Score } },
        @{ Expression = { if ($state -and $_.Id -eq $state.active) { 0 } else { 1 } } },
        @{ Expression = { $_.Ms } })
    $best = if ($ranked.Count) { $ranked[0] } else { $null }
    $report = Save-Report $results $best $restoreStatus
    Write-Host "`nBest strategy: $(if ($best) { $best.Source } else { 'none' })" -ForegroundColor Green
    Write-Host "Report: $report"
    Write-Host "Restore: $restoreStatus"
}
if ($failure) { throw $failure }
if ($restoreStatus -like 'FAILED:*') { throw $restoreStatus }
