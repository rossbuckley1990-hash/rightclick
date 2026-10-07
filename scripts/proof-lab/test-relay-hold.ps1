# Execute the exact hold script with disposable real child processes/files and
# controlled local-user callbacks. This does not create OS users or a relay;
# native Windows account/ACL/tunnel withdrawal remains a separate acceptance.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'windows-relay-hold.ps1'
$originalLocation = Get-Location
$originalState = $env:RIGHTCLICK_WINDOWS_RELAY_STATE
$results = @()
foreach ($case in @('success', 'process-survives', 'user-survives', 'private-state-survives')) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('rc-relay-cleanup-' + [Guid]::NewGuid().ToString())
    $base = Join-Path $fixture 'private'
    $userMarker = Join-Path $fixture 'fixture-user-exists'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'evidence/windows-relay') -Force | Out-Null
    Set-Content (Join-Path $base 'synthetic-private-state') 'disposable fixture'
    Set-Content $userMarker 'controlled local-user callback state'
    $child = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru
    $state = @{schemaVersion=1; expiresAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'); base=$base;
        processes=@($child.Id); users=@('rightclick-cleanup-fixture'); disconnectFile=(Join-Path $base 'disconnect')}
    $state | ConvertTo-Json | Set-Content (Join-Path $base 'supervisor.json')
    $env:RIGHTCLICK_WINDOWS_RELAY_STATE = $base
    $global:rightclickCleanupCase = $case; $global:rightclickCleanupBase = $base; $global:rightclickCleanupUserMarker = $userMarker
    function Stop-Process {
        [CmdletBinding()] param([int]$Id, [switch]$Force)
        if ($global:rightclickCleanupCase -eq 'process-survives') { Write-Error 'Controlled process cleanup failure'; return }
        Microsoft.PowerShell.Management\Stop-Process -Id $Id -Force:$Force -ErrorAction SilentlyContinue
    }
    function Remove-LocalUser {
        [CmdletBinding()] param([Parameter(Position=0)][string]$Name)
        if ($global:rightclickCleanupCase -eq 'user-survives') { Write-Error 'Controlled user cleanup failure'; return }
        Microsoft.PowerShell.Management\Remove-Item $global:rightclickCleanupUserMarker -Force
    }
    function Get-LocalUser {
        [CmdletBinding()] param([Parameter(Position=0)][string]$Name)
        if (Test-Path $global:rightclickCleanupUserMarker) { [PSCustomObject]@{Name=$Name} }
    }
    function Remove-Item {
        [CmdletBinding()] param([Parameter(Position=0)][string]$Path, [switch]$Recurse, [switch]$Force)
        if ($global:rightclickCleanupCase -eq 'private-state-survives' -and $Path -eq $global:rightclickCleanupBase) {
            # A cleanup callback can return without effect; postcondition must
            # detect the real surviving private directory, not trust ACK.
            return
        }
        Microsoft.PowerShell.Management\Remove-Item -Path $Path -Recurse:$Recurse -Force:$Force
    }
    try {
        Set-Location $fixture
        $failed = $false; $errorMessage = $null
        try { & $scriptPath } catch { $failed = $true; $errorMessage = $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber }
        $receiptPath = Join-Path $fixture 'evidence/windows-relay/withdrawal.json'
        $receipt = if (Test-Path $receiptPath) { Get-Content $receiptPath -Raw | ConvertFrom-Json } else { $null }
        $survivingProcess = [bool](Microsoft.PowerShell.Management\Get-Process -Id $child.Id -ErrorAction SilentlyContinue)
        $survivingUser = Test-Path $userMarker
        $survivingState = Test-Path $base
        $expectedSuccess = $case -eq 'success'
        $accurate = $null -ne $receipt -and $receipt.withdrawn -eq $expectedSuccess -and
            $receipt.proofUsersRemoved -eq (-not $survivingUser) -and $receipt.privateStateRemoved -eq (-not $survivingState) -and
            ($expectedSuccess -or ($failed -and -not $receipt.withdrawn))
        $results += [PSCustomObject]@{case=$case; commandFailed=$failed; fixtureError=$errorMessage; processSurvived=$survivingProcess;
            userCallbackStateSurvived=$survivingUser; privateDirectorySurvived=$survivingState;
            withdrawalClaim=if ($receipt) {$receipt.withdrawn} else {$null}; evidenceAccurate=$accurate}
    } finally {
        Set-Location $originalLocation
        Microsoft.PowerShell.Management\Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        Microsoft.PowerShell.Management\Remove-Item $fixture -Recurse -Force
        Microsoft.PowerShell.Management\Remove-Item Function:Stop-Process, Function:Remove-LocalUser, Function:Get-LocalUser, Function:Remove-Item -ErrorAction SilentlyContinue
    }
}
$env:RIGHTCLICK_WINDOWS_RELAY_STATE = $originalState
$results | ConvertTo-Json -Depth 5
if ($results.Where({ -not $_.evidenceAccurate }).Count) { throw 'Proof withdrawal evidence did not match actual cleanup postconditions' }
