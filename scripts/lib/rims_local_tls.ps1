function Get-RimsLocalWorkspaceId {
  param([Parameter(Mandatory = $true)][string]$ScriptDirectory)

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  ).TrimEnd('\', '/')
  $bytes = [Text.Encoding]::UTF8.GetBytes($repositoryRoot.ToLowerInvariant())
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
  } finally {
    $sha256.Dispose()
  }
}

function Get-RimsLocalTlsPaths {
  param([Parameter(Mandatory = $true)][string]$ScriptDirectory)

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  $root = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot '.runtime\rims-local\tls')
  )
  $workspaceId = Get-RimsLocalWorkspaceId -ScriptDirectory $ScriptDirectory
  return [pscustomobject][ordered]@{
    repositoryRoot = $repositoryRoot
    workspaceId = $workspaceId
    root = $root
    opensslConfig = Join-Path $root 'openssl.cnf'
    caPrivateKey = Join-Path $root 'ca.key.pem'
    caCertificate = Join-Path $root 'ca.cert.pem'
    serverPrivateKey = Join-Path $root 'server.key.pem'
    serverRequest = Join-Path $root 'server.csr.pem'
    serverCertificate = Join-Path $root 'server.cert.pem'
    serverPfx = Join-Path $root 'server.pfx'
    caSerial = Join-Path $root 'ca.cert.srl'
    proxyScript = Join-Path $root 'proxy.ps1'
    proxyStdoutLog = Join-Path $root 'proxy.stdout.log'
    proxyStderrLog = Join-Path $root 'proxy.stderr.log'
  }
}

function Get-RimsLocalTlsPort {
  $configured = $env:RIMS_LOCAL_TLS_PORT
  $port = 8443
  if (-not [string]::IsNullOrWhiteSpace($configured) -and
      (-not [int]::TryParse($configured, [ref]$port) -or
        $port -lt 1 -or $port -gt 65535)) {
    throw 'RIMS_LOCAL_TLS_PORT must be an integer from 1 through 65535.'
  }
  return $port
}

function Test-RimsLocalTlsRuntimePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths
  )

  try {
    $root = [IO.Path]::GetFullPath([string]$TlsPaths.root).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath($Path)
    return $candidate.StartsWith(
      $root + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function New-RimsLocalTlsOpenSslConfig {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [string[]]$HostNames = @('localhost'),
    [string[]]$IpAddresses = @('127.0.0.1', '10.0.2.2')
  )

  $dnsEntries = @($HostNames | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
  $ipEntries = @($IpAddresses | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
  $altNames = New-Object 'Collections.Generic.List[string]'
  for ($index = 0; $index -lt $dnsEntries.Count; $index++) {
    [void]$altNames.Add("DNS.$($index + 1) = $($dnsEntries[$index])")
  }
  for ($index = 0; $index -lt $ipEntries.Count; $index++) {
    [void]$altNames.Add("IP.$($index + 1) = $($ipEntries[$index])")
  }
  $sanSummary = @(
    $dnsEntries | ForEach-Object { "DNS:$_" }
    $ipEntries | ForEach-Object { "IP:$_" }
  ) -join ','

  return @"
[req]
prompt = no
distinguished_name = server_dn
req_extensions = server_ext

[server_dn]
CN = localhost
OU = rims-local-$WorkspaceId

[server_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $sanSummary

[alt_names]
$($altNames -join "`n")
"@
}

function Invoke-RimsLocalWslOpenSsl {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject]@{
      exitCode = -1
      stdout = ''
      stderr = 'wsl.exe is unavailable.'
    }
  }
  $converted = New-Object 'Collections.Generic.List[string]'
  foreach ($argument in $Arguments) {
    if ($argument.StartsWith('winpath:')) {
      [void]$converted.Add((ConvertTo-RimsWslPath `
            -WindowsPath $argument.Substring(8) `
            -WslExecutable $wsl))
    } else {
      [void]$converted.Add($argument)
    }
  }
  $result = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments (@('-e', 'openssl') + @($converted)) `
    -TimeoutSeconds 30
  return [pscustomobject]@{
    exitCode = $result.ExitCode
    stdout = $result.StandardOutput
    stderr = $result.StandardError
  }
}

function Get-RimsLocalTlsCertificateFingerprint {
  param([Parameter(Mandatory = $true)][string]$CertificatePath)

  $result = Invoke-RimsLocalWslOpenSsl -Arguments @(
    'x509',
    '-in',
    "winpath:$CertificatePath",
    '-noout',
    '-fingerprint',
    '-sha256'
  )
  if ($result.exitCode -ne 0) {
    throw "OpenSSL certificate fingerprint failed: $($result.stderr)"
  }
  $match = [regex]::Match([string]$result.stdout, 'Fingerprint=([0-9A-Fa-f:]+)')
  if (-not $match.Success) {
    throw 'OpenSSL returned no SHA-256 certificate fingerprint.'
  }
  return $match.Groups[1].Value.Replace(':', '').ToUpperInvariant()
}

function Get-RimsLocalTlsSubjectHash {
  param([Parameter(Mandatory = $true)][string]$CertificatePath)

  $result = Invoke-RimsLocalWslOpenSsl -Arguments @(
    'x509', '-in', "winpath:$CertificatePath", '-noout', '-subject_hash_old'
  )
  if ($result.exitCode -ne 0) {
    throw "OpenSSL subject hash failed: $($result.stderr)"
  }
  $hash = ([string]$result.stdout).Trim().Split("`n")[0].Trim()
  if ($hash -notmatch '\A[0-9a-fA-F]{8}\z') {
    throw 'OpenSSL returned an invalid legacy subject hash.'
  }
  return $hash.ToLowerInvariant()
}

function New-RimsLocalTlsCertificates {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$OpenSslAction,
    [AllowNull()][scriptblock]$FingerprintAction,
    [AllowNull()][scriptblock]$CertificateValidationAction
  )

  foreach ($privatePath in @(
      $TlsPaths.caPrivateKey,
      $TlsPaths.serverPrivateKey,
      $TlsPaths.serverPfx
    )) {
    if (-not (Test-RimsLocalTlsRuntimePath `
        -Path $privatePath `
        -TlsPaths $TlsPaths)) {
      return [pscustomobject]@{ ok = $false; detail = 'TLS private path escaped the owned runtime.' }
    }
  }
  [void][IO.Directory]::CreateDirectory([string]$TlsPaths.root)
  $requiredMaterial = @(
    $TlsPaths.caPrivateKey,
    $TlsPaths.caCertificate,
    $TlsPaths.serverPrivateKey,
    $TlsPaths.serverCertificate,
    $TlsPaths.serverPfx
  )
  $materialExists = @($requiredMaterial | Where-Object {
      -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0
  if ($materialExists) {
    $validateCertificate = if ($null -eq $CertificateValidationAction) {
      { param($certificatePath, $caPath, $hostName)
        Test-RimsLocalTlsCertificate `
          -CertificatePath $certificatePath `
          -CaCertificatePath $caPath `
          -HostName $hostName
      }
    } else { $CertificateValidationAction }
    $validForAllHosts = $true
    foreach ($hostName in @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')) {
      $validation = & $validateCertificate `
        $TlsPaths.serverCertificate `
        $TlsPaths.caCertificate `
        $hostName
      if (-not [bool](Get-RimsObjectPropertyValue `
          -Value $validation `
          -Name 'ok' `
          -DefaultValue $false)) {
        $validForAllHosts = $false
        break
      }
    }
    if ($validForAllHosts) {
      $getExistingFingerprint = if ($null -eq $FingerprintAction) {
        { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
      } else { $FingerprintAction }
      return [pscustomobject][ordered]@{
        ok = $true
        detail = 'Reused valid workspace-scoped local TLS material.'
        workspaceId = $TlsPaths.workspaceId
        caCertificatePath = $TlsPaths.caCertificate
        serverCertificatePath = $TlsPaths.serverCertificate
        caFingerprintSha256 = [string](& $getExistingFingerprint $TlsPaths.caCertificate)
        serverFingerprintSha256 = [string](& $getExistingFingerprint $TlsPaths.serverCertificate)
        caSubjectHash = if ($null -eq $OpenSslAction) {
          Get-RimsLocalTlsSubjectHash -CertificatePath $TlsPaths.caCertificate
        } else { $TlsPaths.workspaceId.Substring(0, 8) }
        requiredSans = @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')
        privateKeysStoredUnderIgnoredRuntime = $true
        created = $false
      }
    }
  }
  $config = New-RimsLocalTlsOpenSslConfig `
    -WorkspaceId $TlsPaths.workspaceId `
    -HostNames @('localhost', 'rims.local') `
    -IpAddresses @('127.0.0.1', '10.0.2.2')
  [IO.File]::WriteAllText(
    [string]$TlsPaths.opensslConfig,
    $config,
    (New-Object Text.UTF8Encoding($false))
  )
  $invokeOpenSsl = if ($null -eq $OpenSslAction) {
    { param($arguments, $paths) Invoke-RimsLocalWslOpenSsl -Arguments $arguments }
  } else {
    $OpenSslAction
  }
  $commands = @(
    @(
      'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
      '-days', '30', '-subj', "/CN=RIMS Local CA $($TlsPaths.workspaceId)",
      '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
      '-addext', 'subjectKeyIdentifier=hash',
      '-keyout', "winpath:$($TlsPaths.caPrivateKey)",
      '-out', "winpath:$($TlsPaths.caCertificate)"
    ),
    @(
      'req', '-newkey', 'rsa:2048', '-sha256', '-nodes',
      '-config', "winpath:$($TlsPaths.opensslConfig)",
      '-keyout', "winpath:$($TlsPaths.serverPrivateKey)",
      '-out', "winpath:$($TlsPaths.serverRequest)"
    ),
    @(
      'x509', '-req', '-sha256', '-days', '14',
      '-in', "winpath:$($TlsPaths.serverRequest)",
      '-CA', "winpath:$($TlsPaths.caCertificate)",
      '-CAkey', "winpath:$($TlsPaths.caPrivateKey)",
      '-CAcreateserial',
      '-extfile', "winpath:$($TlsPaths.opensslConfig)",
      '-extensions', 'server_ext',
      '-out', "winpath:$($TlsPaths.serverCertificate)"
    ),
    @(
      'pkcs12', '-export', '-passout', 'pass:',
      '-inkey', "winpath:$($TlsPaths.serverPrivateKey)",
      '-in', "winpath:$($TlsPaths.serverCertificate)",
      '-certfile', "winpath:$($TlsPaths.caCertificate)",
      '-out', "winpath:$($TlsPaths.serverPfx)"
    )
  )
  try {
    foreach ($command in $commands) {
      $result = & $invokeOpenSsl $command $TlsPaths
      if ([int](Get-RimsObjectPropertyValue `
          -Value $result `
          -Name 'exitCode' `
          -DefaultValue -1) -ne 0) {
        $detail = [string](Get-RimsObjectPropertyValue `
            -Value $result `
            -Name 'stderr' `
            -DefaultValue 'OpenSSL failed without detail.')
        throw $detail
      }
    }
    foreach ($requiredPath in @(
        $TlsPaths.caPrivateKey,
        $TlsPaths.caCertificate,
        $TlsPaths.serverPrivateKey,
        $TlsPaths.serverCertificate
      )) {
      if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "OpenSSL did not create $([IO.Path]::GetFileName($requiredPath))."
      }
    }
    $getFingerprint = if ($null -eq $FingerprintAction) {
      { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
    } else {
      $FingerprintAction
    }
    return [pscustomobject][ordered]@{
      ok = $true
      detail = 'Generated a workspace-scoped local CA and HTTPS certificate.'
      workspaceId = $TlsPaths.workspaceId
      caCertificatePath = $TlsPaths.caCertificate
      serverCertificatePath = $TlsPaths.serverCertificate
      caFingerprintSha256 = [string](& $getFingerprint $TlsPaths.caCertificate)
      serverFingerprintSha256 = [string](& $getFingerprint $TlsPaths.serverCertificate)
      caSubjectHash = if ($null -eq $OpenSslAction) {
        Get-RimsLocalTlsSubjectHash -CertificatePath $TlsPaths.caCertificate
      } else {
        $TlsPaths.workspaceId.Substring(0, 8)
      }
      requiredSans = @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')
      privateKeysStoredUnderIgnoredRuntime = $true
      created = $true
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
    }
  }
}

function Test-RimsLocalTlsCertificate {
  param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$CaCertificatePath,
    [Parameter(Mandatory = $true)][string]$HostName,
    [AllowNull()][scriptblock]$OpenSslAction
  )

  $action = if ($null -eq $OpenSslAction) {
    { param($arguments) Invoke-RimsLocalWslOpenSsl -Arguments $arguments }
  } else {
    $OpenSslAction
  }
  $identityOption = 'verify_hostname'
  $parsedIp = [Net.IPAddress]::None
  if ([Net.IPAddress]::TryParse($HostName, [ref]$parsedIp)) {
    $identityOption = 'verify_ip'
  }
  $arguments = @(
    'verify',
    '-purpose', 'sslserver',
    "-$identityOption", $HostName,
    '-CAfile', "winpath:$CaCertificatePath",
    "winpath:$CertificatePath"
  )
  try {
    $result = & $action $arguments
    $exitCode = [int](Get-RimsObjectPropertyValue `
        -Value $result `
        -Name 'exitCode' `
        -DefaultValue -1)
    return [pscustomobject][ordered]@{
      ok = $exitCode -eq 0
      hostName = $HostName
      detail = if ($exitCode -eq 0) {
        'Certificate chain, validity, usage, and host identity are valid.'
      } else {
        ConvertTo-RimsDiagnosticSummary `
          -StandardOutput ([string](Get-RimsObjectPropertyValue -Value $result -Name 'stdout' -DefaultValue '')) `
          -StandardError ([string](Get-RimsObjectPropertyValue -Value $result -Name 'stderr' -DefaultValue 'Certificate verification failed.'))
      }
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      hostName = $HostName
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
    }
  }
}

function New-RimsLocalTlsProxyScript {
  return @'
param(
  [Parameter(Mandatory = $true)][string]$PfxPath,
  [Parameter(Mandatory = $true)][int]$ListenPort,
  [Parameter(Mandatory = $true)][int]$BackendPort,
  [Parameter(Mandatory = $true)][string]$OwnershipMarker,
  [Parameter(Mandatory = $true)][string]$ErrorLogPath
)
$ErrorActionPreference = 'Stop'
$keyStorageFlags =
  [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
  [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
  $PfxPath,
  '',
  $keyStorageFlags
)
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $ListenPort)
$listener.Start()
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    $backend = $null
    $ssl = $null
    try {
      $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false)
      $ssl.AuthenticateAsServer($certificate, $false, 3072, $false)
      $backend = New-Object Net.Sockets.TcpClient
      $backend.Connect('127.0.0.1', $BackendPort)
      $backendStream = $backend.GetStream()
      $toBackend = $ssl.CopyToAsync($backendStream)
      $toClient = $backendStream.CopyToAsync($ssl)
      [void][Threading.Tasks.Task]::WaitAny(@($toBackend, $toClient))
    } catch {
      $message = $_.Exception.Message -replace '[\r\n]+', ' '
      [IO.File]::AppendAllText($ErrorLogPath, "$message`n")
    } finally {
      if ($null -ne $ssl) { $ssl.Dispose() }
      if ($null -ne $backend) { $backend.Close() }
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
  $certificate.Dispose()
}
'@
}

function Start-RimsLocalTlsProxyProcess {
  param([Parameter(Mandatory = $true)][psobject]$Spec)

  $powerShell = (Get-Process -Id $PID).Path
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $Spec.proxyScript,
    '-PfxPath', $Spec.serverPfx,
    '-ListenPort', [string]$Spec.tlsPort,
    '-BackendPort', [string]$Spec.backendPort,
    '-OwnershipMarker', $Spec.ownershipMarker,
    '-ErrorLogPath', $Spec.stderrLogPath
  )
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $powerShell
  $startInfo.Arguments = ($arguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value $_
    }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $false
  $startInfo.RedirectStandardError = $false
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $identity = [pscustomobject]@{
    windowsPid = $process.Id
    windowsProcessStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    commandLine = "$powerShell $($startInfo.Arguments)"
  }
  $process.Dispose()
  return $identity
}

function Start-RimsLocalTlsProxy {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$BackendPort,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$TlsPort,
    [AllowNull()][scriptblock]$PortListeningAction,
    [AllowNull()][scriptblock]$StartProcessAction,
    [AllowNull()][scriptblock]$ReadinessAction,
    [AllowNull()][scriptblock]$PortOwnershipAction
  )

  $testListening = if ($null -eq $PortListeningAction) {
    { param($port) Test-RimsTcpPortListening -Port $port }
  } else { $PortListeningAction }
  if ([bool](& $testListening $TlsPort)) {
    return [pscustomobject]@{
      ok = $false
      detail = "TLS port $TlsPort has an unowned listener; it was left untouched."
    }
  }
  [void][IO.Directory]::CreateDirectory([string]$TlsPaths.root)
  [IO.File]::WriteAllText(
    [string]$TlsPaths.proxyScript,
    (New-RimsLocalTlsProxyScript),
    (New-Object Text.UTF8Encoding($false))
  )
  $marker = "rims-local-tls-proxy:$($TlsPaths.workspaceId)"
  $spec = [pscustomobject][ordered]@{
    proxyScript = $TlsPaths.proxyScript
    serverPfx = $TlsPaths.serverPfx
    backendPort = $BackendPort
    tlsPort = $TlsPort
    ownershipMarker = $marker
    stderrLogPath = $TlsPaths.proxyStderrLog
    commandLine = "powershell $($TlsPaths.proxyScript) $marker"
  }
  $start = if ($null -eq $StartProcessAction) {
    Start-RimsLocalTlsProxyProcess -Spec $spec
  } else {
    & $StartProcessAction $spec
  }
  $state = [pscustomobject][ordered]@{
    workspaceId = $TlsPaths.workspaceId
    port = $TlsPort
    backendPort = $BackendPort
    windowsPid = $start.windowsPid
    windowsProcessStartTimeUtc = $start.windowsProcessStartTimeUtc
    commandLine = $start.commandLine
    ownershipMarker = $marker
    proxyScriptPath = $TlsPaths.proxyScript
    stdoutLogPath = $TlsPaths.proxyStdoutLog
    stderrLogPath = $TlsPaths.proxyStderrLog
    cleanupPending = $true
  }
  $ready = if ($null -eq $ReadinessAction) {
    $deadline = (Get-Date).AddSeconds(15)
    $isReady = $false
    do {
      if (Test-RimsTcpPortListening -Port $TlsPort -TimeoutMilliseconds 250) {
        $isReady = $true
        break
      }
      Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    $isReady
  } else {
    [bool](& $ReadinessAction $state)
  }
  $testPortOwnership = if ($null -eq $PortOwnershipAction) {
    { param($port, $processId) Test-RimsFrontendPortOwnedByProcess -Port $port -RootProcessId $processId }
  } else { $PortOwnershipAction }
  $portOwned = [bool](& $testPortOwnership $TlsPort $state.windowsPid)
  if (-not $ready -or -not $portOwned) {
    [void](Stop-RimsLocalTlsProxy -TlsState $state)
    return [pscustomobject]@{
      ok = $false
      detail = if (-not $portOwned) {
        'TLS listener was not owned by the recorded process.'
      } else { 'TLS proxy did not become ready.' }
    }
  }
  $state.cleanupPending = $false
  return [pscustomobject]@{
    ok = $true
    detail = "Owned HTTPS proxy is listening on port $TlsPort."
    state = $state
  }
}

function Get-RimsProcessCommandLine {
  param([Parameter(Mandatory = $true)][int]$ProcessId)

  try {
    return [string](Get-CimInstance Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction Stop).CommandLine
  } catch {
    return ''
  }
}

function Test-RimsLocalTlsProxyOwnership {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsState,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$ProcessOwnershipAction,
    [AllowNull()][scriptblock]$PortOwnershipAction,
    [AllowNull()][scriptblock]$CommandLineAction
  )

  $processOwned = if ($null -eq $ProcessOwnershipAction) {
    Test-RimsStateOwnsProcess -State $TlsState
  } else { [bool](& $ProcessOwnershipAction $TlsState) }
  if (-not $processOwned) {
    return [pscustomobject]@{ ok = $false; detail = 'TLS PID/start-time ownership does not match.' }
  }
  $processId = [int]$TlsState.windowsPid
  $portOwned = if ($null -eq $PortOwnershipAction) {
    Test-RimsFrontendPortOwnedByProcess -Port ([int]$TlsState.port) -RootProcessId $processId
  } else { [bool](& $PortOwnershipAction ([int]$TlsState.port) $processId) }
  if (-not $portOwned) {
    return [pscustomobject]@{ ok = $false; detail = 'TLS port is not owned by the recorded process tree.' }
  }
  $commandLine = if ($null -eq $CommandLineAction) {
    Get-RimsProcessCommandLine -ProcessId $processId
  } else { [string](& $CommandLineAction $processId) }
  $marker = "rims-local-tls-proxy:$($TlsPaths.workspaceId)"
  $commandOwned = $commandLine.Contains($marker) -and
    $commandLine.Contains([string]$TlsPaths.proxyScript)
  return [pscustomobject]@{
    ok = $commandOwned
    detail = if ($commandOwned) {
      'TLS PID, start time, port, command line, and workspace marker match.'
    } else { 'TLS command line or workspace marker does not match.' }
  }
}

function New-RimsLocalTlsComponent {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][bool]$Required,
    [AllowNull()][scriptblock]$OwnershipAction,
    [AllowNull()][scriptblock]$CertificateAction
  )

  $tlsState = Get-RimsObjectPropertyValue -Value $State -Name 'localTls'
  if ($null -eq $tlsState) {
    return [pscustomobject][ordered]@{
      name = 'localTls'
      ok = -not $Required
      required = $Required
      detail = if ($Required) {
        'Local HTTPS was requested, but no owned TLS state exists.'
      } else { 'Local HTTPS is not enabled for this runtime.' }
      remediation = if ($Required) { 'Run up with -UseLocalTls.' } else { '' }
      enabled = $false
      workspaceId = $TlsPaths.workspaceId
      port = $null
      caFingerprintSha256 = $null
      serverFingerprintSha256 = $null
      requiredSans = @()
      proxyOwned = $false
      certificateValid = $false
    }
  }
  $proxyState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'proxy'
  $ownedResult = if ($null -eq $OwnershipAction) {
    Test-RimsLocalTlsProxyOwnership `
      -TlsState $proxyState `
      -TlsPaths $TlsPaths
  } else { & $OwnershipAction $proxyState $TlsPaths }
  $certificateResult = if ($null -eq $CertificateAction) {
    Test-RimsLocalTlsCertificate `
      -CertificatePath ([string]$tlsState.serverCertificatePath) `
      -CaCertificatePath ([string]$tlsState.caCertificatePath) `
      -HostName 'localhost'
  } else { & $CertificateAction $tlsState }
  $ok = [bool]$ownedResult.ok -and [bool]$certificateResult.ok
  return [pscustomobject][ordered]@{
    name = 'localTls'
    ok = $ok
    required = $Required
    detail = if ($ok) {
      'Owned local HTTPS proxy and certificate evidence are valid.'
    } else {
      "$($ownedResult.detail) $($certificateResult.detail)".Trim()
    }
    remediation = if ($ok) { '' } else {
      'Run down with the recorded runtime parameters, then retry up with -UseLocalTls.'
    }
    enabled = $true
    workspaceId = [string]$tlsState.workspaceId
    port = [int]$tlsState.port
    caFingerprintSha256 = [string]$tlsState.caFingerprintSha256
    serverFingerprintSha256 = [string]$tlsState.serverFingerprintSha256
    requiredSans = @($tlsState.requiredSans)
    proxyOwned = [bool]$ownedResult.ok
    certificateValid = [bool]$certificateResult.ok
  }
}

function Stop-RimsLocalTlsProxy {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsState,
    [AllowNull()][scriptblock]$StopAction
  )

  if ($null -ne $StopAction) {
    return & $StopAction $TlsState
  }
  $container = [pscustomobject]@{ tlsProxy = $TlsState }
  return Stop-RimsNestedOwnedProcess -State $container -PropertyName 'tlsProxy'
}

function Invoke-RimsAdbCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $result = Invoke-RimsExternalCommand `
    -FilePath $adb `
    -Arguments (@('-s', $Serial) + $Arguments) `
    -TimeoutSeconds 30
  return [pscustomobject]@{
    exitCode = $result.ExitCode
    stdout = $result.StandardOutput
    stderr = $result.StandardError
  }
}

function Get-RimsAndroidCaRemotePath {
  param([Parameter(Mandatory = $true)][string]$SubjectHash)
  if ($SubjectHash -notmatch '\A[0-9a-fA-F]{8}\z') {
    throw 'Android CA subject hash must contain exactly eight hexadecimal characters.'
  }
  return "/data/misc/user/0/cacerts-added/$($SubjectHash.ToLowerInvariant()).0"
}

function Test-RimsOwnedEmulatorState {
  param([Parameter(Mandatory = $true)][psobject]$EmulatorState)

  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $EmulatorState `
      -Name 'owned' `
      -DefaultValue $false)) {
    return $false
  }
  $container = [pscustomobject]@{ emulator = $EmulatorState }
  return Test-RimsNestedOwnedProcess -State $container -PropertyName 'emulator'
}

function Install-RimsAndroidUserCa {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][psobject]$EmulatorState,
    [Parameter(Mandatory = $true)][string]$CaFingerprintSha256,
    [AllowNull()][AllowEmptyString()][string]$CaSubjectHash,
    [AllowNull()][scriptblock]$EmulatorOwnershipAction,
    [AllowNull()][scriptblock]$TrustQueryAction,
    [AllowNull()][scriptblock]$AdbAction
  )

  $owned = if ($null -eq $EmulatorOwnershipAction) {
    Test-RimsOwnedEmulatorState -EmulatorState $EmulatorState
  } else { [bool](& $EmulatorOwnershipAction $EmulatorState) }
  if (-not $owned) {
    return [pscustomobject]@{ ok = $false; detail = 'Android CA install requires an exactly owned emulator.' }
  }
  $serial = [string]$EmulatorState.serial
  $subjectHash = if ([string]::IsNullOrWhiteSpace($CaSubjectHash)) {
    $TlsPaths.workspaceId.Substring(0, 8)
  } else { $CaSubjectHash }
  $remotePath = Get-RimsAndroidCaRemotePath -SubjectHash $subjectHash
  $adb = if ($null -eq $AdbAction) {
    { param($device, $arguments) Invoke-RimsAdbCommand -Serial $device -Arguments $arguments }
  } else { $AdbAction }
  $alreadyTrusted = if ($null -eq $TrustQueryAction) {
    $rootResult = & $adb $serial @('root')
    if ([int]$rootResult.exitCode -ne 0) {
      return [pscustomobject]@{
        ok = $false
        detail = 'Could not inspect Android user trust without root on the owned emulator.'
      }
    }
    $query = & $adb $serial @('shell', 'test', '-f', $remotePath)
    if ([int]$query.exitCode -eq 0) {
      $existingPath = Join-Path $TlsPaths.root 'android-existing-ca.pem'
      try {
        $pull = & $adb $serial @('pull', $remotePath, $existingPath)
        if ([int]$pull.exitCode -ne 0) {
          return [pscustomobject]@{
            ok = $false
            detail = 'Could not compare the pre-existing Android trust certificate.'
          }
        }
        $existingFingerprint = Get-RimsLocalTlsCertificateFingerprint `
          -CertificatePath $existingPath
        if ($existingFingerprint -ne $CaFingerprintSha256) {
          return [pscustomobject]@{
            ok = $false
            detail = 'Android trust path is occupied by a different certificate; it was left untouched.'
          }
        }
        $true
      } finally {
        Remove-Item -LiteralPath $existingPath -Force -ErrorAction SilentlyContinue
      }
    } else { $false }
  } else { [bool](& $TrustQueryAction $serial $CaFingerprintSha256) }
  if ($alreadyTrusted) {
    return [pscustomobject]@{
      ok = $true
      detail = 'The workspace CA was already trusted and remains user-managed.'
      state = [pscustomobject][ordered]@{
        serial = $serial
        fingerprintSha256 = $CaFingerprintSha256
        subjectHash = $subjectHash
        remotePath = $remotePath
        preExisting = $true
        installedByController = $false
      }
    }
  }
  $temporaryPath = "/data/local/tmp/rims-$($TlsPaths.workspaceId)-ca.pem"
  $commands = @(
    @('root'),
    @('push', [string]$TlsPaths.caCertificate, $temporaryPath),
    @('shell', 'mkdir', '-p', '/data/misc/user/0/cacerts-added'),
    @('shell', 'cp', $temporaryPath, $remotePath),
    @('shell', 'chmod', '644', $remotePath),
    @('shell', 'chown', 'system:system', $remotePath),
    @('shell', 'restorecon', $remotePath),
    @('shell', 'rm', '-f', $temporaryPath)
  )
  foreach ($arguments in $commands) {
    $result = & $adb $serial $arguments
    if ([int](Get-RimsObjectPropertyValue -Value $result -Name 'exitCode' -DefaultValue -1) -ne 0) {
      return [pscustomobject]@{
        ok = $false
        detail = 'Failed to install the owned CA on the owned emulator.'
      }
    }
  }
  return [pscustomobject]@{
    ok = $true
    detail = 'Installed the workspace CA in the owned emulator user trust store.'
    state = [pscustomobject][ordered]@{
      serial = $serial
      fingerprintSha256 = $CaFingerprintSha256
      subjectHash = $subjectHash
      remotePath = $remotePath
      preExisting = $false
      installedByController = $true
    }
  }
}

function Remove-RimsAndroidUserCa {
  param(
    [Parameter(Mandatory = $true)][psobject]$TrustState,
    [Parameter(Mandatory = $true)][psobject]$EmulatorState,
    [AllowNull()][scriptblock]$EmulatorOwnershipAction,
    [AllowNull()][scriptblock]$AdbAction
  )

  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'installedByController' `
      -DefaultValue $false)) {
    return [pscustomobject]@{
      ok = $true
      detail = 'Pre-existing Android trust was preserved.'
    }
  }
  $owned = if ($null -eq $EmulatorOwnershipAction) {
    Test-RimsOwnedEmulatorState -EmulatorState $EmulatorState
  } else { [bool](& $EmulatorOwnershipAction $EmulatorState) }
  if (-not $owned) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Owned Android trust could not be removed because emulator ownership no longer matches.'
    }
  }
  $adb = if ($null -eq $AdbAction) {
    { param($device, $arguments) Invoke-RimsAdbCommand -Serial $device -Arguments $arguments }
  } else { $AdbAction }
  $result = & $adb ([string]$TrustState.serial) @(
    'shell', 'rm', '-f', [string]$TrustState.remotePath
  )
  $ok = [int](Get-RimsObjectPropertyValue `
      -Value $result `
      -Name 'exitCode' `
      -DefaultValue -1) -eq 0
  return [pscustomobject]@{
    ok = $ok
    detail = if ($ok) { 'Removed only the controller-installed Android CA.' } else {
      'Failed to remove the controller-installed Android CA.'
    }
  }
}

function Remove-RimsLocalTlsCertificates {
  param([Parameter(Mandatory = $true)][psobject]$TlsPaths)

  try {
    if (Test-Path -LiteralPath $TlsPaths.root) {
      Remove-Item -LiteralPath $TlsPaths.root -Recurse -Force
    }
    return [pscustomobject]@{ ok = $true; detail = 'Removed owned local TLS material.' }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
    }
  }
}

function Stop-RimsLocalTlsRuntime {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$TrustRemoveAction,
    [AllowNull()][scriptblock]$OwnershipAction,
    [AllowNull()][scriptblock]$PortListeningAction,
    [AllowNull()][scriptblock]$ProxyStopAction,
    [AllowNull()][scriptblock]$CertificateCleanupAction
  )

  $tlsState = Get-RimsObjectPropertyValue -Value $State -Name 'localTls'
  if ($null -eq $tlsState) {
    return [pscustomobject]@{
      ok = $true
      detail = 'No owned local TLS runtime requires cleanup.'
      cleanupPending = $false
    }
  }
  $trustState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'androidTrust'
  $preserveCertificateMaterial = $null -ne $trustState -and
    [bool](Get-RimsObjectPropertyValue `
      -Value $trustState `
      -Name 'preExisting' `
      -DefaultValue $false)
  if ($null -ne $trustState) {
    $removeTrust = if ($null -eq $TrustRemoveAction) {
      { param($trust, $emulator)
        Remove-RimsAndroidUserCa -TrustState $trust -EmulatorState $emulator
      }
    } else { $TrustRemoveAction }
    $trustResult = & $removeTrust $trustState $State.emulator
    if (-not $trustResult.ok) {
      $tlsState.cleanupPending = $true
      return [pscustomobject]@{
        ok = $false
        detail = $trustResult.detail
        cleanupPending = $true
      }
    }
    $tlsState.androidTrust = $null
  }

  $proxyState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'proxy'
  if ($null -ne $proxyState) {
    $ownership = if ($null -eq $OwnershipAction) {
      Test-RimsLocalTlsProxyOwnership `
        -TlsState $proxyState `
        -TlsPaths $TlsPaths
    } else { & $OwnershipAction $proxyState $TlsPaths }
    if (-not $ownership.ok) {
      $testListening = if ($null -eq $PortListeningAction) {
        { param($port) Test-RimsTcpPortListening -Port $port }
      } else { $PortListeningAction }
      if ([bool](& $testListening ([int]$proxyState.port))) {
        $tlsState.cleanupPending = $true
        return [pscustomobject]@{
          ok = $false
          detail = "Refused to stop a TLS listener without exact ownership: $($ownership.detail)"
          cleanupPending = $true
        }
      }
    } else {
      $stopProxy = if ($null -eq $ProxyStopAction) {
        { param($proxy) Stop-RimsLocalTlsProxy -TlsState $proxy }
      } else { $ProxyStopAction }
      $proxyResult = & $stopProxy $proxyState
      if (-not $proxyResult.ok) {
        $tlsState.cleanupPending = $true
        return [pscustomobject]@{
          ok = $false
          detail = $proxyResult.detail
          cleanupPending = $true
        }
      }
    }
    $tlsState.proxy = $null
  }
  $cleanup = if ($preserveCertificateMaterial) {
    [pscustomobject]@{
      ok = $true
      detail = 'Preserved workspace CA material required by pre-existing trust.'
    }
  } elseif ($null -eq $CertificateCleanupAction) {
    Remove-RimsLocalTlsCertificates -TlsPaths $TlsPaths
  } else { & $CertificateCleanupAction $TlsPaths }
  if (-not $cleanup.ok) {
    $tlsState.cleanupPending = $true
    return [pscustomobject]@{
      ok = $false
      detail = $cleanup.detail
      cleanupPending = $true
    }
  }
  $State.localTls = $null
  return [pscustomobject]@{
    ok = $true
    detail = if ($preserveCertificateMaterial) {
      'Removed the owned HTTPS proxy and preserved pre-existing trust and its CA material.'
    } else { 'Removed owned Android trust, HTTPS proxy, and TLS material.' }
    cleanupPending = $false
  }
}

function Invoke-RimsLocalTlsUp {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][int]$BackendPort,
    [Parameter(Mandatory = $true)][int]$TlsPort,
    [Parameter(Mandatory = $true)][ValidateSet('none', 'web', 'android')][string]$Target,
    [AllowNull()][object]$EmulatorState,
    [AllowNull()][scriptblock]$CertificateAction,
    [AllowNull()][scriptblock]$ProxyStartAction,
    [AllowNull()][scriptblock]$TrustInstallAction,
    [AllowNull()][scriptblock]$ProxyStopAction,
    [AllowNull()][scriptblock]$CertificateCleanupAction
  )

  $createCertificates = if ($null -eq $CertificateAction) {
    { param($paths) New-RimsLocalTlsCertificates -TlsPaths $paths }
  } else { $CertificateAction }
  $startProxy = if ($null -eq $ProxyStartAction) {
    { param($paths, $backendPortValue, $tlsPortValue)
      Start-RimsLocalTlsProxy -TlsPaths $paths -BackendPort $backendPortValue -TlsPort $tlsPortValue
    }
  } else { $ProxyStartAction }
  $stopProxy = if ($null -eq $ProxyStopAction) {
    { param($state) Stop-RimsLocalTlsProxy -TlsState $state }
  } else { $ProxyStopAction }
  $cleanupCertificates = if ($null -eq $CertificateCleanupAction) {
    { param($paths) Remove-RimsLocalTlsCertificates -TlsPaths $paths }
  } else { $CertificateCleanupAction }

  $certificates = & $createCertificates $TlsPaths
  if (-not $certificates.ok) {
    return [pscustomobject]@{ ok = $false; detail = $certificates.detail }
  }
  $certificatesCreated = [bool](Get-RimsObjectPropertyValue `
      -Value $certificates `
      -Name 'created' `
      -DefaultValue $true)
  $proxy = & $startProxy $TlsPaths $BackendPort $TlsPort
  if (-not $proxy.ok) {
    if ($certificatesCreated) {
      [void](& $cleanupCertificates $TlsPaths)
    }
    return [pscustomobject]@{ ok = $false; detail = $proxy.detail }
  }
  $trust = $null
  if ($Target -eq 'android') {
    $installTrust = if ($null -eq $TrustInstallAction) {
      { param($paths, $emulator, $fingerprint, $subjectHash)
        Install-RimsAndroidUserCa `
          -TlsPaths $paths `
          -EmulatorState $emulator `
          -CaFingerprintSha256 $fingerprint `
          -CaSubjectHash $subjectHash
      }
    } else { $TrustInstallAction }
    $caSubjectHash = [string](Get-RimsObjectPropertyValue `
        -Value $certificates `
        -Name 'caSubjectHash' `
        -DefaultValue $TlsPaths.workspaceId.Substring(0, 8))
    $trust = & $installTrust `
      $TlsPaths `
      $EmulatorState `
      $certificates.caFingerprintSha256 `
      $caSubjectHash
    if (-not $trust.ok) {
      [void](& $stopProxy $proxy.state)
      if ($certificatesCreated) {
        [void](& $cleanupCertificates $TlsPaths)
      }
      return [pscustomobject]@{ ok = $false; detail = $trust.detail }
    }
  }
  return [pscustomobject]@{
    ok = $true
    detail = 'Local HTTPS runtime is ready.'
    state = [pscustomobject][ordered]@{
      workspaceId = $TlsPaths.workspaceId
      port = $TlsPort
      backendPort = $BackendPort
      caCertificatePath = $certificates.caCertificatePath
      serverCertificatePath = $certificates.serverCertificatePath
      caFingerprintSha256 = $certificates.caFingerprintSha256
      serverFingerprintSha256 = $certificates.serverFingerprintSha256
      caSubjectHash = [string](Get-RimsObjectPropertyValue `
          -Value $certificates `
          -Name 'caSubjectHash' `
          -DefaultValue $TlsPaths.workspaceId.Substring(0, 8))
      certificateCreated = $certificatesCreated
      requiredSans = @($certificates.requiredSans)
      proxy = $proxy.state
      androidTrust = if ($null -eq $trust) { $null } else { $trust.state }
      cleanupPending = $false
    }
  }
}
