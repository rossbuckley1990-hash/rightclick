$ErrorActionPreference = 'Stop'
$base = $env:RIGHTCLICK_WINDOWS_RELAY_STATE
if (-not $base -or -not (Test-Path (Join-Path $base 'supervisor.json'))) { throw 'Proof relay supervisor state is absent' }
$state = Get-Content (Join-Path $base 'supervisor.json') -Raw | ConvertFrom-Json
try {
    while ([DateTimeOffset]::UtcNow -lt [DateTimeOffset]::Parse($state.expiresAt)) {
        if (Test-Path $state.disconnectFile) {
            Write-Host 'Operator requested Windows provider withdrawal.'
            break
        }
        foreach ($id in $state.processes) {
            if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { throw "Windows proof process $id disappeared before requested withdrawal" }
        }
        Start-Sleep -Seconds 2
    }
} finally {
    $cleanupErrors = 0
    foreach ($id in $state.processes) {
        try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { $cleanupErrors++ }
    }
    foreach ($name in $state.users) {
        try { Remove-LocalUser $name -ErrorAction Stop } catch { $cleanupErrors++ }
    }
    try { if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction Stop } } catch { $cleanupErrors++ }
    # A successful cleanup command is only an acknowledgement. Verify absence;
    # lookup errors are uncertainty, never evidence of successful withdrawal.
    $processesStopped = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $running = @(Get-Process -ErrorAction Stop | Where-Object { $_.Id -in $state.processes })
            $processesStopped = $running.Count -eq 0
        } catch { $processesStopped = $false; break }
        if ($processesStopped) { break }
        Start-Sleep -Milliseconds 100
    }
    $proofUsersRemoved = $false
    try {
        $users = @(Get-LocalUser -ErrorAction Stop)
        $proofUsersRemoved = @($users | Where-Object { $_.Name -in $state.users }).Count -eq 0
    } catch { $cleanupErrors++ }
    $privateStateRemoved = $false
    try { $privateStateRemoved = -not (Test-Path $base -ErrorAction Stop) } catch { $cleanupErrors++ }
    $withdrawn = $processesStopped -and $proofUsersRemoved -and $privateStateRemoved -and $cleanupErrors -eq 0
    @{withdrawn = $withdrawn; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); processesStopped = $processesStopped;
      proofUsersRemoved = $proofUsersRemoved; privateStateRemoved = $privateStateRemoved; cleanupErrors = $cleanupErrors} |
        ConvertTo-Json | Set-Content evidence/windows-relay/withdrawal.json
    if (-not $withdrawn) { throw 'Windows proof withdrawal could not be independently confirmed; consult cleanup evidence' }
}
