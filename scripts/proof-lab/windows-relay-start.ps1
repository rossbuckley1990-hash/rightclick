$ErrorActionPreference = 'Stop'
$base = Join-Path $env:RUNNER_TEMP ('rightclick-relay-' + [guid]::NewGuid().ToString('N'))
$writer = 'rightclick-proof'
$observer = 'rcproof-observer'
$created = @()
$processes = @()
$expires = [DateTimeOffset]::UtcNow.AddMinutes(60)
$publicKey = Resolve-Path fixtures/proof-relay/operator-public-key.pem
$out = 'evidence/windows-relay'

function Set-PrivateAcl($path, $grants) {
    & icacls $path /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' @grants | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to establish proof directory ACL' }
}
function New-ProofUser($name) {
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { throw 'Refusing to reuse an existing local identity' }
    $text = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(48)) + 'Aa1!'
    $password = ConvertTo-SecureString $text -AsPlainText -Force
    $text = $null
    New-LocalUser -Name $name -Password $password -AccountExpires $expires.UtcDateTime -Description 'Disposable RIGHTCLICK TLS relay proof identity' | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member "$env:COMPUTERNAME\$name"
    if (@(Get-LocalGroupMember Administrators | Select-Object -ExpandProperty Name) -contains "$env:COMPUTERNAME\$name") {
        throw 'Proof identities must remain non-administrators'
    }
    return [pscredential]::new("$env:COMPUTERNAME\$name", $password)
}
function Wait-Service($port) {
    for ($i = 0; $i -lt 40; $i++) {
        try { return Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 2 }
        catch { Start-Sleep -Seconds 1 }
    }
    throw 'Restricted Windows proof service did not become ready'
}
function Start-QuickTunnel($binary, $port, $name) {
    $stdout = Join-Path $base ($name + '.stdout.log')
    $stderr = Join-Path $base ($name + '.stderr.log')
    $p = Start-Process $binary -ArgumentList "tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$port" -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $script:processes += $p.Id
    for ($i = 0; $i -lt 90; $i++) {
        $p.Refresh()
        if ($p.HasExited) { throw 'Official quick tunnel process exited during setup' }
        $log = (Get-Content $stdout, $stderr -Raw -ErrorAction SilentlyContinue) -join "`n"
        $match = [regex]::Match($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($match.Success) { return @{ Process = $p; Origin = $match.Value } }
        Start-Sleep -Seconds 1
    }
    throw 'Quick tunnel did not issue a TLS endpoint within its setup deadline'
}
function Wait-TlsService($origin, $principal) {
    for ($i = 0; $i -lt 90; $i++) {
        try {
            $health = Invoke-RestMethod "$origin/health" -TimeoutSec 3
            if ($health.platform -eq 'Windows' -and $health.principal -eq $principal) { return $health }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'Public TLS proof service failed independent readiness deadline'
}
function Assert-Denied($uri, $token, $method = 'Get', $body = $null, $expected = 401) {
    $parameters = @{Uri = $uri; Headers = @{Authorization = "Bearer $token"}; Method = $method; TimeoutSec = 10; SkipHttpErrorCheck = $true}
    if ($null -ne $body) { $parameters.Body = $body; $parameters.ContentType = 'application/json' }
    $result = Invoke-WebRequest @parameters
    if ([int]$result.StatusCode -ne $expected) { throw 'Proof authority denial returned an unexpected status' }
    return [int]$result.StatusCode
}

try {
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    Set-PrivateAcl $base @()
    $writerCredential = New-ProofUser $writer
    $created += $writer
    $observerCredential = New-ProofUser $observer
    $created += $observer
    $writerRoot = Join-Path $base 'writer'
    $observerRoot = Join-Path $base 'observer'
    $effects = Join-Path $base 'effects'
    $guard = Join-Path $base 'administrator'
    New-Item -ItemType Directory -Path $writerRoot, $observerRoot, $effects, $guard | Out-Null
    Set-PrivateAcl $writerRoot @("${env:COMPUTERNAME}\${writer}:(OI)(CI)M")
    Set-PrivateAcl $observerRoot @("${env:COMPUTERNAME}\${observer}:(OI)(CI)M")
    Set-PrivateAcl $effects @("${env:COMPUTERNAME}\${writer}:(OI)(CI)M", "${env:COMPUTERNAME}\${observer}:(OI)(CI)RX")
    Set-PrivateAcl $guard @()
    $protected = Join-Path $guard 'administrator-only.txt'
    Set-Content $protected 'Harmless administrator-scope read challenge'
    $controlToken = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $disconnect = Join-Path $writerRoot 'withdraw.flag'
    $configs = @{}
    $python = (Get-Command python).Source
    Start-Service seclogon
    foreach ($mode in @('writer', 'observer')) {
        $root = if ($mode -eq 'writer') { $writerRoot } else { $observerRoot }
        $port = if ($mode -eq 'writer') { 19141 } else { 19145 }
        $config = @{
            RIGHTCLICK_PROOF_HOST_TOKEN = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
            RIGHTCLICK_PROOF_HOST_ORIGIN = "http://127.0.0.1:$port"
            RIGHTCLICK_PROOF_BIND = '127.0.0.1'
            RIGHTCLICK_PROOF_PORT = "$port"
            RIGHTCLICK_PROOF_EFFECTS = $effects
            RIGHTCLICK_PROOF_PROTECTED_PATH = $protected
            RIGHTCLICK_PROOF_READ_ONLY = $(if ($mode -eq 'observer') { 'true' } else { 'false' })
            RIGHTCLICK_PROOF_EXPIRES_AT = "$($expires.ToUnixTimeSeconds())"
            RIGHTCLICK_PROOF_PUBLIC_ORIGIN_FILE = (Join-Path $root 'public-origin.txt')
        }
        if ($mode -eq 'writer') {
            $config.RIGHTCLICK_PROOF_CONTROL_TOKEN = $controlToken
            $config.RIGHTCLICK_PROOF_DISCONNECT_FILE = $disconnect
        }
        $fixture = Join-Path $root 'host-service.py'
        $configPath = Join-Path $root 'credential.json'
        Copy-Item scripts/proof-lab/host-service.py $fixture
        $config | ConvertTo-Json | Set-Content $configPath
        $credential = if ($mode -eq 'writer') { $writerCredential } else { $observerCredential }
        $p = Start-Process $python -ArgumentList "`"$fixture`" `"$configPath`"" -Credential $credential -LoadUserProfile -WorkingDirectory $root -PassThru
        $processes += $p.Id
        $health = Wait-Service $port
        $expectedPrincipal = if ($mode -eq 'writer') { $writer } else { $observer }
        if ($health.platform -ne 'Windows' -or $health.principal -ne $expectedPrincipal) { throw 'Actual Windows process identity mismatch' }
        $configs[$mode] = $config
    }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    python scripts/proof-lab/windows-verify.py (Join-Path $writerRoot 'credential.json') "$out/windows-local-readiness.json"
    if ($LASTEXITCODE -ne 0) { throw 'Restricted writer readiness failed' }
    $observerAuthority = Invoke-RestMethod 'http://127.0.0.1:19145/authority-check' -Headers @{Authorization = "Bearer $($configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN)"}
    if (-not $observerAuthority.protectedReadDenied -or -not $observerAuthority.effectWriteDenied) { throw 'Windows observer authority is broader than get-only' }
    $challenge = 'rcrelay_' + [guid]::NewGuid().ToString('N')
    $body = @{challenge = $challenge} | ConvertTo-Json -Compress
    $null = Invoke-RestMethod 'http://127.0.0.1:19141/proof' -Method Post -ContentType 'application/json' -Body $body -Headers @{Authorization = "Bearer $($configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN)"}
    $observed = Invoke-RestMethod "http://127.0.0.1:19145/proof/$challenge" -Headers @{Authorization = "Bearer $($configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN)"}
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('RIGHTCLICK:' + $challenge))).ToLowerInvariant()
    if ($observed.challenge -ne $challenge -or $observed.result -ne $expectedHash -or $observed.observerPrincipal -ne $observer) { throw 'Independent Windows effect observer mismatch' }
    $localCrossObserver = Assert-Denied "http://127.0.0.1:19145/proof/$challenge" $configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN
    $localCrossWriter = Assert-Denied 'http://127.0.0.1:19141/proof' $configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN 'Post' $body
    $localReadOnlyMutation = Assert-Denied 'http://127.0.0.1:19145/proof' $configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN 'Post' $body 403
    $localUnauthorizedWithdrawal = Assert-Denied 'http://127.0.0.1:19141/control/disconnect' $configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN 'Post' '{}'
    $binary = Join-Path $base 'cloudflared.exe'
    Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-windows-amd64.exe' -OutFile $binary
    $binaryHash = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($binaryHash -ne '86aee4017b26625cee8484c113558f48effa4cd47f7aa05fcf425604e5d2b23c') { throw 'Official cloudflared binary digest mismatch' }
    $relays = @{}
    foreach ($mode in @('writer', 'observer')) {
        $port = if ($mode -eq 'writer') { 19141 } else { 19145 }
        $relay = Start-QuickTunnel $binary $port $mode
        $relays[$mode] = $relay.Origin
        Set-Content $configs[$mode].RIGHTCLICK_PROOF_PUBLIC_ORIGIN_FILE $relay.Origin
    }
    $writerTlsHealth = Wait-TlsService $relays.writer $writer
    $observerTlsHealth = Wait-TlsService $relays.observer $observer
    $writerDescriptor = Invoke-RestMethod "$($relays.writer)/openapi.json" -TimeoutSec 10
    $observerDescriptor = Invoke-RestMethod "$($relays.observer)/openapi.json" -TimeoutSec 10
    if ($writerDescriptor.servers[0].url -ne $relays.writer -or $observerDescriptor.servers[0].url -ne $relays.observer) { throw 'Public descriptors are not pinned to their actual TLS origins' }
    $remoteChallenge = 'rcremote_' + [guid]::NewGuid().ToString('N')
    $remoteBody = @{challenge = $remoteChallenge} | ConvertTo-Json -Compress
    $remoteAccepted = Invoke-WebRequest "$($relays.writer)/proof" -Method Post -ContentType 'application/json' -Body $remoteBody -Headers @{Authorization = "Bearer $($configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN)"} -TimeoutSec 10
    if ([int]$remoteAccepted.StatusCode -ne 202) { throw 'TLS writer did not accept the harmless scoped effect' }
    $remoteObserved = Invoke-RestMethod "$($relays.observer)/proof/$remoteChallenge" -Headers @{Authorization = "Bearer $($configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN)"} -TimeoutSec 10
    $remoteExpected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('RIGHTCLICK:' + $remoteChallenge))).ToLowerInvariant()
    if ($remoteObserved.challenge -ne $remoteChallenge -or $remoteObserved.result -ne $remoteExpected -or $remoteObserved.observerPrincipal -ne $observer) { throw 'Independent Windows readback across TLS did not match actual effect' }
    $remoteCrossObserver = Assert-Denied "$($relays.observer)/proof/$remoteChallenge" $configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN
    $remoteCrossWriter = Assert-Denied "$($relays.writer)/proof" $configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN 'Post' $remoteBody
    $remoteUnauthorizedWithdrawal = Assert-Denied "$($relays.writer)/control/disconnect" $configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN 'Post' '{}'
    $connection = @{
        schemaVersion = 1; sourceHead = $env:RIGHTCLICK_RELAY_SOURCE_HEAD; expiresAt = $expires.ToString('o')
        writerOrigin = $relays.writer; observerOrigin = $relays.observer
        writerToken = $configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN; observerToken = $configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN
        controlToken = $controlToken; controlPath = '/control/disconnect'
        writerPrincipal = $writer; observerPrincipal = $observer
    }
    $plaintext = [Text.Encoding]::UTF8.GetBytes(($connection | ConvertTo-Json -Compress))
    . ./scripts/proof-lab/relay-envelope.ps1
    $envelope = [RightclickRelayEnvelope]::Encrypt($plaintext, (Get-Content $publicKey -Raw))
    $keyHash = $envelope.publicKeyDER_SHA256
    if ($keyHash -ne '2be79f7bbcbe8fe18c91504026eddb68fbab902344a91104bc7541a693bab8a0') { throw 'Operator public key fingerprint differs from the approved reference' }
    $envelope['schemaVersion'] = '1'
    $envelope | ConvertTo-Json | Set-Content "$out/connection.encrypted.json"
    [Array]::Clear($plaintext, 0, $plaintext.Length)
    @{schemaVersion = 1; sourceHead = $env:RIGHTCLICK_RELAY_SOURCE_HEAD; expiresAt = $expires.ToString('o'); publicKeyDER_SHA256 = $keyHash
      writerOrigin = $relays.writer; observerOrigin = $relays.observer; cloudflaredVersion = '2026.10.0'; cloudflaredSHA256 = $binaryHash
      writerPrincipal = $writer; observerPrincipal = $observer; observerAuthority = $observerAuthority; independentReadinessEffect = $observed
      writerTlsHealth = $writerTlsHealth; observerTlsHealth = $observerTlsHealth; independentTlsReadinessEffect = $remoteObserved
      crossTokenDenials = @{localWriterAtObserver = $localCrossObserver; localObserverAtWriter = $localCrossWriter; observerMutation = $localReadOnlyMutation
          writerWithdrawal = $localUnauthorizedWithdrawal; tlsWriterAtObserver = $remoteCrossObserver; tlsObserverAtWriter = $remoteCrossWriter; tlsWriterWithdrawal = $remoteUnauthorizedWithdrawal}
      sevenOperationRuntimeAcceptance = 'RED until the Mac runtime agent operates and withdraws this live provider'} | ConvertTo-Json -Depth 8 | Set-Content "$out/public.json"
    $published = (Get-Content "$out/*.json" -Raw) -join "`n"
    foreach ($secret in @($configs.writer.RIGHTCLICK_PROOF_HOST_TOKEN, $configs.observer.RIGHTCLICK_PROOF_HOST_TOKEN, $controlToken)) {
        if ($published.Contains($secret)) { throw 'Refusing to publish an artifact containing an issued credential' }
    }
    $published = $null
    @{schemaVersion = 1; expiresAt = $expires.ToString('o'); base = $base; processes = $processes; users = $created; disconnectFile = $disconnect} | ConvertTo-Json | Set-Content (Join-Path $base 'supervisor.json')
    "RIGHTCLICK_WINDOWS_RELAY_STATE=$base" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
    Write-Host 'Authenticated native Windows writer and get-only observer TLS relays are ready; connection credentials are encrypted for the operator.'
} catch {
    foreach ($id in $processes) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    foreach ($name in $created) { Remove-LocalUser $name -ErrorAction SilentlyContinue }
    if (Test-Path $base) { Remove-Item $base -Recurse -Force }
    throw
}
