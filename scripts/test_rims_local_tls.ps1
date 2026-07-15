$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$supportScript = Join-Path $scriptDir 'tests\test_rims_local_support.ps1'
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'
. $supportScript
. $commonScript

$testRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-local-tls-' + [guid]::NewGuid().ToString('N'))
$workspaceA = Join-Path $testRoot 'workspace-a'
$workspaceB = Join-Path $testRoot 'workspace-b'

function Get-RimsTlsTestPort {
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Get-RimsTlsPrivateKeyContainerSnapshot {
  $snapshot = [ordered]@{}
  foreach ($containerRoot in @(
      (Join-Path $env:APPDATA 'Microsoft\Crypto\RSA'),
      (Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys')
    )) {
    if (-not (Test-Path -LiteralPath $containerRoot -PathType Container)) {
      continue
    }
    foreach ($file in @(Get-ChildItem `
        -LiteralPath $containerRoot `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue)) {
      $snapshot[$file.FullName] = '{0}:{1}' -f `
        $file.LastWriteTimeUtc.Ticks, `
        $file.Length
    }
  }
  return $snapshot
}

function Assert-RimsTlsPrivateKeySnapshotEqual {
  param(
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Before,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$After,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $changes = @()
  foreach ($path in $After.Keys) {
    if (-not $Before.Contains($path)) {
      $changes += "new:$path"
    } elseif ($Before[$path] -ne $After[$path]) {
      $changes += "changed:$path"
    }
  }
  if ($changes.Count -gt 0) {
    throw "$Message Changes: $($changes -join ', ')"
  }
}

function Wait-RimsTlsTestTask {
  param(
    [Parameter(Mandatory = $true)][Threading.Tasks.Task]$Task,
    [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Task.Wait($TimeoutMilliseconds)) {
    throw $Message
  }
  return $Task.GetAwaiter().GetResult()
}

function Write-RimsTlsTestStage {
  param([Parameter(Mandatory = $true)][string]$Name)

  Write-Output "[TLS TEST] $Name"
}

try {
  Write-RimsTlsTestStage -Name 'wrapper and safe JSON contracts'
  [void][IO.Directory]::CreateDirectory((Join-Path $workspaceA 'scripts'))
  [void][IO.Directory]::CreateDirectory((Join-Path $workspaceB 'scripts'))

  $localCommand = Get-Command `
    -Name (Join-Path $scriptDir 'rims_local.ps1') `
    -CommandType ExternalScript
  Assert-True `
    -Value $localCommand.Parameters.ContainsKey('UseLocalTls') `
    -Message 'The local command wrapper did not declare -UseLocalTls.'
  foreach ($lifecycleCommand in @(
      'Invoke-RimsLocalHealth',
      'Invoke-RimsLocalRestart',
      'Invoke-RimsLocalReset'
    )) {
    Assert-True `
      -Value (Get-Command $lifecycleCommand).Parameters.ContainsKey('UseLocalTls') `
      -Message "$lifecycleCommand does not explicitly handle -UseLocalTls."
  }
  $plainRecordedState = [pscustomobject]@{ localTls = $null }
  $tlsRecordedState = [pscustomobject]@{ localTls = [pscustomobject]@{ workspaceId = 'fake' } }
  Assert-True `
    -Value (Test-RimsLocalTlsModeMatchesState -State $tlsRecordedState -UseLocalTls) `
    -Message 'Restart TLS mode rejected matching recorded TLS state.'
  Assert-False `
    -Value (Test-RimsLocalTlsModeMatchesState -State $tlsRecordedState) `
    -Message 'Restart silently downgraded recorded TLS state.'
  Assert-False `
    -Value (Test-RimsLocalTlsModeMatchesState -State $plainRecordedState -UseLocalTls) `
    -Message 'Restart silently upgraded a recorded HTTP state.'
  $resetTls = Invoke-RimsLocalResetUnlocked `
    -Target none `
    -ScriptDirectory $scriptDir `
    -BackendDir '' `
    -BackendWorkspaceRoot '' `
    -BackendPort 8080 `
    -UseLocalTls
  Assert-False `
    -Value $resetTls.ok `
    -Message 'Reset silently ignored -UseLocalTls.'
  Assert-True `
    -Value (($resetTls.errors -join ' ').Contains('UseLocalTls')) `
    -Message 'Reset TLS rejection did not explain the inconsistent option.'
  $repositoryTlsPaths = Get-RimsLocalTlsPaths -ScriptDirectory $scriptDir
  $wrapperSource = [IO.File]::ReadAllText((Join-Path $scriptDir 'rims_local.ps1'))
  foreach ($forwardingPattern in @(
      '''health''[\s\S]*?-UseLocalTls:\$UseLocalTls',
      '''restart''[\s\S]*?-UseLocalTls:\$UseLocalTls',
      '''reset''[\s\S]*?-UseLocalTls:\$UseLocalTls'
    )) {
    Assert-True `
      -Value ([regex]::IsMatch($wrapperSource, $forwardingPattern)) `
      -Message 'The CLI wrapper silently dropped -UseLocalTls for a lifecycle command.'
  }
  $readmeSource = [IO.File]::ReadAllText((Join-Path $repositoryTlsPaths.repositoryRoot 'README.md'))
  Assert-True `
    -Value ($readmeSource.Contains('10.0.2.2') -and $readmeSource.Contains('host loopback')) `
    -Message 'README does not explain the Android emulator special alias to host loopback.'
  Assert-True `
    -Value ($readmeSource.Contains('SPKI') -and $readmeSource.Contains('temporary Chrome')) `
    -Message 'README does not explain isolated Web SPKI trust.'
  Assert-True `
    -Value ($readmeSource.Contains('WSL Go TLS proxy') -and
      $readmeSource.Contains('Linux process identity')) `
    -Message 'README does not explain the WSL Go TLS proxy ownership boundary.'
  $tlsLibrarySource = [IO.File]::ReadAllText((Join-Path $scriptDir 'lib\rims_local_tls.ps1'))
  Assert-True `
    -Value ($tlsLibrarySource.Contains("'-pubkey'") -and
      $tlsLibrarySource.Contains('BEGIN PUBLIC KEY')) `
    -Message 'SPKI calculation does not use WSL OpenSSL public-key output.'
  Assert-False `
    -Value $tlsLibrarySource.Contains('ExportSubjectPublicKeyInfo') `
    -Message 'SPKI calculation depends on a PowerShell 7-only key export API.'
  $debugManifestPath = Join-Path `
    $repositoryTlsPaths.repositoryRoot `
    'rims_frontend\android\app\src\debug\AndroidManifest.xml'
  $debugNetworkConfigPath = Join-Path `
    $repositoryTlsPaths.repositoryRoot `
    'rims_frontend\android\app\src\debug\res\xml\rims_local_network_security_config.xml'
  Assert-True `
    -Value (Test-Path -LiteralPath $debugNetworkConfigPath -PathType Leaf) `
    -Message 'Debug Android user-CA trust config is missing.'
  $debugManifestText = [IO.File]::ReadAllText($debugManifestPath)
  $debugNetworkConfigText = [IO.File]::ReadAllText($debugNetworkConfigPath)
  Assert-True `
    -Value $debugManifestText.Contains('@xml/rims_local_network_security_config') `
    -Message 'Debug Android manifest does not select local TLS trust config.'
  Assert-True `
    -Value $debugNetworkConfigText.Contains('certificates src="user"') `
    -Message 'Debug Android config does not trust the installed user CA.'
  $legacyTlsSmoke = Invoke-LocalCli -Arguments @(
    '-Command', 'smoke',
    '-Target', 'web',
    '-Output', 'Json',
    '-UseLocalTls'
  )
  Assert-Equal `
    -Actual $legacyTlsSmoke.ExitCode `
    -Expected 2 `
    -Message 'Legacy smoke did not refuse unverified TLS migration.'
  $legacyTlsSmokeResult = ConvertFrom-SingleJson `
    -Text $legacyTlsSmoke.StandardOutput `
    -Context 'Legacy TLS smoke refusal'
  Assert-False `
    -Value $legacyTlsSmokeResult.ok `
    -Message 'Legacy TLS smoke emitted successful HTTP evidence.'

  $secretWindowsPath = 'E:\SECRET-rims-json-success\tls\server.pfx'
  $secretWslPath = '/mnt/e/SECRET-rims-json-failure/tls/ca.key'
  $secretDoctor = Invoke-LocalCli -Arguments @(
    '-Command', 'doctor',
    '-Target', 'web',
    '-Output', 'Json',
    '-UseLocalTls',
    '-BackendDir', $secretWindowsPath,
    '-BackendWorkspaceRoot', $secretWslPath
  )
  Assert-False `
    -Value $secretDoctor.StandardOutput.Contains('SECRET-rims-json') `
    -Message 'TLS doctor JSON leaked an arbitrary Windows or WSL absolute path.'
  $secretDoctorText = Invoke-LocalCli -Arguments @(
    '-Command', 'doctor',
    '-Target', 'web',
    '-Output', 'Text',
    '-UseLocalTls',
    '-BackendDir', $secretWindowsPath,
    '-BackendWorkspaceRoot', $secretWslPath
  )
  Assert-True `
    -Value $secretDoctorText.StandardOutput.Contains('SECRET-rims-json') `
    -Message 'Text doctor lost actionable absolute-path diagnostics.'

  foreach ($jsonBoundaryCase in @(
      [pscustomobject]@{ command = 'doctor'; ok = $true; mode = 'success' },
      [pscustomobject]@{ command = 'up'; ok = $false; mode = 'failure' },
      [pscustomobject]@{ command = 'status'; ok = $true; mode = 'success' },
      [pscustomobject]@{ command = 'logs'; ok = $false; mode = 'exception' },
      [pscustomobject]@{ command = 'down'; ok = $true; mode = 'success' }
    )) {
    $boundaryResult = New-RimsLocalResult -Command $jsonBoundaryCase.command
    $boundaryResult.components = @(
      [pscustomobject][ordered]@{
        name = 'localTls'
        ok = $jsonBoundaryCase.ok
        detail = "Result uses $secretWindowsPath"
        nested = [pscustomobject]@{
          certificatePath = $secretWindowsPath
          events = @(
            [pscustomobject]@{
              error = "Injected $($jsonBoundaryCase.mode) at $secretWslPath"
            }
          )
        }
      }
    )
    $boundaryResult.errors = @(
      "Injected $($jsonBoundaryCase.mode): $secretWslPath"
    )
    $boundaryResult = Complete-RimsLocalResult `
      -Result $boundaryResult `
      -Ok $jsonBoundaryCase.ok `
      -ExitCode $(if ($jsonBoundaryCase.ok) { 0 } else { 2 })
    $safeJson = ConvertTo-RimsLocalSafeJson -Result $boundaryResult
    Assert-False `
      -Value $safeJson.Contains('SECRET-rims-json') `
      -Message "$($jsonBoundaryCase.command) JSON leaked a deep absolute path."
    Assert-True `
      -Value ($safeJson.Contains('pathId') -and
        $safeJson.Contains('category') -and
        $safeJson.Contains('exists')) `
      -Message "$($jsonBoundaryCase.command) JSON omitted safe path metadata."
  }

  $posixSecretResult = New-RimsLocalResult -Command 'doctor'
  $posixSecretResult.components = @(
    [pscustomobject]@{
      name = 'localTls'
      purePath = '/home/SECRET-posix-pure/tls/server.pem'
      nested = @(
        [pscustomobject]@{
          temporaryPath = '/tmp/SECRET-posix-nested/ca.pem'
          exception = New-Object InvalidOperationException(
            'failed at /var/lib/SECRET-posix-exception/private.key')
        }
      )
      detail = 'mixed /usr/local/SECRET-posix-mixed/server.pfx; retry denied'
      url = 'https://example.test/home/SAFE-URL/resource'
      ordinarySlashText = 'docs/guide/SAFE-SLASH remains diagnostic'
    }
  )
  $posixSafeJson = ConvertTo-RimsLocalSafeJson -Result $posixSecretResult
  foreach ($secretMarker in @(
      'SECRET-posix-pure',
      'SECRET-posix-nested',
      'SECRET-posix-exception',
      'SECRET-posix-mixed'
    )) {
    Assert-False `
      -Value $posixSafeJson.Contains($secretMarker) `
      -Message "Safe JSON leaked POSIX path marker $secretMarker."
  }
  Assert-True `
    -Value $posixSafeJson.Contains('posixAbsolutePath') `
    -Message 'Safe JSON omitted POSIX path metadata.'
  Assert-True `
    -Value ($posixSafeJson.Contains('https://example.test/home/SAFE-URL/resource') -and
      $posixSafeJson.Contains('docs/guide/SAFE-SLASH remains diagnostic')) `
    -Message 'Safe JSON incorrectly treated a URL or ordinary slash text as a local path.'

  $webSpkiPin = [Convert]::ToBase64String([byte[]](0..31))
  $missingWebPinRejected = $false
  try {
    [void](New-FlutterLaunchSpec `
        -Target web `
        -FrontendDirectory (Join-Path $workspaceA 'rims_frontend') `
        -BackendPort 8080 `
        -FrontendPort 8091 `
        -UseLocalTls `
        -TlsPort 8443)
  } catch {
    $missingWebPinRejected = $true
  }
  Assert-True `
    -Value $missingWebPinRejected `
    -Message 'TLS Web launch accepted a missing SPKI pin.'

  $webLaunch = New-FlutterLaunchSpec `
    -Target web `
    -FrontendDirectory (Join-Path $workspaceA 'rims_frontend') `
    -BackendPort 8080 `
    -FrontendPort 8091 `
    -UseLocalTls `
    -TlsPort 8443 `
    -TlsSpkiPin $webSpkiPin
  Assert-Contains `
    -Collection $webLaunch.arguments `
    -Expected '--dart-define=ALLOW_LOCAL_HTTP=false' `
    -Message 'TLS Web launch did not disable local HTTP.'
  Assert-Contains `
    -Collection $webLaunch.arguments `
    -Expected '--dart-define=API_BASE_URL=https://localhost:8443/api/v1' `
    -Message 'TLS Web launch did not use the owned HTTPS proxy.'
  Assert-Contains `
    -Collection $webLaunch.arguments `
    -Expected "--web-browser-flag=--ignore-certificate-errors-spki-list=$webSpkiPin" `
    -Message 'TLS Web launch did not scope temporary Chrome trust to the server SPKI pin.'
  $tlsWebDeviceIndex = [Array]::IndexOf([object[]]$webLaunch.arguments, '-d')
  Assert-Equal `
    -Actual $webLaunch.arguments[$tlsWebDeviceIndex + 1] `
    -Expected 'chrome' `
    -Message 'TLS Web launch did not isolate SPKI trust in Flutter temporary Chrome.'
  Assert-False `
    -Value (@($webLaunch.arguments) -contains '--web-browser-flag=--ignore-certificate-errors') `
    -Message 'TLS Web launch used an unconstrained certificate-error bypass.'
  $httpWebLaunch = New-FlutterLaunchSpec `
    -Target web `
    -FrontendDirectory (Join-Path $workspaceA 'rims_frontend') `
    -BackendPort 8080 `
    -FrontendPort 8091
  $httpWebDeviceIndex = [Array]::IndexOf([object[]]$httpWebLaunch.arguments, '-d')
  Assert-Equal `
    -Actual $httpWebLaunch.arguments[$httpWebDeviceIndex + 1] `
    -Expected 'web-server' `
    -Message 'Legacy local HTTP Web launch no longer uses its explicit web-server device.'

  $edgeOnlyDevices = @(
    [pscustomobject]@{ id = 'edge'; targetPlatform = 'web-javascript' }
  ) | ConvertTo-Json -Compress
  $edgeOnlyDoctor = Test-RimsWebDeviceComponent `
    -FlutterExecutable 'fake-flutter' `
    -Required $true `
    -RequiredDeviceId 'chrome' `
    -DeviceQueryAction {
      param($flutter)
      return [pscustomobject]@{
        ExitCode = 0
        StandardOutput = $edgeOnlyDevices
        StandardError = ''
      }
    }
  Assert-False `
    -Value $edgeOnlyDoctor.ok `
    -Message 'TLS Web doctor accepted Edge without Flutter device ID chrome.'
  $chromeDoctor = Test-RimsWebDeviceComponent `
    -FlutterExecutable 'fake-flutter' `
    -Required $true `
    -RequiredDeviceId 'chrome' `
    -DeviceQueryAction {
      param($flutter)
      return [pscustomobject]@{
        ExitCode = 0
        StandardOutput = (@(
            [pscustomobject]@{ id = 'chrome'; targetPlatform = 'web-javascript' }
          ) | ConvertTo-Json -Compress)
        StandardError = ''
      }
    }
  Assert-True `
    -Value $chromeDoctor.ok `
    -Message 'TLS Web doctor rejected Flutter device ID chrome.'
  $doctorSource = [IO.File]::ReadAllText((Join-Path $scriptDir 'lib\rims_local_doctor.ps1'))
  Assert-True `
    -Value $doctorSource.Contains("if (`$UseLocalTls -and `$Target -eq 'web') { 'chrome' }") `
    -Message 'Doctor does not request Chrome specifically for TLS Web.'
  $androidLaunch = New-FlutterLaunchSpec `
    -Target android `
    -FrontendDirectory (Join-Path $workspaceA 'rims_frontend') `
    -BackendPort 8080 `
    -FrontendPort 8091 `
    -AndroidSerial 'emulator-5556' `
    -UseLocalTls `
    -TlsPort 8443
  Assert-Contains `
    -Collection $androidLaunch.arguments `
    -Expected '--dart-define=API_BASE_URL=https://10.0.2.2:8443/api/v1' `
    -Message 'TLS Android launch did not use the emulator HTTPS host.'

  $pathsA = Get-RimsLocalTlsPaths `
    -ScriptDirectory (Join-Path $workspaceA 'scripts')
  $pathsB = Get-RimsLocalTlsPaths `
    -ScriptDirectory (Join-Path $workspaceB 'scripts')
  Assert-Equal `
    -Actual ([string](Get-RimsObjectPropertyValue `
        -Value $pathsA `
        -Name 'proxySource' `
        -DefaultValue '')) `
    -Expected (Join-Path $pathsA.root 'proxy.go') `
    -Message 'TLS paths omitted deterministic WSL Go proxy source.'
  Assert-Equal `
    -Actual ([string](Get-RimsObjectPropertyValue `
        -Value $pathsA `
        -Name 'proxyBinary' `
        -DefaultValue '')) `
    -Expected (Join-Path $pathsA.root 'rims-local-tls-proxy') `
    -Message 'TLS paths omitted deterministic WSL Go proxy binary.'
  Assert-Equal `
    -Actual ([string](Get-RimsObjectPropertyValue `
        -Value $pathsA `
        -Name 'proxyLinuxIdentity' `
        -DefaultValue '')) `
    -Expected (Join-Path $pathsA.root 'proxy.linux-identity.json') `
    -Message 'TLS paths omitted deterministic Linux identity evidence.'
  $goProxySource = New-RimsLocalTlsProxySource
  foreach ($goProxyPattern in @(
      'tls.LoadX509KeyPair',
      'net.Listen("tcp", "127.0.0.1:"',
      'go func()',
      'io.Copy',
      'signal.NotifyContext'
    )) {
    Assert-True `
      -Value $goProxySource.Contains($goProxyPattern) `
      -Message "WSL Go TLS proxy omitted required pattern: $goProxyPattern"
  }
  Assert-False `
    -Value ($goProxySource.Contains('0.0.0.0') -or
      $goProxySource.Contains('[::]')) `
    -Message 'WSL Go TLS proxy source exposed a non-loopback listener.'
  Assert-True `
    -Value $goProxySource.Contains('func handleConnection(ctx context.Context') `
    -Message 'WSL Go TLS proxy does not pass cancellation into active connections.'
  Assert-True `
    -Value $goProxySource.Contains('case <-ctx.Done():') `
    -Message 'WSL Go TLS proxy does not close active connections on shutdown.'
  foreach ($safeGoFailureCategory in @(
      'certificate load failed',
      'listener start failed'
    )) {
    Assert-True `
      -Value $goProxySource.Contains($safeGoFailureCategory) `
      -Message "WSL Go TLS proxy omitted safe failure category: $safeGoFailureCategory"
  }
  Assert-False `
    -Value $goProxySource.Contains('log.Fatal(err)') `
    -Message 'WSL Go TLS proxy logs raw lower-level errors that can contain secret paths.'
  $tlsLibrarySource = [IO.File]::ReadAllText(
    (Join-Path $scriptDir 'lib\rims_local_tls.ps1')
  )
  Assert-False `
    -Value ([regex]::IsMatch($tlsLibrarySource, '\.WaitForExit\(\s*\)')) `
    -Message 'TLS process compensation retained an unbounded WaitForExit call.'
  foreach ($retiredProxyPattern in @(
      'EphemeralKeySet',
      'X509Certificate2',
      'ConcurrentTlsProxy',
      'Start-RimsLegacyLocalTlsProxyProcess'
    )) {
    Assert-False `
      -Value $tlsLibrarySource.Contains($retiredProxyPattern) `
      -Message "Retired Windows TLS proxy path remains: $retiredProxyPattern"
  }
  Assert-NotEqual `
    -Actual $pathsA.workspaceId `
    -Expected $pathsB.workspaceId `
    -Message 'TLS CA identity was not scoped to the workspace.'
  Assert-True `
    -Value $pathsA.root.StartsWith((Join-Path $workspaceA '.runtime\rims-local\tls')) `
    -Message 'TLS secrets were not rooted under the workspace ignored runtime.'
  foreach ($secretPath in @(
      $pathsA.caPrivateKey,
      $pathsA.serverPrivateKey,
      $pathsA.proxyScript
    )) {
    Assert-True `
      -Value (Test-RimsLocalTlsRuntimePath -Path $secretPath -TlsPaths $pathsA) `
      -Message 'TLS private/runtime path escaped the owned ignored directory.'
  }
  foreach ($ignoredPath in @(
      $repositoryTlsPaths.caPrivateKey,
      $repositoryTlsPaths.serverPrivateKey,
      $repositoryTlsPaths.proxyScript
    )) {
    & git -C $repositoryTlsPaths.repositoryRoot check-ignore -q -- $ignoredPath
    Assert-Equal `
      -Actual $LASTEXITCODE `
      -Expected 0 `
      -Message 'A TLS private/runtime path is not covered by gitignore.'
  }

  $config = New-RimsLocalTlsOpenSslConfig `
    -WorkspaceId $pathsA.workspaceId `
    -HostNames @('localhost', 'rims.local') `
    -IpAddresses @('127.0.0.1', '10.0.2.2')
  foreach ($requiredSan in @(
      'DNS:localhost',
      'DNS:rims.local',
      'IP:127.0.0.1',
      'IP:10.0.2.2'
    )) {
    Assert-True `
      -Value $config.Contains($requiredSan) `
      -Message "OpenSSL config omitted required SAN '$requiredSan'."
  }
  Assert-True `
    -Value $config.Contains($pathsA.workspaceId) `
    -Message 'Certificate identity omitted the per-workspace identifier.'

  $opensslCalls = New-Object 'Collections.Generic.List[object]'
  $certificateResult = New-RimsLocalTlsCertificates `
    -TlsPaths $pathsA `
    -OpenSslAction {
      param($arguments, $invocationPaths)
      [void]$opensslCalls.Add([pscustomobject]@{
          arguments = @($arguments)
          paths = $invocationPaths
        })
      foreach ($path in @(
          $invocationPaths.caPrivateKey,
          $invocationPaths.caCertificate,
          $invocationPaths.serverPrivateKey,
          $invocationPaths.serverCertificate,
          $invocationPaths.serverPfx
        )) {
        [IO.File]::WriteAllText($path, "fake:$([IO.Path]::GetFileName($path))")
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SpkiPinAction { param($path) return $webSpkiPin }
  Assert-True -Value $certificateResult.ok -Message 'Fake certificate generation failed.'
  Assert-Equal `
    -Actual $certificateResult.serverSpkiSha256 `
    -Expected $webSpkiPin `
    -Message 'Server certificate evidence omitted its SHA-256 SPKI pin.'
  Assert-True `
    -Value ($opensslCalls.Count -ge 2) `
    -Message 'Certificate generation did not invoke the fake OpenSSL boundary.'
  $opensslArgumentText = @($opensslCalls | ForEach-Object {
      $_.arguments -join ' '
    }) -join "`n"
  Assert-True `
    -Value $opensslArgumentText.Contains('basicConstraints=critical,CA:TRUE') `
    -Message 'Local CA generation omitted the critical CA constraint.'
  Assert-True `
    -Value $opensslArgumentText.Contains('keyUsage=critical,keyCertSign,cRLSign') `
    -Message 'Local CA generation omitted certificate-signing key usage.'
  Assert-Equal `
    -Actual $certificateResult.caFingerprintSha256.Length `
    -Expected 64 `
    -Message 'CA evidence did not contain a SHA-256 fingerprint.'
  $certificateJson = $certificateResult | ConvertTo-Json -Depth 8
  Assert-False `
    -Value $certificateJson.Contains('fake:ca.key.pem') `
    -Message 'Certificate evidence leaked private-key content.'
  $reuseOpenSslCalls = 0
  $reusedCertificates = New-RimsLocalTlsCertificates `
    -TlsPaths $pathsA `
    -OpenSslAction {
      param($arguments, $paths)
      $script:reuseOpenSslCalls++
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SpkiPinAction { param($path) return $webSpkiPin } `
    -CertificateValidationAction {
      param($certificatePath, $caPath, $hostName)
      return [pscustomobject]@{ ok = $true }
    }
  Assert-True `
    -Value $reusedCertificates.ok `
    -Message 'Valid workspace TLS material was not reusable.'
  Assert-Equal `
    -Actual $reuseOpenSslCalls `
    -Expected 0 `
    -Message 'Reusable workspace CA was unexpectedly regenerated.'

  foreach ($verificationCase in @(
      [pscustomobject]@{ name = 'expired'; detail = 'certificate has expired' },
      [pscustomobject]@{ name = 'wrong-host'; detail = 'hostname mismatch' },
      [pscustomobject]@{ name = 'untrusted'; detail = 'unable to get local issuer certificate' }
    )) {
    $verification = Test-RimsLocalTlsCertificate `
      -CertificatePath $pathsA.serverCertificate `
      -CaCertificatePath $pathsA.caCertificate `
      -HostName 'localhost' `
      -OpenSslAction {
        param($arguments)
        return [pscustomobject]@{
          exitCode = 2
          stdout = ''
          stderr = $verificationCase.detail
        }
      }
    Assert-False `
      -Value $verification.ok `
      -Message "TLS verification accepted $($verificationCase.name) certificate."
  }

  $startCalls = 0
  $unownedStart = Start-RimsLocalTlsProxy `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -PortListeningAction { param($port) return $true } `
    -StartProcessAction {
      param($spec)
      $script:startCalls++
      throw 'must not start'
    }
  Assert-False `
    -Value $unownedStart.ok `
    -Message 'TLS proxy accepted an unowned listener.'
  Assert-Equal `
    -Actual $startCalls `
    -Expected 0 `
    -Message 'TLS proxy spawned despite an occupied unowned port.'

  $script:startedProcessCompensated = $false
  $script:startedProcessWaitTimeout = $null
  $script:proxyRuntimeExecutable = $null
  Write-RimsTlsTestStage -Name 'process start and compensation seams'
  $fakeStartedProcess = [pscustomobject]@{
    StartInfo = $null
    Id = 4343
    HasExited = $false
  }
  $fakeStartedProcess | Add-Member -MemberType ScriptMethod -Name Start -Value {
    $script:proxyRuntimeExecutable = $this.StartInfo.FileName
    return $true
  }
  $fakeStartedProcess | Add-Member -MemberType ScriptProperty -Name StartTime -Value {
    throw 'fake start-time read failure after process start'
  }
  $fakeStartedProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    $script:startedProcessCompensated = $true
  }
  $fakeStartedProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($timeoutMilliseconds)
    $script:startedProcessWaitTimeout = $timeoutMilliseconds
    return $true
  }
  $fakeStartedProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
  $startThenIdentityThrow = Start-RimsLocalTlsProxyProcess `
    -Spec ([pscustomobject]@{
      proxySource = $pathsA.proxySource
      proxyBinary = $pathsA.proxyBinary
      linuxIdentityPath = $pathsA.proxyLinuxIdentity
      serverCertificate = $pathsA.serverCertificate
      serverPrivateKey = $pathsA.serverPrivateKey
      tlsPort = 8443
      backendPort = 8080
      ownershipMarker = "rims-local-tls-proxy:$($pathsA.workspaceId)"
      stderrLogPath = $pathsA.proxyStderrLog
      stdoutLogPath = $pathsA.proxyStdoutLog
    }) `
    -BuildAction { param($spec) return [pscustomobject]@{ ok = $true } } `
    -PathConversionAction { param($path) return "/mnt/c/fake/$([IO.Path]::GetFileName($path))" } `
    -ProcessFactoryAction { return $fakeStartedProcess }
  Assert-False `
    -Value $startThenIdentityThrow.ok `
    -Message 'Proxy process identity read throw was reported as a successful start.'
  Assert-True `
    -Value $script:startedProcessCompensated `
    -Message 'Started proxy wrapper was not killed after identity acquisition threw.'
  Assert-True `
    -Value $startThenIdentityThrow.cleanupPending `
    -Message 'Killing only the WSL wrapper incorrectly proved the Linux proxy was clean.'
  Assert-True `
    -Value ($null -ne $startThenIdentityThrow.state) `
    -Message 'Missing published identity did not return persistable partial proxy state.'
  Assert-Equal `
    -Actual $startThenIdentityThrow.state.windowsPid `
    -Expected 4343 `
    -Message 'Partial proxy state lost the Windows PID after identity recovery failed.'
  Assert-Equal `
    -Actual $startThenIdentityThrow.state.linuxIdentityPath `
    -Expected $pathsA.proxyLinuxIdentity `
    -Message 'Partial proxy state lost the deterministic published identity path.'
  Assert-Equal `
    -Actual $script:startedProcessWaitTimeout `
    -Expected 3000 `
    -Message 'Started proxy compensation did not use the bounded exit wait.'
  Assert-Equal `
    -Actual ([IO.Path]::GetFileName($script:proxyRuntimeExecutable)) `
    -Expected 'wsl.exe' `
    -Message 'PS5.1 controller did not launch the TLS proxy through WSL.'

  $publishedMarker = "rims-local-tls-proxy:$($pathsA.workspaceId)"
  $publishedIdentity = [pscustomobject][ordered]@{
    bootId = 'published-boot-id'
    leaderPid = 4455
    startTicks = '7654321'
    processGroupId = 4455
    commandMarker = $publishedMarker
  }
  $publishedProcess = [pscustomobject]@{
    StartInfo = $null
    Id = 4454
    HasExited = $false
    StartTime = [DateTime]::Parse('2026-07-15T01:02:04Z')
  }
  $publishedProcess | Add-Member -MemberType ScriptMethod -Name Start -Value {
    return $true
  }
  $publishedProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {}
  $publishedProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($timeoutMilliseconds)
    return $true
  }
  $publishedProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
  $script:publishedIdentityCurrentReads = 0
  $script:publishedIdentityCompensationState = $null
  $publicationReaderThrow = Start-RimsLocalTlsProxyProcess `
    -Spec ([pscustomobject]@{
      proxySource = $pathsA.proxySource
      proxyBinary = $pathsA.proxyBinary
      linuxIdentityPath = $pathsA.proxyLinuxIdentity
      serverCertificate = $pathsA.serverCertificate
      serverPrivateKey = $pathsA.serverPrivateKey
      tlsPort = 8443
      backendPort = 8080
      ownershipMarker = $publishedMarker
      stderrLogPath = $pathsA.proxyStderrLog
      stdoutLogPath = $pathsA.proxyStdoutLog
    }) `
    -BuildAction { param($spec) return [pscustomobject]@{ ok = $true } } `
    -PathConversionAction { param($path) return "/mnt/c/fake/$([IO.Path]::GetFileName($path))" } `
    -ProcessFactoryAction { return $publishedProcess } `
    -LinuxIdentityAction {
      param($spec, $process)
      $identityTemporaryPath = ([string]$spec.linuxIdentityPath) + '.tmp.test'
      [IO.File]::WriteAllText(
        $identityTemporaryPath,
        ($publishedIdentity | ConvertTo-Json -Compress),
        (New-Object Text.UTF8Encoding($false))
      )
      [IO.File]::Move($identityTemporaryPath, [string]$spec.linuxIdentityPath)
      throw 'fake reader failure after atomic identity publication'
    } `
    -CurrentLinuxIdentityAction {
      param($storedIdentity)
      $script:publishedIdentityCurrentReads += 1
      return [pscustomobject]@{
        ok = $true
        exists = $true
        identity = $publishedIdentity
        detail = 'fake exact current identity'
      }
    } `
    -CompensationAction {
      param($state)
      $script:publishedIdentityCompensationState = $state
      return $true
    }
  Assert-False `
    -Value $publicationReaderThrow.ok `
    -Message 'Post-publication reader throw was reported as a successful start.'
  Assert-Equal `
    -Actual $script:publishedIdentityCurrentReads `
    -Expected 1 `
    -Message 'Published identity recovery did not verify the current Linux leader.'
  Assert-True `
    -Value ($null -ne $script:publishedIdentityCompensationState) `
    -Message 'Verified published identity did not reach exact group compensation.'
  Assert-Equal `
    -Actual $script:publishedIdentityCompensationState.linuxProcessGroupId `
    -Expected 4455 `
    -Message 'Exact compensation received the wrong recovered Linux process group.'
  Assert-Equal `
    -Actual $script:publishedIdentityCompensationState.linuxIdentity.commandMarker `
    -Expected $publishedMarker `
    -Message 'Exact compensation lost the recovered workspace command marker.'
  Assert-False `
    -Value $publicationReaderThrow.cleanupPending `
    -Message 'Successful exact recovered-identity compensation remained pending.'

  $script:linuxIdentityCompensated = $false
  $fakeIdentityProcess = [pscustomobject]@{
    StartInfo = $null
    Id = 4444
    HasExited = $false
    StartTime = [DateTime]::Parse('2026-07-15T01:02:03Z')
  }
  $fakeIdentityProcess | Add-Member -MemberType ScriptMethod -Name Start -Value {
    return $true
  }
  $fakeIdentityProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {}
  $fakeIdentityProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($timeoutMilliseconds)
    return $true
  }
  $fakeIdentityProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
  $throwingLinuxIdentity = [pscustomobject][ordered]@{
    bootId = 'boot-id'
    leaderPid = 4445
    startTicks = '654321'
    commandMarker = "rims-local-tls-proxy:$($pathsA.workspaceId)"
  }
  $throwingLinuxIdentity | Add-Member `
    -MemberType ScriptProperty `
    -Name processGroupId `
    -Value { throw 'fake PGID read after Linux identity publication' }
  $identityPostReadThrow = Start-RimsLocalTlsProxyProcess `
    -Spec ([pscustomobject]@{
      proxySource = $pathsA.proxySource
      proxyBinary = $pathsA.proxyBinary
      linuxIdentityPath = $pathsA.proxyLinuxIdentity
      serverCertificate = $pathsA.serverCertificate
      serverPrivateKey = $pathsA.serverPrivateKey
      tlsPort = 8443
      backendPort = 8080
      ownershipMarker = "rims-local-tls-proxy:$($pathsA.workspaceId)"
      stderrLogPath = $pathsA.proxyStderrLog
      stdoutLogPath = $pathsA.proxyStdoutLog
    }) `
    -BuildAction { param($spec) return [pscustomobject]@{ ok = $true } } `
    -PathConversionAction { param($path) return "/mnt/c/fake/$([IO.Path]::GetFileName($path))" } `
    -ProcessFactoryAction { return $fakeIdentityProcess } `
    -LinuxIdentityAction { param($spec, $process) return $throwingLinuxIdentity } `
    -CompensationAction {
      param($state)
      $script:linuxIdentityCompensated = $true
      return $true
    }
  Assert-False `
    -Value $identityPostReadThrow.ok `
    -Message 'Post-identity TLS start throw was reported as success.'
  Assert-True `
    -Value $script:linuxIdentityCompensated `
    -Message 'Post-identity TLS start throw skipped exact Linux compensation.'
  Assert-False `
    -Value $identityPostReadThrow.cleanupPending `
    -Message 'Successful post-identity compensation left cleanup pending.'

  $fakeStartedAt = '2026-07-15T01:02:03.0000000Z'
  $fakeLinuxIdentity = [pscustomobject][ordered]@{
    bootId = 'fake-boot-id'
    leaderPid = 4344
    startTicks = '123456'
    processGroupId = 4344
    commandMarker = "rims-local-tls-proxy:$($pathsA.workspaceId)"
  }
  $proxy = Start-RimsLocalTlsProxy `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -PortListeningAction { param($port) return $false } `
    -StartProcessAction {
      param($spec)
      return [pscustomobject]@{
        windowsPid = 4242
        windowsProcessStartTimeUtc = $fakeStartedAt
        commandLine = "wsl.exe /mnt/c/fake/rims-local-tls-proxy $($spec.ownershipMarker)"
        linuxIdentity = $fakeLinuxIdentity
        linuxProcessGroupId = $fakeLinuxIdentity.processGroupId
        proxyBinaryWslPath = '/mnt/c/fake/rims-local-tls-proxy'
      }
    } `
    -ReadinessAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $processId -eq 4242 }
  Assert-True -Value $proxy.ok -Message 'Owned fake TLS proxy did not start.'
  $proxySourceText = [IO.File]::ReadAllText($pathsA.proxySource)
  Assert-Equal `
    -Actual $proxySourceText `
    -Expected $goProxySource `
    -Message 'TLS start did not write the reviewed WSL Go proxy source.'
  Assert-Equal `
    -Actual $proxy.state.linuxIdentity.commandMarker `
    -Expected $fakeLinuxIdentity.commandMarker `
    -Message 'TLS state omitted Linux command-marker ownership.'

  if ($null -eq ('RimsTlsTestCertificateValidation' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class RimsTlsTestCertificateValidation
{
    public static bool Accept(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors errors)
    {
        return true;
    }
}
'@
  }
  $validationCallback = [Delegate]::CreateDelegate(
    [Net.Security.RemoteCertificateValidationCallback],
    [RimsTlsTestCertificateValidation].GetMethod('Accept')
  )

  Write-RimsTlsTestStage -Name 'real WSL proxy concurrency integration'
  $concurrentProxyRoot = Join-Path $testRoot 'concurrent-proxy'
  [void][IO.Directory]::CreateDirectory($concurrentProxyRoot)
  $concurrentWorkspaceScripts = Join-Path $testRoot 'concurrent-workspace\scripts'
  [void][IO.Directory]::CreateDirectory($concurrentWorkspaceScripts)
  $concurrentTlsPaths = Get-RimsLocalTlsPaths `
    -ScriptDirectory $concurrentWorkspaceScripts
  $concurrentCertificateResult = New-RimsLocalTlsCertificates `
    -TlsPaths $concurrentTlsPaths
  Assert-True `
    -Value $concurrentCertificateResult.ok `
    -Message "Real local TLS test certificate generation failed: $($concurrentCertificateResult.detail)"
  $concurrentBackendScript = Join-Path $concurrentProxyRoot 'backend.go'
  $concurrentBackendReady = Join-Path $concurrentProxyRoot 'backend-first.ready'
  $concurrentBackendMarker = 'rims-tls-backend-' +
    [guid]::NewGuid().ToString('N')
  $testWsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  [IO.File]::WriteAllText(
    $concurrentBackendScript,
    @'
package main

import (
	"flag"
	"net"
	"os"
	"sync"
)

func main() {
	port := flag.String("port", "", "listen port")
	ready := flag.String("ready", "", "first payload marker")
	marker := flag.String("marker", "", "ownership marker")
	flag.Parse()
	if *marker == "" {
		os.Exit(2)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+*port)
	if err != nil {
		panic(err)
	}
	defer listener.Close()
	var firstPayload sync.Once
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		go func() {
			defer connection.Close()
			buffer := make([]byte, 16)
			for {
				count, readErr := connection.Read(buffer)
				if readErr != nil {
					return
				}
				firstPayload.Do(func() {
					_ = os.WriteFile(*ready, []byte("ready"), 0600)
				})
				if string(buffer[:count]) == "ping" {
					_, _ = connection.Write([]byte("pong"))
				}
			}
		}()
	}
}
'@,
    (New-Object Text.UTF8Encoding($false)))
  $concurrentBackendPort = Get-RimsTlsTestPort
  $concurrentProxyPort = Get-RimsTlsTestPort
  $backendProcess = $null
  $realProxy = $null
  $firstClient = $null
  $firstTls = $null
  $secondClient = $null
  $secondTls = $null
  $privateKeySnapshotBefore = Get-RimsTlsPrivateKeyContainerSnapshot
  $privateKeySnapshotDuring = $null
  $privateKeySnapshotAfter = $null
  try {
    $backendSourceWsl = ConvertTo-RimsWslPath `
      -WindowsPath $concurrentBackendScript `
      -WslExecutable $testWsl
    $backendReadyWsl = ConvertTo-RimsWslPath `
      -WindowsPath $concurrentBackendReady `
      -WslExecutable $testWsl
    $backendCommand = 'exec "$HOME/local/go/bin/go" run "$1" ' +
      '-port "$2" -ready "$3" -marker "$4"'
    $backendArguments = @(
      '-e', 'bash', '-c', $backendCommand,
      'rims-tls-test-backend',
      $backendSourceWsl,
      [string]$concurrentBackendPort,
      $backendReadyWsl,
      $concurrentBackendMarker
    )
    $backendProcess = Start-Process `
      -FilePath $testWsl `
      -ArgumentList (($backendArguments | ForEach-Object {
            ConvertTo-RimsWindowsCommandLineArgument -Value $_
          }) -join ' ') `
      -WindowStyle Hidden `
      -PassThru
    $backendDeadline = (Get-Date).AddSeconds(20)
    do {
      if ($backendProcess.HasExited) {
        throw "WSL test backend exited with $($backendProcess.ExitCode)."
      }
      if (Test-RimsTcpPortListening `
          -Port $concurrentBackendPort `
          -TimeoutMilliseconds 250) {
        break
      }
      Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $backendDeadline)
    if ((Get-Date) -ge $backendDeadline) {
      throw 'WSL test backend readiness timed out.'
    }
    $realProxy = Start-RimsLocalTlsProxy `
      -TlsPaths $concurrentTlsPaths `
      -BackendPort $concurrentBackendPort `
      -TlsPort $concurrentProxyPort
    Assert-True `
      -Value $realProxy.ok `
      -Message "Real WSL Go TLS proxy failed to start: $($realProxy.detail)"

    $firstClient = New-Object Net.Sockets.TcpClient
    [void](Wait-RimsTlsTestTask `
        -Task $firstClient.ConnectAsync(
          [Net.IPAddress]::Loopback,
          $concurrentProxyPort) `
        -TimeoutMilliseconds 3000 `
        -Message 'First TLS client connect exceeded its hard timeout.')
    $firstTls = New-Object Net.Security.SslStream(
      $firstClient.GetStream(),
      $false,
      $validationCallback
    )
    $firstHandshake = $firstTls.AuthenticateAsClientAsync('localhost')
    Assert-True `
      -Value $firstHandshake.Wait(5000) `
      -Message 'First persistent TLS connection did not complete its handshake.'
    $holdRequest = [Text.Encoding]::ASCII.GetBytes('hold')
    [void](Wait-RimsTlsTestTask `
        -Task $firstTls.WriteAsync(
          $holdRequest,
          0,
          $holdRequest.Length) `
        -TimeoutMilliseconds 3000 `
        -Message 'First TLS client write exceeded its hard timeout.')
    $backendReadyDeadline = (Get-Date).AddSeconds(3)
    while (-not (Test-Path -LiteralPath $concurrentBackendReady -PathType Leaf) -and
        (Get-Date) -lt $backendReadyDeadline) {
      Start-Sleep -Milliseconds 25
    }
    Assert-True `
      -Value (Test-Path -LiteralPath $concurrentBackendReady -PathType Leaf) `
      -Message 'First persistent connection did not reach the backend before the hard deadline.'

    $secondClient = New-Object Net.Sockets.TcpClient
    [void](Wait-RimsTlsTestTask `
        -Task $secondClient.ConnectAsync(
          [Net.IPAddress]::Loopback,
          $concurrentProxyPort) `
        -TimeoutMilliseconds 3000 `
        -Message 'Second TLS client connect exceeded its hard timeout.')
    Assert-True `
      -Value ([Net.IPAddress]::IsLoopback(
          [Net.IPAddress]$secondClient.Client.RemoteEndPoint.Address)) `
      -Message 'Actual TLS proxy connection was not bound to host loopback.'
    $secondTls = New-Object Net.Security.SslStream(
      $secondClient.GetStream(),
      $false,
      $validationCallback
    )
    $secondHandshake = $secondTls.AuthenticateAsClientAsync('localhost')
    Assert-True `
      -Value $secondHandshake.Wait(3000) `
      -Message 'Second TLS connection was blocked by the first persistent connection.'
    $request = [Text.Encoding]::ASCII.GetBytes('ping')
    [void](Wait-RimsTlsTestTask `
        -Task $secondTls.WriteAsync($request, 0, $request.Length) `
        -TimeoutMilliseconds 3000 `
        -Message 'Second TLS client write exceeded its hard timeout.')
    $responseBuffer = New-Object byte[] 4
    $responseRead = $secondTls.ReadAsync($responseBuffer, 0, $responseBuffer.Length)
    Assert-True `
      -Value $responseRead.Wait(3000) `
      -Message 'Second proxied connection did not receive a concurrent backend response.'
    Assert-Equal `
      -Actual ([Text.Encoding]::ASCII.GetString($responseBuffer, 0, $responseRead.Result)) `
      -Expected 'pong' `
      -Message 'Second proxied connection returned the wrong backend response.'
    $privateKeySnapshotDuring = Get-RimsTlsPrivateKeyContainerSnapshot
    Assert-RimsTlsPrivateKeySnapshotEqual `
      -Before $privateKeySnapshotBefore `
      -After $privateKeySnapshotDuring `
      -Message 'TLS proxy created or updated a Windows user private-key container while running.'

    $validCertificateWsl = ConvertTo-RimsWslPath `
      -WindowsPath $concurrentTlsPaths.serverCertificate `
      -WslExecutable $testWsl
    $validPrivateKeyWsl = ConvertTo-RimsWslPath `
      -WindowsPath $concurrentTlsPaths.serverPrivateKey `
      -WslExecutable $testWsl
    foreach ($missingMaterialCase in @(
        [pscustomobject]@{
          name = 'certificate'
          certificate = '/mnt/e/SECRET-rims-missing-cert/server.pem'
          privateKey = $validPrivateKeyWsl
        },
        [pscustomobject]@{
          name = 'private key'
          certificate = $validCertificateWsl
          privateKey = '/mnt/e/SECRET-rims-missing-key/server.key'
        }
      )) {
      $missingMaterial = Invoke-RimsExternalCommand `
        -FilePath $testWsl `
        -Arguments @(
          '-e', [string]$realProxy.state.proxyBinaryWslPath,
          '-cert', [string]$missingMaterialCase.certificate,
          '-key', [string]$missingMaterialCase.privateKey,
          '-listen-port', [string]$concurrentProxyPort,
          '-backend-port', [string]$concurrentBackendPort,
          '-command-marker', 'rims-local-missing-material-test'
        ) `
        -TimeoutSeconds 5
      Assert-False `
        -Value ($missingMaterial.ExitCode -eq 0) `
        -Message "WSL Go TLS proxy accepted a missing $($missingMaterialCase.name)."
      Assert-True `
        -Value $missingMaterial.StandardError.Contains('certificate load failed') `
        -Message "Missing $($missingMaterialCase.name) did not emit the fixed certificate category."
      Assert-False `
        -Value ($missingMaterial.StandardError -match '(?i)(?:[A-Z]:[\\/]|/mnt/|/home/|/tmp/|/var/|/usr/|SECRET)') `
        -Message "Missing $($missingMaterialCase.name) leaked an absolute path in raw stderr."
    }
  } catch {
    $proxyLog = if (Test-Path `
        -LiteralPath $concurrentTlsPaths.proxyStderrLog `
        -PathType Leaf) {
      try {
        [IO.File]::ReadAllText($concurrentTlsPaths.proxyStderrLog)
      } catch { '<proxy log active>' }
    } else { '' }
    throw "$($_.Exception.Message) Proxy log: $proxyLog"
  } finally {
    if ($null -ne $secondTls) { $secondTls.Dispose() }
    if ($null -ne $secondClient) { $secondClient.Close() }
    if ($null -ne $firstTls) { $firstTls.Dispose() }
    if ($null -ne $firstClient) { $firstClient.Close() }
    if ($null -ne $realProxy -and $realProxy.ok) {
      $realProxyStop = Stop-RimsLocalTlsProxy `
        -TlsState $realProxy.state
      if (-not $realProxyStop.ok) {
        throw "Real WSL Go TLS proxy cleanup failed: $($realProxyStop.detail)"
      }
    }
    $backendPattern = '[r]' + $concurrentBackendMarker.Substring(1)
    [void](Invoke-RimsExternalCommand `
        -FilePath $testWsl `
        -Arguments @(
          '-e', 'bash', '-c',
          'pkill -TERM -f -- "$1" 2>/dev/null || true',
          'rims-tls-test-cleanup', $backendPattern
        ) `
        -TimeoutSeconds 5)
    if ($null -ne $backendProcess) {
      try {
        if (-not $backendProcess.HasExited) { $backendProcess.Kill() }
        [void]$backendProcess.WaitForExit(3000)
      } catch {} finally { $backendProcess.Dispose() }
    }
    $privateKeySnapshotAfter = Get-RimsTlsPrivateKeyContainerSnapshot
  }
  Assert-RimsTlsPrivateKeySnapshotEqual `
    -Before $privateKeySnapshotBefore `
    -After $privateKeySnapshotAfter `
    -Message 'TLS proxy left a new or updated Windows user private-key container after exit.'
  Write-RimsTlsTestStage -Name 'real WSL proxy integration complete'
  Assert-Equal -Actual $proxy.state.port -Expected 8443 -Message 'TLS port evidence changed.'
  Assert-Equal -Actual $proxy.state.windowsPid -Expected 4242 -Message 'TLS PID was not recorded.'
  Assert-Equal `
    -Actual $proxy.state.windowsProcessStartTimeUtc `
    -Expected $fakeStartedAt `
    -Message 'TLS process start time was not recorded.'
  $owned = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -LinuxPortOwnershipAction { param($port, $state) return $true } `
    -CommandLineAction { param($processId) return $proxy.state.commandLine }
  Assert-True -Value $owned.ok -Message 'Exact fake TLS proxy ownership was rejected.'
  $wrongCommand = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -LinuxPortOwnershipAction { param($port, $state) return $true } `
    -CommandLineAction { param($processId) return 'powershell unrelated-proxy.ps1' }
  Assert-False `
    -Value $wrongCommand.ok `
    -Message 'TLS ownership accepted the wrong command line.'

  $pidMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction {
      param($state)
      return [pscustomobject]@{ ok = $false; pidMatches = $false; startTimeMatches = $true }
    }
  Assert-False -Value $pidMismatch.ok -Message 'TLS ownership accepted a PID mismatch.'
  Assert-True `
    -Value $pidMismatch.detail.Contains('PID') `
    -Message 'TLS PID mismatch evidence was not specific.'
  $startTimeMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction {
      param($state)
      return [pscustomobject]@{ ok = $false; pidMatches = $true; startTimeMatches = $false }
    }
  Assert-False `
    -Value $startTimeMismatch.ok `
    -Message 'TLS ownership accepted a process start-time mismatch.'
  Assert-True `
    -Value $startTimeMismatch.detail.Contains('start time') `
    -Message 'TLS process start-time mismatch evidence was not specific.'
  $linuxIdentityMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -LinuxOwnershipAction { param($state) return $false }
  Assert-False `
    -Value $linuxIdentityMismatch.ok `
    -Message 'TLS ownership accepted a Linux identity mismatch.'
  $ownershipPortMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $false }
  Assert-False `
    -Value $ownershipPortMismatch.ok `
    -Message 'TLS ownership accepted a port mismatch.'
  $markerMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -LinuxPortOwnershipAction { param($port, $state) return $true } `
    -CommandLineAction { param($processId) return "powershell $($pathsA.proxyScript)" }
  Assert-False `
    -Value $markerMismatch.ok `
    -Message 'TLS ownership accepted a missing workspace marker.'
  $scriptPathMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -LinuxPortOwnershipAction { param($port, $state) return $true } `
    -CommandLineAction { param($processId) return "wsl.exe /mnt/c/other/proxy $($proxy.state.ownershipMarker)" }
  Assert-False `
    -Value $scriptPathMismatch.ok `
    -Message 'TLS ownership accepted the wrong proxy script path.'
  $linuxPortMismatch = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -LinuxOwnershipAction { param($state) return $true } `
    -LinuxPortOwnershipAction { param($port, $state) return $false } `
    -CommandLineAction { param($processId) return $proxy.state.commandLine }
  Assert-False `
    -Value $linuxPortMismatch.ok `
    -Message 'TLS ownership accepted a Linux listener inode mismatch.'

  $failedProxyStop = Start-RimsLocalTlsProxy `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -PortListeningAction { param($port) return $false } `
    -StartProcessAction {
      param($spec)
      return [pscustomobject]@{
        windowsPid = $proxy.state.windowsPid
        windowsProcessStartTimeUtc = $proxy.state.windowsProcessStartTimeUtc
        commandLine = $spec.commandLine
      }
    } `
    -ReadinessAction { param($state) return $false } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -StopAction {
      param($state)
      return [pscustomobject]@{ ok = $false; detail = 'fake proxy stop failure' }
    }
  Assert-False -Value $failedProxyStop.ok -Message 'Proxy readiness failure was hidden.'
  Assert-True `
    -Value $failedProxyStop.cleanupPending `
    -Message 'Proxy stop failure was not marked pending.'
  Assert-Equal `
    -Actual $failedProxyStop.state.windowsPid `
    -Expected $proxy.state.windowsPid `
    -Message 'Proxy stop failure lost PID ownership state.'

  $startThrow = Start-RimsLocalTlsProxy `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -PortListeningAction { param($port) return $false } `
    -StartProcessAction { param($spec) throw 'fake start throw' }
  Assert-False -Value $startThrow.ok -Message 'Proxy start throw escaped or was hidden.'
  Assert-False `
    -Value $startThrow.cleanupPending `
    -Message 'Proxy start throw without identity invented owned cleanup state.'

  foreach ($throwStage in @('readiness', 'ownership')) {
    $throwStopCalls = 0
    $proxyStageThrow = Start-RimsLocalTlsProxy `
      -TlsPaths $pathsA `
      -BackendPort 8080 `
      -TlsPort 8443 `
      -PortListeningAction { param($port) return $false } `
      -StartProcessAction {
        param($spec)
        return [pscustomobject]@{
          windowsPid = $proxy.state.windowsPid
          windowsProcessStartTimeUtc = $proxy.state.windowsProcessStartTimeUtc
          commandLine = $spec.commandLine
        }
      } `
      -ReadinessAction {
        param($state)
        if ($throwStage -eq 'readiness') { throw 'fake readiness throw' }
        return $true
      } `
      -PortOwnershipAction {
        param($port, $processId)
        if ($throwStage -eq 'ownership') { throw 'fake ownership throw' }
        return $true
      } `
      -StopAction {
        param($state)
        $script:throwStopCalls++
        return [pscustomobject]@{ ok = $true; detail = 'stopped' }
      }
    Assert-False `
      -Value $proxyStageThrow.ok `
      -Message "Proxy $throwStage throw escaped or was hidden."
    Assert-Equal `
      -Actual $throwStopCalls `
      -Expected 1 `
      -Message "Proxy $throwStage throw did not stop the obtained identity."
    Assert-False `
      -Value $proxyStageThrow.cleanupPending `
      -Message "Proxy $throwStage throw remained pending after successful stop."
  }

  $stopThrowPending = Start-RimsLocalTlsProxy `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -PortListeningAction { param($port) return $false } `
    -StartProcessAction {
      param($spec)
      return [pscustomobject]@{
        windowsPid = $proxy.state.windowsPid
        windowsProcessStartTimeUtc = $proxy.state.windowsProcessStartTimeUtc
        commandLine = $spec.commandLine
      }
    } `
    -ReadinessAction { param($state) return $false } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -StopAction { param($state) throw 'fake stop throw' }
  Assert-False -Value $stopThrowPending.ok -Message 'Proxy stop throw escaped.'
  Assert-True `
    -Value $stopThrowPending.cleanupPending `
    -Message 'Proxy stop throw did not retain obtained identity.'
  Assert-Equal `
    -Actual $stopThrowPending.state.windowsPid `
    -Expected $proxy.state.windowsPid `
    -Message 'Proxy stop throw lost full ownership state.'

  $ownedEmulator = [pscustomobject]@{
    serial = 'emulator-5556'
    avdName = 'Medium_Phone_API_36.1'
    windowsPid = 5151
    windowsProcessStartTimeUtc = $fakeStartedAt
  }
  Write-RimsTlsTestStage -Name 'Android trust sentinel and compensation'
  $adbCalls = New-Object 'Collections.Generic.List[string]'
  $installed = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $true } `
    -TrustQueryAction { param($serial, $fingerprint) return $false } `
    -AdbAction {
      param($serial, $arguments)
      [void]$adbCalls.Add(($arguments -join ' '))
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True -Value $installed.ok -Message 'Owned emulator CA install failed.'
  Assert-True `
    -Value $installed.state.installedByController `
    -Message 'Owned CA install was not recorded.'
  Assert-True `
    -Value ($adbCalls.Count -gt 0) `
    -Message 'Owned CA install did not cross the fake ADB boundary.'

  $presenceScript = 'if [ -f "$1" ]; then printf EXISTS; else printf ABSENT; fi'
  $presenceCommand = "shell sh -c $presenceScript rims-ca-query $($installed.state.remotePath)"
  $sentinelInstallCalls = New-Object 'Collections.Generic.List[string]'
  $sentinelAbsentInstall = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -CaSubjectHash $installed.state.subjectHash `
    -EmulatorOwnershipAction { param($state) return $true } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$sentinelInstallCalls.Add($commandText)
      if ($commandText -eq $presenceCommand) {
        return [pscustomobject]@{
          exitCode = 0
          stdout = 'ABSENT'
          stderr = ''
        }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $sentinelAbsentInstall.ok `
    -Message 'Android ABSENT sentinel did not permit an owned CA install.'
  Assert-True `
    -Value (@($sentinelInstallCalls) -contains $presenceCommand) `
    -Message 'Android install did not use the single shell presence sentinel.'
  Assert-False `
    -Value (($sentinelInstallCalls -join '|').Contains('shell test -f')) `
    -Message 'Android install retained exit-code-based shell test querying.'

  foreach ($sentinelFailure in @(
      [pscustomobject]@{
        name = 'exit1-with-stderr'
        exitCode = 1
        stdout = 'ABSENT'
        stderr = 'query failed'
        throws = $false
      },
      [pscustomobject]@{
        name = 'stderr-on-exit0'
        exitCode = 0
        stdout = 'ABSENT'
        stderr = 'unexpected diagnostic'
        throws = $false
      },
      [pscustomobject]@{
        name = 'unknown-stdout'
        exitCode = 0
        stdout = 'UNKNOWN'
        stderr = ''
        throws = $false
      },
      [pscustomobject]@{
        name = 'adb-throw'
        exitCode = 0
        stdout = ''
        stderr = ''
        throws = $true
      }
    )) {
    $sentinelFailureCalls = New-Object 'Collections.Generic.List[string]'
    $sentinelFailureResult = Install-RimsAndroidUserCa `
      -TlsPaths $pathsA `
      -EmulatorState $ownedEmulator `
      -CaFingerprintSha256 ('AA' * 32) `
      -CaSubjectHash $installed.state.subjectHash `
      -EmulatorOwnershipAction { param($state) return $true } `
      -AdbAction {
        param($serial, $arguments)
        $commandText = $arguments -join ' '
        [void]$sentinelFailureCalls.Add($commandText)
        if ($commandText -eq $presenceCommand -or
            $commandText -like 'shell test -f *') {
          if ($sentinelFailure.throws) {
            throw 'fake sentinel ADB exception'
          }
          return [pscustomobject]@{
            exitCode = $sentinelFailure.exitCode
            stdout = $sentinelFailure.stdout
            stderr = $sentinelFailure.stderr
          }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $sentinelFailureResult.ok `
      -Message "Android sentinel $($sentinelFailure.name) did not fail closed."
    $unsafeSentinelMutations = @($sentinelFailureCalls | Where-Object {
        $_ -match '^(push|shell (cp|rm))'
      })
    Assert-Equal `
      -Actual $unsafeSentinelMutations.Count `
      -Expected 0 `
      -Message "Android sentinel $($sentinelFailure.name) performed a mutation."
  }

  $adbCalls.Clear()
  $sentinelAbsentRemoval = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$adbCalls.Add($commandText)
      if ($commandText -eq $presenceCommand) {
        return [pscustomobject]@{
          exitCode = 0
          stdout = 'ABSENT'
          stderr = ''
        }
      }
      if ($commandText -like 'shell test -f *') {
        return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = '' }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $sentinelAbsentRemoval.ok `
    -Message 'Android ABSENT sentinel did not permit deterministic temp cleanup.'
  Assert-True `
    -Value (@($adbCalls) -contains $presenceCommand) `
    -Message 'Android removal did not use the single shell presence sentinel.'
  Assert-False `
    -Value (@($adbCalls) -contains "pull $($installed.state.remotePath) $($pathsA.root)\android-remove-ca.pem") `
    -Message 'Android ABSENT removal attempted to pull a missing remote CA.'
  Assert-False `
    -Value (@($adbCalls) -contains "shell rm -f $($installed.state.remotePath)") `
    -Message 'Android ABSENT removal attempted to mutate the missing remote CA.'

  $adbCalls.Clear()
  $removedOwnedTrust = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      [void]$adbCalls.Add(($arguments -join ' '))
      if (($arguments -join ' ') -eq $presenceCommand) {
        return [pscustomobject]@{
          exitCode = 0
          stdout = 'EXISTS'
          stderr = ''
        }
      }
      if ($arguments[0] -eq 'pull') {
        [IO.File]::WriteAllText([string]$arguments[2], 'fake remote CA')
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $removedOwnedTrust.ok `
    -Message 'Controller-installed Android CA removal failed.'
  Assert-Equal `
    -Actual ($adbCalls -join '|') `
    -Expected "root|$presenceCommand|pull $($installed.state.remotePath) $($pathsA.root)\android-remove-ca.pem|shell rm -f $($installed.state.remotePath)|shell rm -f $($installed.state.temporaryPath)" `
    -Message 'Owned Android CA removal did not verify and remove the exact recorded certificate.'
  Assert-True `
    -Value (-not (Test-Path -LiteralPath (Join-Path $pathsA.root 'android-remove-ca.pem'))) `
    -Message 'Android CA removal left its temporary pulled certificate.'
  Assert-True `
    -Value (@($adbCalls) -contains "shell rm -f $($installed.state.remotePath)") `
    -Message 'Owned Android CA removal did not use the exact recorded path.'

  $adbCalls.Clear()
  $preExisting = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $true } `
    -TrustQueryAction { param($serial, $fingerprint) return $true } `
    -AdbAction {
      param($serial, $arguments)
      [void]$adbCalls.Add(($arguments -join ' '))
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True -Value $preExisting.ok -Message 'Pre-existing user trust was rejected.'
  Assert-False `
    -Value $preExisting.state.installedByController `
    -Message 'Pre-existing trust was claimed by the controller.'
  Assert-Equal `
    -Actual $adbCalls.Count `
    -Expected 0 `
    -Message 'Pre-existing trust triggered an ADB mutation.'

  foreach ($queryFailureMode in @('exit2', 'throw')) {
    $queryFailureCalls = New-Object 'Collections.Generic.List[string]'
    $queryFailure = Install-RimsAndroidUserCa `
      -TlsPaths $pathsA `
      -EmulatorState $ownedEmulator `
      -CaFingerprintSha256 ('AA' * 32) `
      -CaSubjectHash $installed.state.subjectHash `
      -EmulatorOwnershipAction { param($state) return $true } `
      -AdbAction {
        param($serial, $arguments)
        $commandText = $arguments -join ' '
        [void]$queryFailureCalls.Add($commandText)
        if ($commandText -eq $presenceCommand) {
          if ($queryFailureMode -eq 'throw') {
            throw 'fake ADB trust query exception'
          }
          return [pscustomobject]@{
            exitCode = 2
            stdout = ''
            stderr = 'fake trust query indeterminate'
          }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $queryFailure.ok `
      -Message "Android trust query $queryFailureMode did not fail closed."
    $queryMutationCalls = @($queryFailureCalls | Where-Object {
        $_ -match '^(push|shell (cp|rm|mkdir|chmod|chown|restorecon))'
      })
    Assert-Equal `
      -Actual $queryMutationCalls.Count `
      -Expected 0 `
      -Message "Android trust query $queryFailureMode performed a mutation."
    Assert-False `
      -Value (@($queryFailureCalls) -contains "shell rm -f $($installed.state.remotePath)") `
      -Message "Android trust query $queryFailureMode changed the existing remote certificate."
  }
  $preserved = Remove-RimsAndroidUserCa `
    -TrustState $preExisting.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -AdbAction {
      param($serial, $arguments)
      [void]$adbCalls.Add(($arguments -join ' '))
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True -Value $preserved.ok -Message 'Pre-existing trust preservation failed.'
  Assert-Equal `
    -Actual $adbCalls.Count `
    -Expected 0 `
    -Message 'Down removed trust that pre-existed the controller.'

  $wrongSerialEmulator = [pscustomobject]@{
    serial = 'emulator-5558'
    avdName = 'Medium_Phone_API_36.1'
    windowsPid = 5252
    windowsProcessStartTimeUtc = $fakeStartedAt
  }
  $wrongSerialCalls = 0
  $wrongSerialRemoval = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $wrongSerialEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $script:wrongSerialCalls++
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $wrongSerialRemoval.ok `
    -Message 'Android CA removal accepted a different owned emulator serial.'
  Assert-Equal `
    -Actual $wrongSerialCalls `
    -Expected 0 `
    -Message 'Wrong-serial Android CA removal crossed the ADB boundary.'

  $replacementCalls = New-Object 'Collections.Generic.List[string]'
  $replacementRemoval = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction {
      param($path)
      if ($path -eq $pathsA.caCertificate) { return ('AA' * 32) }
      return ('BB' * 32)
    } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      [void]$replacementCalls.Add(($arguments -join ' '))
      if ($arguments[0] -eq 'pull') {
        [IO.File]::WriteAllText([string]$arguments[2], 'replacement CA')
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $replacementRemoval.ok `
    -Message 'Android CA removal deleted a remotely replaced certificate.'
  Assert-True `
    -Value $replacementRemoval.cleanupPending `
    -Message 'Remote Android CA replacement did not retain cleanup state.'
  Assert-False `
    -Value (@($replacementCalls) -contains "shell rm -f $($installed.state.remotePath)") `
    -Message 'Remote Android CA replacement was deleted.'
  Assert-False `
    -Value (Test-Path -LiteralPath (Join-Path $pathsA.root 'android-remove-ca.pem')) `
    -Message 'Remote replacement verification left its pulled temporary file.'

  $installMutations = @(
    'root',
    "push $($pathsA.caCertificate) /data/local/tmp/rims-$($pathsA.workspaceId)-ca.pem",
    'shell mkdir -p /data/misc/user/0/cacerts-added',
    "shell cp /data/local/tmp/rims-$($pathsA.workspaceId)-ca.pem $($installed.state.remotePath)",
    "shell chmod 644 $($installed.state.remotePath)",
    "shell chown system:system $($installed.state.remotePath)",
    "shell restorecon $($installed.state.remotePath)",
    "shell rm -f /data/local/tmp/rims-$($pathsA.workspaceId)-ca.pem"
  )
  for ($failedMutation = 0; $failedMutation -lt $installMutations.Count; $failedMutation++) {
    $mutationCalls = New-Object 'Collections.Generic.List[string]'
    $script:mutationFailedOnce = $false
    $mutationFailure = Install-RimsAndroidUserCa `
      -TlsPaths $pathsA `
      -EmulatorState $ownedEmulator `
      -CaFingerprintSha256 ('AA' * 32) `
      -EmulatorOwnershipAction { param($state) return $true } `
      -TrustQueryAction { param($serial, $fingerprint) return $false } `
      -AdbAction {
        param($serial, $arguments)
        $commandText = $arguments -join ' '
        [void]$mutationCalls.Add($commandText)
        if (-not $script:mutationFailedOnce -and
            $commandText -eq $installMutations[$failedMutation]) {
          $script:mutationFailedOnce = $true
          return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake ADB mutation failure' }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $mutationFailure.ok `
      -Message "Android install mutation '$($installMutations[$failedMutation])' failure was hidden."
    Assert-True `
      -Value (@($mutationCalls) -contains "shell rm -f /data/local/tmp/rims-$($pathsA.workspaceId)-ca.pem") `
      -Message "Android install mutation '$($installMutations[$failedMutation])' did not compensate its temp file."
    if ($failedMutation -ge 3) {
      Assert-True `
        -Value (@($mutationCalls) -contains "shell rm -f $($installed.state.remotePath)") `
        -Message "Android install mutation '$($installMutations[$failedMutation])' did not compensate attempted remote trust."
    }
    Assert-False `
      -Value $mutationFailure.cleanupPending `
      -Message "Successful Android compensation '$($installMutations[$failedMutation])' remained pending."
  }

  $script:compensationPrimaryCall = 0
  $failedCompensation = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $true } `
    -TrustQueryAction { param($serial, $fingerprint) return $false } `
    -AdbAction {
      param($serial, $arguments)
      $isRemoval = $arguments[0] -eq 'shell' -and $arguments[1] -eq 'rm'
      if ($isRemoval) {
        return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake compensation failure' }
      }
      $script:compensationPrimaryCall++
      if ($script:compensationPrimaryCall -eq 5) {
        return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake chmod failure' }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False -Value $failedCompensation.ok -Message 'Android compensation failure was hidden.'
  Assert-True `
    -Value $failedCompensation.cleanupPending `
    -Message 'Android compensation failure was not marked pending.'
  Assert-True `
    -Value $failedCompensation.state.installedByController `
    -Message 'Android compensation failure lost owned trust state.'
  Assert-Equal `
    -Actual $failedCompensation.state.serial `
    -Expected $ownedEmulator.serial `
    -Message 'Android compensation failure lost the exact emulator serial.'

  foreach ($tamperedField in @('subjectHash', 'remotePath', 'temporaryPath')) {
    $tamperedTrust = [pscustomobject][ordered]@{}
    foreach ($property in $failedCompensation.state.PSObject.Properties) {
      $tamperedTrust | Add-Member `
        -MemberType NoteProperty `
        -Name $property.Name `
        -Value $property.Value
    }
    if ($tamperedField -eq 'subjectHash') {
      $tamperedTrust.subjectHash = '../bad'
    } elseif ($tamperedField -eq 'remotePath') {
      $tamperedTrust.remotePath = '/data/misc/user/0/cacerts-added/evil.0'
    } else {
      $tamperedTrust.temporaryPath = '/data/local/tmp/other.pem'
    }
    $tamperedAdbCalls = 0
    $tamperedRemoval = Remove-RimsAndroidUserCa `
      -TrustState $tamperedTrust `
      -EmulatorState $ownedEmulator `
      -TlsPaths $pathsA `
      -EmulatorOwnershipAction { param($state) return $true } `
      -FingerprintAction { param($path) return ('AA' * 32) } `
      -SubjectHashAction { param($path) return $installed.state.subjectHash } `
      -AdbAction {
        param($serial, $arguments)
        $script:tamperedAdbCalls++
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $tamperedRemoval.ok `
      -Message "Android cleanup accepted tampered $tamperedField state."
    Assert-Equal `
      -Actual $tamperedAdbCalls `
      -Expected 0 `
      -Message "Tampered $tamperedField state reached root/ADB."
  }

  $coordinatedTamper = [pscustomobject][ordered]@{
    serial = $installed.state.serial
    fingerprintSha256 = ('BB' * 32)
    subjectHash = 'deadbeef'
    remotePath = (Get-RimsAndroidCaRemotePath -SubjectHash 'deadbeef')
    temporaryPath = $installed.state.temporaryPath
    preExisting = $false
    installedByController = $true
    remoteMutationAttempted = $true
    cleanupPending = $true
  }
  $coordinatedTamperAdbCalls = 0
  $coordinatedTamperRemoval = Remove-RimsAndroidUserCa `
    -TrustState $coordinatedTamper `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction {
      param($path)
      if ($path -eq $pathsA.caCertificate) { return ('AA' * 32) }
      return ('BB' * 32)
    } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $script:coordinatedTamperAdbCalls++
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $coordinatedTamperRemoval.ok `
    -Message 'Coordinated subjectHash/remotePath/fingerprint tampering was accepted.'
  Assert-Equal `
    -Actual $coordinatedTamperAdbCalls `
    -Expected 0 `
    -Message 'Coordinated trust-state tampering reached root/ADB.'

  $legacyTrustWithoutTemporaryPath = [pscustomobject][ordered]@{
    serial = $installed.state.serial
    fingerprintSha256 = $installed.state.fingerprintSha256
    subjectHash = $installed.state.subjectHash
    remotePath = $installed.state.remotePath
    preExisting = $false
    installedByController = $true
    remoteMutationAttempted = $true
    cleanupPending = $true
  }
  $legacyTemporaryCalls = New-Object 'Collections.Generic.List[string]'
  $legacyTemporaryRemoval = Remove-RimsAndroidUserCa `
    -TrustState $legacyTrustWithoutTemporaryPath `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$legacyTemporaryCalls.Add($commandText)
      if ($commandText -eq $presenceCommand) {
        return [pscustomobject]@{ exitCode = 0; stdout = 'ABSENT'; stderr = '' }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $legacyTemporaryRemoval.ok `
    -Message 'Legacy controller trust state without temporaryPath was rejected.'
  Assert-True `
    -Value (@($legacyTemporaryCalls) -contains "shell rm -f $($installed.state.temporaryPath)") `
    -Message 'Legacy trust cleanup did not derive deterministic temporaryPath.'

  $partialRetryCalls = New-Object 'Collections.Generic.List[string]'
  $partialRetry = Remove-RimsAndroidUserCa `
    -TrustState $failedCompensation.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$partialRetryCalls.Add($commandText)
      if ($commandText -eq $presenceCommand) {
        return [pscustomobject]@{ exitCode = 0; stdout = 'ABSENT'; stderr = '' }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $partialRetry.ok `
    -Message 'Later down retry did not finish Android partial-install cleanup.'
  Assert-True `
    -Value (@($partialRetryCalls) -contains "shell rm -f $($failedCompensation.state.temporaryPath)") `
    -Message 'Later down retry did not remove the fixed Android temp PEM.'

  $partialTempFailure = Remove-RimsAndroidUserCa `
    -TrustState $failedCompensation.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      if ($commandText -eq $presenceCommand) {
        return [pscustomobject]@{ exitCode = 0; stdout = 'ABSENT'; stderr = '' }
      }
      if ($commandText -eq "shell rm -f $($failedCompensation.state.temporaryPath)") {
        return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake temp cleanup failure' }
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $partialTempFailure.ok `
    -Message 'Later down hid Android temp PEM cleanup failure.'
  Assert-True `
    -Value $partialTempFailure.cleanupPending `
    -Message 'Android temp PEM cleanup failure lost partial state.'

  $installThrowCalls = New-Object 'Collections.Generic.List[string]'
  $script:installPrimaryThrew = $false
  $installAdbThrow = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $true } `
    -TrustQueryAction { param($serial, $fingerprint) return $false } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$installThrowCalls.Add($commandText)
      if (-not $script:installPrimaryThrew -and $arguments -contains 'chmod') {
        $script:installPrimaryThrew = $true
        throw 'fake install ADB throw'
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False -Value $installAdbThrow.ok -Message 'Install ADB throw escaped.'
  Assert-False `
    -Value $installAdbThrow.cleanupPending `
    -Message 'Install ADB throw remained pending after successful compensation.'
  Assert-True `
    -Value (@($installThrowCalls) -contains "shell rm -f $($installed.state.remotePath)") `
    -Message 'Install ADB throw did not compensate fixed remote CA.'
  Assert-True `
    -Value (@($installThrowCalls) -contains "shell rm -f $($installed.state.temporaryPath)") `
    -Message 'Install ADB throw did not compensate fixed temp PEM.'

  foreach ($throwingCompensation in @('remote', 'temporary')) {
    $compensationThrowCalls = New-Object 'Collections.Generic.List[string]'
    $compensationThrow = Install-RimsAndroidUserCa `
      -TlsPaths $pathsA `
      -EmulatorState $ownedEmulator `
      -CaFingerprintSha256 ('AA' * 32) `
      -EmulatorOwnershipAction { param($state) return $true } `
      -TrustQueryAction { param($serial, $fingerprint) return $false } `
      -AdbAction {
        param($serial, $arguments)
        $commandText = $arguments -join ' '
        [void]$compensationThrowCalls.Add($commandText)
        if ($arguments -contains 'chmod') {
          return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake install failure' }
        }
        if ($throwingCompensation -eq 'remote' -and
            $commandText -eq "shell rm -f $($installed.state.remotePath)") {
          throw 'fake remote compensation throw'
        }
        if ($throwingCompensation -eq 'temporary' -and
            $commandText -eq "shell rm -f $($installed.state.temporaryPath)") {
          throw 'fake temp compensation throw'
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $compensationThrow.ok `
      -Message "Android $throwingCompensation compensation throw escaped."
    Assert-True `
      -Value $compensationThrow.cleanupPending `
      -Message "Android $throwingCompensation compensation throw lost partial state."
    Assert-True `
      -Value (@($compensationThrowCalls) -contains "shell rm -f $($installed.state.temporaryPath)") `
      -Message "Android $throwingCompensation compensation throw skipped temp cleanup attempt."
  }

  $queryThrow = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $true } `
    -TrustQueryAction { param($serial, $fingerprint) throw 'fake trust query throw' }
  Assert-False -Value $queryThrow.ok -Message 'Trust query throw escaped install boundary.'
  Assert-False `
    -Value $queryThrow.cleanupPending `
    -Message 'Trust query throw invented mutation cleanup state.'

  $unownedAdbCalls = 0
  $unownedInstall = Install-RimsAndroidUserCa `
    -TlsPaths $pathsA `
    -EmulatorState $ownedEmulator `
    -CaFingerprintSha256 ('AA' * 32) `
    -EmulatorOwnershipAction { param($state) return $false } `
    -AdbAction {
      param($serial, $arguments)
      $script:unownedAdbCalls++
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $unownedInstall.ok `
    -Message 'Android CA install accepted an unowned emulator.'
  Assert-Equal `
    -Actual $unownedAdbCalls `
    -Expected 0 `
    -Message 'Unowned Android CA install crossed the ADB boundary.'

  foreach ($removeFailureCommand in @('root', 'query', 'pull', 'remove')) {
    $removeTrustState = [pscustomobject]@{
      serial = $ownedEmulator.serial
      fingerprintSha256 = ('AA' * 32)
      subjectHash = $installed.state.subjectHash
      remotePath = $installed.state.remotePath
      preExisting = $false
      installedByController = $true
      cleanupPending = $false
    }
    $removeFailure = Remove-RimsAndroidUserCa `
      -TrustState $removeTrustState `
      -EmulatorState $ownedEmulator `
      -TlsPaths $pathsA `
      -EmulatorOwnershipAction { param($state) return $true } `
      -FingerprintAction { param($path) return ('AA' * 32) } `
      -SubjectHashAction { param($path) return $installed.state.subjectHash } `
      -AdbAction {
        param($serial, $arguments)
        $commandKind = if ($arguments[0] -eq 'root') {
          'root'
        } elseif ($arguments[0] -eq 'pull') {
          [IO.File]::WriteAllText([string]$arguments[2], 'pulled CA')
          'pull'
        } elseif ($arguments[0] -eq 'shell' -and $arguments[1] -eq 'test') {
          'query'
        } else {
          'remove'
        }
        if ($commandKind -eq $removeFailureCommand) {
          $exitCode = if ($commandKind -eq 'query') { 2 } else { 1 }
          return [pscustomobject]@{ exitCode = $exitCode; stdout = ''; stderr = 'fake remove failure' }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $removeFailure.ok `
      -Message "Android CA $removeFailureCommand failure was hidden."
    Assert-True `
      -Value $removeFailure.cleanupPending `
      -Message "Android CA $removeFailureCommand failure lost cleanup state."
    Assert-False `
      -Value (Test-Path -LiteralPath (Join-Path $pathsA.root 'android-remove-ca.pem')) `
      -Message "Android CA $removeFailureCommand failure left its pulled temporary file."
  }

  $removeAdbThrow = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction { param($serial, $arguments) throw 'fake remove ADB throw' }
  Assert-False -Value $removeAdbThrow.ok -Message 'Remove ADB throw escaped.'
  Assert-True `
    -Value $removeAdbThrow.cleanupPending `
    -Message 'Remove ADB throw lost trust partial state.'

  $legacyTrustWithoutPending = [pscustomobject][ordered]@{
    serial = $installed.state.serial
    fingerprintSha256 = $installed.state.fingerprintSha256
    subjectHash = $installed.state.subjectHash
    remotePath = $installed.state.remotePath
    temporaryPath = $installed.state.temporaryPath
    preExisting = $false
    installedByController = $true
  }
  $legacyTrustThrow = Remove-RimsAndroidUserCa `
    -TrustState $legacyTrustWithoutPending `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction { param($path) return ('AA' * 32) } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction { param($serial, $arguments) throw 'fake legacy-state ADB throw' }
  Assert-False `
    -Value $legacyTrustThrow.ok `
    -Message 'Legacy trust state without cleanupPending escaped exception handling.'
  Assert-True `
    -Value $legacyTrustThrow.cleanupPending `
    -Message 'Legacy trust state did not gain cleanupPending evidence.'

  $fingerprintThrowCalls = New-Object 'Collections.Generic.List[string]'
  $removeFingerprintThrow = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -FingerprintAction {
      param($path)
      if ($path -eq $pathsA.caCertificate) { return ('AA' * 32) }
      throw 'fake fingerprint throw'
    } `
    -SubjectHashAction { param($path) return $installed.state.subjectHash } `
    -AdbAction {
      param($serial, $arguments)
      $commandText = $arguments -join ' '
      [void]$fingerprintThrowCalls.Add($commandText)
      if ($arguments[0] -eq 'pull') {
        [IO.File]::WriteAllText([string]$arguments[2], 'fake pulled CA')
      }
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-False `
    -Value $removeFingerprintThrow.ok `
    -Message 'Remove fingerprint throw escaped.'
  Assert-True `
    -Value $removeFingerprintThrow.cleanupPending `
    -Message 'Remove fingerprint throw lost trust partial state.'
  Assert-True `
    -Value (@($fingerprintThrowCalls) -contains "shell rm -f $($installed.state.temporaryPath)") `
    -Message 'Remove fingerprint throw skipped fixed temp cleanup.'
  Assert-False `
    -Value (Test-Path -LiteralPath (Join-Path $pathsA.root 'android-remove-ca.pem')) `
    -Message 'Remove fingerprint throw left pulled local material.'

  $preservedTlsState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      proxy = $null
      androidTrust = $preExisting.state
      cleanupPending = $false
    }
    emulator = $ownedEmulator
  }
  $preservedCertificateCleanupCalls = 0
  $preservedRuntime = Stop-RimsLocalTlsRuntime `
    -State $preservedTlsState `
    -TlsPaths $pathsA `
    -TrustRemoveAction {
      param($trust, $emulator)
      return [pscustomobject]@{ ok = $true; detail = 'preserved' }
    } `
    -CertificateCleanupAction {
      param($paths)
      $script:preservedCertificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-True `
    -Value $preservedRuntime.ok `
    -Message 'TLS cleanup failed while preserving pre-existing trust.'
  Assert-Equal `
    -Actual $preservedCertificateCleanupCalls `
    -Expected 0 `
    -Message 'TLS cleanup deleted CA material required by pre-existing trust.'

  $cleanupOrder = New-Object 'Collections.Generic.List[string]'
  $failedUp = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target android `
    -EmulatorState $ownedEmulator `
    -CertificateAction {
      param($paths)
      return [pscustomobject]@{
        ok = $true
        caFingerprintSha256 = ('AA' * 32)
        serverFingerprintSha256 = ('BB' * 32)
        caSubjectHash = '0123abcd'
      }
    } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{ ok = $true; state = $proxy.state }
    } `
    -TrustInstallAction {
      param($paths, $emulator, $fingerprint)
      return [pscustomobject]@{ ok = $false; detail = 'fake trust failure' }
    } `
    -ProxyStopAction {
      param($state)
      [void]$cleanupOrder.Add('proxy')
      return [pscustomobject]@{ ok = $true }
    } `
    -CertificateCleanupAction {
      param($paths)
      [void]$cleanupOrder.Add('certificates')
      return [pscustomobject]@{ ok = $true }
    }
  Assert-False -Value $failedUp.ok -Message 'TLS up hid its first required failure.'
  Assert-Equal `
    -Actual ($cleanupOrder -join '|') `
    -Expected 'proxy|certificates' `
    -Message 'TLS first-failure cleanup order changed.'

  $stopCalls = 0
  $certificateCleanupCalls = 0
  $refusalState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      proxy = $proxy.state
      androidTrust = $null
      cleanupPending = $false
    }
    emulator = $ownedEmulator
  }
  $refusedCleanup = Stop-RimsLocalTlsRuntime `
    -State $refusalState `
    -TlsPaths $pathsA `
    -OwnershipAction {
      param($state, $paths)
      return [pscustomobject]@{ ok = $false; detail = 'fake ownership mismatch' }
    } `
    -PortListeningAction { param($port) return $true } `
    -ProxyStopAction {
      param($state)
      $script:stopCalls++
      return [pscustomobject]@{ ok = $true }
    } `
    -CertificateCleanupAction {
      param($paths)
      $script:certificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-False `
    -Value $refusedCleanup.ok `
    -Message 'Cleanup accepted a listener without exact ownership.'
  Assert-Equal -Actual $stopCalls -Expected 0 -Message 'Unowned listener was stopped.'
  Assert-Equal `
    -Actual $certificateCleanupCalls `
    -Expected 0 `
    -Message 'TLS evidence was deleted after unowned-listener refusal.'

  $downTrustThrowState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      androidTrust = $failedCompensation.state
      proxy = $null
      cleanupPending = $true
    }
    emulator = $ownedEmulator
  }
  $downTrustThrow = Stop-RimsLocalTlsRuntime `
    -State $downTrustThrowState `
    -TlsPaths $pathsA `
    -TrustRemoveAction { param($trust, $emulator) throw 'fake trust remove throw' }
  Assert-False -Value $downTrustThrow.ok -Message 'Down trust cleanup throw escaped.'
  Assert-True `
    -Value $downTrustThrow.cleanupPending `
    -Message 'Down trust cleanup throw lost persisted state.'

  $downProxyThrowState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      androidTrust = $null
      proxy = $proxy.state
      cleanupPending = $true
    }
    emulator = $ownedEmulator
  }
  $downProxyThrow = Stop-RimsLocalTlsRuntime `
    -State $downProxyThrowState `
    -TlsPaths $pathsA `
    -OwnershipAction { param($state, $paths) return [pscustomobject]@{ ok = $true } } `
    -ProxyStopAction { param($state) throw 'fake down proxy stop throw' }
  Assert-False -Value $downProxyThrow.ok -Message 'Down proxy stop throw escaped.'
  Assert-True `
    -Value $downProxyThrow.cleanupPending `
    -Message 'Down proxy stop throw lost persisted state.'

  $downCertificateThrowState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      androidTrust = $null
      proxy = $null
      cleanupPending = $true
    }
    emulator = $ownedEmulator
  }
  $downCertificateThrow = Stop-RimsLocalTlsRuntime `
    -State $downCertificateThrowState `
    -TlsPaths $pathsA `
    -CertificateCleanupAction { param($paths) throw 'fake down certificate cleanup throw' }
  Assert-False `
    -Value $downCertificateThrow.ok `
    -Message 'Down certificate cleanup throw escaped.'
  Assert-True `
    -Value $downCertificateThrow.cleanupPending `
    -Message 'Down certificate cleanup throw lost persisted state.'

  foreach ($failedStep in 1..4) {
    $stepWorkspace = Join-Path $testRoot "openssl-step-$failedStep"
    [void][IO.Directory]::CreateDirectory((Join-Path $stepWorkspace 'scripts'))
    $stepPaths = Get-RimsLocalTlsPaths -ScriptDirectory (Join-Path $stepWorkspace 'scripts')
    $script:tlsOpenSslCall = 0
    $stepFailure = New-RimsLocalTlsCertificates `
      -TlsPaths $stepPaths `
      -OpenSslAction {
        param($arguments, $invocationPaths)
        $script:tlsOpenSslCall++
        [IO.File]::WriteAllText(
          (Join-Path $invocationPaths.root "partial-$script:tlsOpenSslCall"),
          'partial'
        )
        if ($script:tlsOpenSslCall -eq $failedStep) {
          return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake OpenSSL failure' }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $stepFailure.ok `
      -Message "OpenSSL step $failedStep failure was hidden."
    Assert-False `
      -Value (Test-Path -LiteralPath $stepPaths.root) `
      -Message "OpenSSL step $failedStep left partial TLS material."
  }

  $requiredMaterialNames = @(
    'caPrivateKey',
    'caCertificate',
    'serverPrivateKey',
    'serverCertificate',
    'serverPfx'
  )
  foreach ($missingName in $requiredMaterialNames) {
    $missingWorkspace = Join-Path $testRoot "missing-$missingName"
    [void][IO.Directory]::CreateDirectory((Join-Path $missingWorkspace 'scripts'))
    $missingPaths = Get-RimsLocalTlsPaths -ScriptDirectory (Join-Path $missingWorkspace 'scripts')
    $missingResult = New-RimsLocalTlsCertificates `
      -TlsPaths $missingPaths `
      -OpenSslAction {
        param($arguments, $invocationPaths)
        foreach ($materialName in $requiredMaterialNames) {
          if ($materialName -ne $missingName) {
            [IO.File]::WriteAllText([string]$invocationPaths.$materialName, 'partial')
          }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
      }
    Assert-False `
      -Value $missingResult.ok `
      -Message "Missing required TLS material '$missingName' was accepted."
    Assert-False `
      -Value (Test-Path -LiteralPath $missingPaths.root) `
      -Message "Missing required TLS material '$missingName' left partial files."
  }

  $cleanupWorkspace = Join-Path $testRoot 'cleanup-pending'
  [void][IO.Directory]::CreateDirectory((Join-Path $cleanupWorkspace 'scripts'))
  $cleanupPaths = Get-RimsLocalTlsPaths -ScriptDirectory (Join-Path $cleanupWorkspace 'scripts')
  $cleanupFailure = New-RimsLocalTlsCertificates `
    -TlsPaths $cleanupPaths `
    -OpenSslAction {
      param($arguments, $invocationPaths)
      [IO.File]::WriteAllText((Join-Path $invocationPaths.root 'partial'), 'partial')
      return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake generation failure' }
    } `
    -CleanupAction {
      param($paths)
      return [pscustomobject]@{ ok = $false; detail = 'fake cleanup failure' }
    }
  Assert-False -Value $cleanupFailure.ok -Message 'Certificate cleanup failure was hidden.'
  Assert-True `
    -Value $cleanupFailure.cleanupPending `
    -Message 'Certificate cleanup failure was not marked pending.'
  Assert-True `
    -Value $cleanupFailure.state.cleanupPending `
    -Message 'Certificate cleanup failure did not return persistent partial state.'
  Assert-Equal `
    -Actual $cleanupFailure.state.root `
    -Expected $cleanupPaths.root `
    -Message 'Certificate partial state lost its deterministic cleanup root.'

  $throwCleanupWorkspace = Join-Path $testRoot 'cleanup-throw'
  [void][IO.Directory]::CreateDirectory((Join-Path $throwCleanupWorkspace 'scripts'))
  $throwCleanupPaths = Get-RimsLocalTlsPaths `
    -ScriptDirectory (Join-Path $throwCleanupWorkspace 'scripts')
  $throwCleanup = New-RimsLocalTlsCertificates `
    -TlsPaths $throwCleanupPaths `
    -OpenSslAction {
      param($arguments, $invocationPaths)
      [IO.File]::WriteAllText((Join-Path $invocationPaths.root 'partial'), 'partial')
      return [pscustomobject]@{ exitCode = 1; stdout = ''; stderr = 'fake generation failure' }
    } `
    -CleanupAction { param($paths) throw 'fake cleanup throw' }
  Assert-False `
    -Value $throwCleanup.ok `
    -Message 'OpenSSL cleanup throw escaped the certificate boundary.'
  Assert-True `
    -Value $throwCleanup.cleanupPending `
    -Message 'OpenSSL cleanup throw was not persisted as pending.'
  Assert-Equal `
    -Actual $throwCleanup.state.root `
    -Expected $throwCleanupPaths.root `
    -Message 'OpenSSL cleanup throw lost deterministic certificate state.'

  $certificatePartial = [pscustomobject]@{
    workspaceId = $pathsA.workspaceId
    root = $pathsA.root
    certificateCreated = $true
    proxy = $null
    androidTrust = $null
    cleanupPending = $true
  }
  $failedCertificateUp = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target none `
    -CertificateAction {
      param($paths)
      return [pscustomobject]@{
        ok = $false
        detail = 'fake certificate cleanup pending'
        cleanupPending = $true
        state = $certificatePartial
      }
    }
  Assert-True `
    -Value $failedCertificateUp.cleanupPending `
    -Message 'TLS up lost certificate cleanup-pending evidence.'
  Assert-Equal `
    -Actual $failedCertificateUp.state.root `
    -Expected $pathsA.root `
    -Message 'TLS up lost certificate partial state.'
  $partialTlsComponent = New-RimsLocalTlsComponent `
    -State ([pscustomobject]@{ localTls = $certificatePartial }) `
    -TlsPaths $pathsA `
    -Required $true
  Assert-False `
    -Value $partialTlsComponent.ok `
    -Message 'TLS status reported cleanup-pending partial state as healthy.'
  Assert-True `
    -Value $partialTlsComponent.cleanupPending `
    -Message 'TLS status omitted cleanup-pending partial-state evidence.'

  $successfulCertificateState = [pscustomobject]@{
    ok = $true
    created = $true
    caCertificatePath = $pathsA.caCertificate
    serverCertificatePath = $pathsA.serverCertificate
    caFingerprintSha256 = ('AA' * 32)
    serverFingerprintSha256 = ('BB' * 32)
    serverSpkiSha256 = $webSpkiPin
    caSubjectHash = '0123abcd'
    requiredSans = @('localhost', '127.0.0.1', '10.0.2.2')
  }
  $failedProxyUp = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target none `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{
        ok = $false
        detail = 'fake proxy cleanup pending'
        cleanupPending = $true
        state = $proxy.state
      }
    } `
    -CertificateCleanupAction {
      param($paths)
      return [pscustomobject]@{ ok = $false; detail = 'fake certificate cleanup failure' }
    }
  Assert-True `
    -Value $failedProxyUp.cleanupPending `
    -Message 'TLS up lost proxy cleanup-pending evidence.'
  Assert-Equal `
    -Actual $failedProxyUp.state.proxy.windowsPid `
    -Expected $proxy.state.windowsPid `
    -Message 'TLS up lost proxy ownership partial state.'

  $partialTrust = [pscustomobject]@{
    serial = $ownedEmulator.serial
    fingerprintSha256 = ('AA' * 32)
    remotePath = $installed.state.remotePath
    installedByController = $true
    cleanupPending = $true
  }
  $failedTrustUp = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target android `
    -EmulatorState $ownedEmulator `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{ ok = $true; state = $proxy.state }
    } `
    -TrustInstallAction {
      param($paths, $emulator, $fingerprint, $subjectHash)
      return [pscustomobject]@{
        ok = $false
        detail = 'fake trust cleanup pending'
        cleanupPending = $true
        state = $partialTrust
      }
    } `
    -ProxyStopAction {
      param($state)
      return [pscustomobject]@{ ok = $false; detail = 'fake proxy stop failure' }
    } `
    -CertificateCleanupAction {
      param($paths)
      return [pscustomobject]@{ ok = $false; detail = 'fake certificate cleanup failure' }
    }
  Assert-True `
    -Value $failedTrustUp.cleanupPending `
    -Message 'TLS up ignored failed trust/proxy/certificate compensation.'
  Assert-Equal `
    -Actual $failedTrustUp.state.androidTrust.serial `
    -Expected $ownedEmulator.serial `
    -Message 'TLS up lost Android trust partial state.'
  Assert-Equal `
    -Actual $failedTrustUp.state.proxy.windowsPid `
    -Expected $proxy.state.windowsPid `
    -Message 'TLS up lost proxy state after trust compensation failed.'

  [IO.File]::WriteAllText($pathsA.caCertificate, 'workspace CA retained for pending trust')
  $pendingTrustCertificateCleanupCalls = 0
  $pendingTrustUp = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target android `
    -EmulatorState $ownedEmulator `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{ ok = $true; state = $proxy.state }
    } `
    -TrustInstallAction {
      param($paths, $emulator, $fingerprint, $subjectHash)
      return [pscustomobject]@{
        ok = $false
        detail = 'fake owned trust cleanup pending'
        cleanupPending = $true
        state = $installed.state
      }
    } `
    -ProxyStopAction { param($state) return [pscustomobject]@{ ok = $true } } `
    -CertificateCleanupAction {
      param($paths)
      $script:pendingTrustCertificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-Equal `
    -Actual $pendingTrustCertificateCleanupCalls `
    -Expected 0 `
    -Message 'TLS up deleted local CA material while owned trust cleanup was pending.'
  Assert-True `
    -Value $pendingTrustUp.state.certificateCreated `
    -Message 'TLS up did not retain certificate ownership state required for trust verification.'
  Assert-True `
    -Value (Test-Path -LiteralPath $pathsA.caCertificate -PathType Leaf) `
    -Message 'TLS up removed the workspace CA before Android trust cleanup completed.'

  $pendingTrustRetryCalls = New-Object 'Collections.Generic.List[string]'
  $pendingTrustFinalCertificateCleanupCalls = 0
  $pendingTrustRetry = Stop-RimsLocalTlsRuntime `
    -State ([pscustomobject]@{
      localTls = $pendingTrustUp.state
      emulator = $ownedEmulator
    }) `
    -TlsPaths $pathsA `
    -TrustRemoveAction {
      param($trust, $emulator)
      return Remove-RimsAndroidUserCa `
        -TrustState $trust `
        -EmulatorState $emulator `
        -TlsPaths $pathsA `
        -EmulatorOwnershipAction { param($state) return $true } `
        -FingerprintAction { param($path) return ('AA' * 32) } `
        -SubjectHashAction { param($path) return $installed.state.subjectHash } `
        -AdbAction {
          param($serial, $arguments)
          $commandText = $arguments -join ' '
          [void]$pendingTrustRetryCalls.Add($commandText)
          if ($commandText -eq $presenceCommand) {
            return [pscustomobject]@{
              exitCode = 0
              stdout = 'EXISTS'
              stderr = ''
            }
          }
          if ($arguments[0] -eq 'pull') {
            [IO.File]::WriteAllText([string]$arguments[2], 'verified remote CA')
          }
          return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
        }
    } `
    -CertificateCleanupAction {
      param($paths)
      $script:pendingTrustFinalCertificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-True `
    -Value $pendingTrustRetry.ok `
    -Message 'Pending owned trust could not be verified and removed on retry.'
  Assert-True `
    -Value (@($pendingTrustRetryCalls) -contains "shell rm -f $($installed.state.remotePath)") `
    -Message 'Pending trust retry did not remove the verified remote CA.'
  Assert-Equal `
    -Actual $pendingTrustFinalCertificateCleanupCalls `
    -Expected 1 `
    -Message 'Certificate material was not cleaned after verified Android trust removal.'

  $upStartThrowCertificateCleanupCalls = 0
  $upStartThrow = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target none `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction { param($paths, $backendPort, $tlsPort) throw 'fake proxy start action throw' } `
    -CertificateCleanupAction {
      param($paths)
      $script:upStartThrowCertificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-False -Value $upStartThrow.ok -Message 'Invoke Up proxy start throw escaped.'
  Assert-Equal `
    -Actual $upStartThrowCertificateCleanupCalls `
    -Expected 1 `
    -Message 'Invoke Up proxy start throw skipped certificate cleanup.'
  Assert-False `
    -Value $upStartThrow.cleanupPending `
    -Message 'Invoke Up proxy start throw remained pending after certificate cleanup.'

  $upCertificateCleanupThrow = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target none `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{
        ok = $false
        detail = 'fake proxy start failure'
        cleanupPending = $false
        state = $null
      }
    } `
    -CertificateCleanupAction { param($paths) throw 'fake up certificate cleanup throw' }
  Assert-False `
    -Value $upCertificateCleanupThrow.ok `
    -Message 'Invoke Up certificate cleanup throw escaped.'
  Assert-True `
    -Value $upCertificateCleanupThrow.cleanupPending `
    -Message 'Invoke Up certificate cleanup throw lost certificate state.'
  Assert-True `
    -Value $upCertificateCleanupThrow.state.certificateCreated `
    -Message 'Invoke Up certificate cleanup throw did not retain created material evidence.'

  $unknownTrustCertificateCleanupCalls = 0
  $upTrustThrow = Invoke-RimsLocalTlsUp `
    -TlsPaths $pathsA `
    -BackendPort 8080 `
    -TlsPort 8443 `
    -Target android `
    -EmulatorState $ownedEmulator `
    -CertificateAction { param($paths) return $successfulCertificateState } `
    -ProxyStartAction {
      param($paths, $backendPort, $tlsPort)
      return [pscustomobject]@{ ok = $true; state = $proxy.state }
    } `
    -TrustInstallAction {
      param($paths, $emulator, $fingerprint, $subjectHash)
      throw 'fake trust install throw'
    } `
    -ProxyStopAction { param($state) throw 'fake up proxy stop throw' } `
    -CertificateCleanupAction {
      param($paths)
      $script:unknownTrustCertificateCleanupCalls++
      return [pscustomobject]@{ ok = $true }
    }
  Assert-False -Value $upTrustThrow.ok -Message 'Invoke Up trust install throw escaped.'
  Assert-True `
    -Value $upTrustThrow.cleanupPending `
    -Message 'Invoke Up trust install throw lost cleanup state.'
  Assert-Equal `
    -Actual $upTrustThrow.state.proxy.windowsPid `
    -Expected $proxy.state.windowsPid `
    -Message 'Invoke Up proxy stop throw lost proxy identity.'
  Assert-False `
    -Value $upTrustThrow.state.androidTrust.installedByController `
    -Message 'Unknown trust install throw fabricated controller ownership.'
  Assert-False `
    -Value $upTrustThrow.state.androidTrust.remoteMutationAttempted `
    -Message 'Unknown trust install throw fabricated a remote CA mutation.'
  Assert-Equal `
    -Actual $upTrustThrow.state.androidTrust.cleanupScope `
    -Expected 'temporaryOnly' `
    -Message 'Unknown trust throw did not constrain retry cleanup to deterministic temp PEM.'
  Assert-True `
    -Value ($null -eq $upTrustThrow.state.androidTrust.PSObject.Properties['remotePath']) `
    -Message 'Unknown trust throw fabricated a remote CA path.'
  Assert-Equal `
    -Actual $upTrustThrow.state.androidTrust.temporaryPath `
    -Expected (Get-RimsAndroidCaTemporaryPath -WorkspaceId $pathsA.workspaceId) `
    -Message 'Invoke Up trust throw did not persist deterministic temp cleanup state.'
  Assert-Equal `
    -Actual $unknownTrustCertificateCleanupCalls `
    -Expected 0 `
    -Message 'Unknown trust cleanup pending deleted the local workspace CA.'

  $unknownTrustCleanupCalls = New-Object 'Collections.Generic.List[string]'
  $unknownTrustCleanup = Remove-RimsAndroidUserCa `
    -TrustState $upTrustThrow.state.androidTrust `
    -EmulatorState $ownedEmulator `
    -TlsPaths $pathsA `
    -EmulatorOwnershipAction { param($state) return $true } `
    -AdbAction {
      param($serial, $arguments)
      [void]$unknownTrustCleanupCalls.Add(($arguments -join ' '))
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $unknownTrustCleanup.ok `
    -Message 'Unknown trust throw temp-only cleanup failed on the exact owned emulator.'
  Assert-True `
    -Value (@($unknownTrustCleanupCalls) -contains "shell rm -f $($upTrustThrow.state.androidTrust.temporaryPath)") `
    -Message 'Unknown trust throw did not retry deterministic temp PEM cleanup.'
  Assert-False `
    -Value ((@($unknownTrustCleanupCalls) -join '|').Contains('/data/misc/user/0/cacerts-added/')) `
    -Message 'Unknown trust throw cleanup touched a remote CA path without ownership evidence.'

  $tlsComponentState = [pscustomobject]@{
    localTls = [pscustomobject]@{
      workspaceId = $pathsA.workspaceId
      port = 8443
      caFingerprintSha256 = ('AA' * 32)
      serverFingerprintSha256 = ('BB' * 32)
      serverSpkiSha256 = $webSpkiPin
      requiredSans = @('localhost')
      proxy = $proxy.state
      serverCertificatePath = $pathsA.serverCertificate
      caCertificatePath = $pathsA.caCertificate
    }
  }
  $tlsComponent = New-RimsLocalTlsComponent `
    -State $tlsComponentState `
    -TlsPaths $pathsA `
    -Required $true `
    -OwnershipAction { param($state, $paths) return [pscustomobject]@{ ok = $true; detail = 'owned' } } `
    -CertificateAction { param($state) return [pscustomobject]@{ ok = $true; detail = 'valid' } }
  $tlsComponentJson = $tlsComponent | ConvertTo-Json -Depth 8
  Assert-Equal `
    -Actual $tlsComponent.serverSpkiSha256 `
    -Expected $webSpkiPin `
    -Message 'Public TLS evidence omitted the server SPKI pin.'
  foreach ($privateEvidence in @(
      $pathsA.root,
      $pathsA.caCertificate,
      $pathsA.serverCertificate,
      $pathsA.serverPrivateKey
    )) {
    Assert-False `
      -Value $tlsComponentJson.Contains($privateEvidence) `
      -Message 'Public TLS evidence exposed an absolute TLS material path.'
  }

  $lifecycleSource = [IO.File]::ReadAllText((Join-Path $scriptDir 'lib\rims_local_lifecycle.ps1'))
  Assert-False `
    -Value $lifecycleSource.Contains('stdoutLogPath = $tlsPaths.proxyStdoutLog') `
    -Message 'Local TLS logs expose an absolute stdout path in JSON evidence.'
  Assert-False `
    -Value $lifecycleSource.Contains('stderrLogPath = $tlsPaths.proxyStderrLog') `
    -Message 'Local TLS logs expose an absolute stderr path in JSON evidence.'
  $failedTlsBranch = [regex]::Match(
    $lifecycleSource,
    'if \(-not \$tlsStarted\.ok\) \{(?<body>[\s\S]*?)return Complete-RimsFailedUpResult'
  )
  Assert-True -Value $failedTlsBranch.Success -Message 'TLS failed-up lifecycle branch was not found.'
  Assert-True `
    -Value $failedTlsBranch.Groups['body'].Value.Contains('$newState.localTls = $tlsStarted.state') `
    -Message 'TLS failed-up lifecycle does not persist returned partial cleanup state.'

  Write-Host 'Local TLS runtime test passed.'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
