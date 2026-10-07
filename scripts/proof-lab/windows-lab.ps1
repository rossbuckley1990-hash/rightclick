$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP ('rightclick-proof-' + [guid]::NewGuid().ToString('N'))
$guard = Join-Path $env:RUNNER_TEMP ('rightclick-proof-admin-' + [guid]::NewGuid().ToString('N'))
$name = 'rightclick-proof'
$principal = "$env:COMPUTERNAME\$name"
$service = $null
$created = $false
try {
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { throw 'Refusing to reuse an existing local identity' }
    $passwordText = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(48)) + 'Aa1!'
    $password = ConvertTo-SecureString $passwordText -AsPlainText -Force
    $passwordText = $null
    New-LocalUser -Name $name -Password $password -AccountExpires (Get-Date).AddHours(1) -Description 'Disposable RIGHTCLICK scoped proof identity' | Out-Null
    $created = $true
    Add-LocalGroupMember -Group 'Users' -Member $principal
    $adminMembers = @(Get-LocalGroupMember -Group 'Administrators' | Select-Object -ExpandProperty Name)
    if ($adminMembers -contains $principal) { throw 'Proof identity must not be an administrator' }
    New-Item -ItemType Directory -Path $root, $guard | Out-Null
    & icacls $root /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' "${principal}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create scoped directory ACL' }
    & icacls $guard /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to protect administrator guard directory' }
    $protected = Join-Path $guard 'administrator-only.txt'
    Set-Content -Path $protected -Value 'Harmless out-of-scope read challenge'
    $fixture = Join-Path $root 'host-service.py'
    Copy-Item scripts/proof-lab/host-service.py $fixture
    $configPath = Join-Path $root 'credential.json'
    $config = @{
        RIGHTCLICK_PROOF_HOST_TOKEN = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        RIGHTCLICK_PROOF_HOST_ORIGIN = 'http://127.0.0.1:19141'
        RIGHTCLICK_PROOF_BIND = '127.0.0.1'
        RIGHTCLICK_PROOF_PORT = '19141'
        RIGHTCLICK_PROOF_EFFECTS = (Join-Path $root 'effects')
        RIGHTCLICK_PROOF_PROTECTED_PATH = $protected
    }
    $config | ConvertTo-Json | Set-Content -Path $configPath
    $credential = [pscredential]::new($principal, $password)
    Start-Service seclogon
    $python = (Get-Command python).Source
    $service = Start-Process -FilePath $python -ArgumentList "`"$fixture`" `"$configPath`"" -Credential $credential -LoadUserProfile -WorkingDirectory $root -PassThru
    python scripts/proof-lab/windows-verify.py $configPath evidence/proof-lab/windows-readiness.json
    if ($LASTEXITCODE -ne 0) { throw 'Native Windows readiness verification failed' }
    Stop-Process -Id $service.Id -Force
    $service = $null
    $disconnected = $false
    try { Invoke-WebRequest -Uri 'http://127.0.0.1:19141/health' -TimeoutSec 3 | Out-Null }
    catch { $disconnected = $true }
    if (-not $disconnected) { throw 'Windows provider did not disconnect' }
    $evidence = Get-Content evidence/proof-lab/windows-readiness.json -Raw | ConvertFrom-Json
    $evidence | Add-Member -NotePropertyName localAdministratorMember -NotePropertyValue $false
    $evidence | Add-Member -NotePropertyName providerDisconnected -NotePropertyValue $true
    $evidence | Add-Member -NotePropertyName principalQualified -NotePropertyValue $principal
    $evidence | ConvertTo-Json -Depth 10 | Set-Content evidence/proof-lab/windows-readiness.json
} finally {
    if ($service) { Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue }
    if ($created) { Remove-LocalUser -Name $name -ErrorAction SilentlyContinue }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    if (Test-Path $guard) { Remove-Item $guard -Recurse -Force }
}
