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
    foreach ($id in $state.processes) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    foreach ($name in $state.users) { Remove-LocalUser $name -ErrorAction SilentlyContinue }
    if (Test-Path $base) { Remove-Item $base -Recurse -Force }
    @{withdrawn = $true; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); proofUsersRemoved = $true; privateStateRemoved = $true} | ConvertTo-Json | Set-Content evidence/windows-relay/withdrawal.json
}
