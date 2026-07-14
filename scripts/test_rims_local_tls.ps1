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

try {
  [void][IO.Directory]::CreateDirectory((Join-Path $workspaceA 'scripts'))
  [void][IO.Directory]::CreateDirectory((Join-Path $workspaceB 'scripts'))

  $localCommand = Get-Command `
    -Name (Join-Path $scriptDir 'rims_local.ps1') `
    -CommandType ExternalScript
  Assert-True `
    -Value $localCommand.Parameters.ContainsKey('UseLocalTls') `
    -Message 'The local command wrapper did not declare -UseLocalTls.'
  $repositoryTlsPaths = Get-RimsLocalTlsPaths -ScriptDirectory $scriptDir
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

  $webLaunch = New-FlutterLaunchSpec `
    -Target web `
    -FrontendDirectory (Join-Path $workspaceA 'rims_frontend') `
    -BackendPort 8080 `
    -FrontendPort 8091 `
    -UseLocalTls `
    -TlsPort 8443
  Assert-Contains `
    -Collection $webLaunch.arguments `
    -Expected '--dart-define=ALLOW_LOCAL_HTTP=false' `
    -Message 'TLS Web launch did not disable local HTTP.'
  Assert-Contains `
    -Collection $webLaunch.arguments `
    -Expected '--dart-define=API_BASE_URL=https://localhost:8443/api/v1' `
    -Message 'TLS Web launch did not use the owned HTTPS proxy.'
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
    -FingerprintAction { param($path) return ('AA' * 32) }
  Assert-True -Value $certificateResult.ok -Message 'Fake certificate generation failed.'
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

  $fakeStartedAt = '2026-07-15T01:02:03.0000000Z'
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
        commandLine = $spec.commandLine
      }
    } `
    -ReadinessAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $processId -eq 4242 }
  Assert-True -Value $proxy.ok -Message 'Owned fake TLS proxy did not start.'
  $proxyScriptText = [IO.File]::ReadAllText($pathsA.proxyScript)
  Assert-True `
    -Value $proxyScriptText.Contains('EphemeralKeySet') `
    -Message 'TLS proxy did not keep imported PFX keys ephemeral.'
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
    -CommandLineAction { param($processId) return $proxy.state.commandLine }
  Assert-True -Value $owned.ok -Message 'Exact fake TLS proxy ownership was rejected.'
  $wrongCommand = Test-RimsLocalTlsProxyOwnership `
    -TlsState $proxy.state `
    -TlsPaths $pathsA `
    -ProcessOwnershipAction { param($state) return $true } `
    -PortOwnershipAction { param($port, $processId) return $true } `
    -CommandLineAction { param($processId) return 'powershell unrelated-proxy.ps1' }
  Assert-False `
    -Value $wrongCommand.ok `
    -Message 'TLS ownership accepted the wrong command line.'

  $ownedEmulator = [pscustomobject]@{
    serial = 'emulator-5556'
    avdName = 'Medium_Phone_API_36.1'
    windowsPid = 5151
    windowsProcessStartTimeUtc = $fakeStartedAt
  }
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
  $adbCalls.Clear()
  $removedOwnedTrust = Remove-RimsAndroidUserCa `
    -TrustState $installed.state `
    -EmulatorState $ownedEmulator `
    -EmulatorOwnershipAction { param($state) return $true } `
    -AdbAction {
      param($serial, $arguments)
      [void]$adbCalls.Add(($arguments -join ' '))
      return [pscustomobject]@{ exitCode = 0; stdout = ''; stderr = '' }
    }
  Assert-True `
    -Value $removedOwnedTrust.ok `
    -Message 'Controller-installed Android CA removal failed.'
  Assert-Equal `
    -Actual $adbCalls.Count `
    -Expected 1 `
    -Message 'Owned Android CA removal crossed the ADB boundary more than once.'
  Assert-True `
    -Value $adbCalls[0].Contains($installed.state.remotePath) `
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
  $preserved = Remove-RimsAndroidUserCa `
    -TrustState $preExisting.state `
    -EmulatorState $ownedEmulator `
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

  Write-Host 'Local TLS runtime test passed.'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
