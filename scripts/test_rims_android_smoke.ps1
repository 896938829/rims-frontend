$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptDir 'rims_android_smoke.ps1'
$localScript = Join-Path $scriptDir 'rims_local.ps1'

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
  throw "Missing Android smoke wrapper: $wrapper"
}
$localText = Get-Content -LiteralPath $localScript -Raw
$webWrapperText = Get-Content `
  -LiteralPath (Join-Path $scriptDir 'rims_web_e2e.ps1') `
  -Raw
$androidWrapperText = Get-Content -LiteralPath $wrapper -Raw
$windowsHealthAction = [regex]::Match(
  $androidWrapperText,
  "'windows-healthz'\s*\{\s*\{(?<body>.*?)\r?\n\s*\}\s*\}\s*'emulator-healthz'",
  [Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $windowsHealthAction.Success -or
    -not $windowsHealthAction.Groups['body'].Value.Contains(
      'Test-WindowsHealthzOnce -Port $healthPort'
    )) {
  throw 'Windows health action must probe the selected owned bridge port.'
}

function Test-StrictInteger {
  param($Value)
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
}

function Assert-StrictNetworkEvidence {
  param($Evidence, [string]$Message)
  if ($null -eq $Evidence) { throw "$Message Network evidence is missing." }
  foreach ($portName in @(
      'backendTargetPort', 'ownedBridgePort', 'faultProxyPort'
    )) {
    $port = $Evidence.$portName
    if (-not (Test-StrictInteger $port) -or $port -lt 1 -or $port -gt 65535) {
      throw "$Message '$portName' is not a strict valid integer port."
    }
  }
  if ($Evidence.backendTargetPort -eq $Evidence.faultProxyPort -or
      $Evidence.ownedBridgePort -eq $Evidence.faultProxyPort) {
    throw "$Message Fault proxy port overlaps its target or upstream."
  }
  foreach ($identityName in @('hostBridge', 'faultProxy')) {
    $identity = $Evidence.$identityName
    if ($null -eq $identity -or $identity.owned -isnot [bool] -or
        -not $identity.owned -or
        -not (Test-StrictInteger $identity.windowsPid) -or
        $identity.windowsPid -le 0) {
      throw "$Message '$identityName' identity is malformed."
    }
    $parsedStart = [DateTimeOffset]::MinValue
    if ($identity.windowsProcessStartTimeUtc -isnot [string] -or
        [string]::IsNullOrWhiteSpace($identity.windowsProcessStartTimeUtc) -or
        -not [DateTimeOffset]::TryParse(
          $identity.windowsProcessStartTimeUtc,
          [ref]$parsedStart
        )) {
      throw "$Message '$identityName' start time is malformed."
    }
  }
  Assert-Equal -Actual $Evidence.hostBridge.listenPort -Expected $Evidence.ownedBridgePort -Message "$Message host bridge listen port."
  Assert-Equal -Actual $Evidence.hostBridge.upstreamPort -Expected $Evidence.backendTargetPort -Message "$Message host bridge upstream port."
  Assert-Equal -Actual $Evidence.faultProxy.listenPort -Expected $Evidence.faultProxyPort -Message "$Message fault proxy listen port."
  Assert-Equal -Actual $Evidence.faultProxy.upstreamPort -Expected $Evidence.ownedBridgePort -Message "$Message fault proxy upstream port."
  $route = $Evidence.routeValidation
  if ($null -eq $route -or $route.ok -isnot [bool] -or -not $route.ok -or
      $route.proxyReachedVerifiedBackend -isnot [bool] -or
      -not $route.proxyReachedVerifiedBackend -or
      $route.unownedListenerReached -isnot [bool] -or
      $route.unownedListenerReached -or
      $route.expectedBackendIdentity -isnot [string] -or
      $route.observedBackendIdentity -isnot [string] -or
      $route.expectedBackendIdentity -cne $route.observedBackendIdentity) {
    throw "$Message route validation is malformed or did not prove backend identity."
  }
}
foreach ($resetEvidenceContract in @(
    'RIMS_M9_RESET_COUNTS',
    'Reset evidence must emit exactly one strict counts marker.',
    "Reset evidence left nonzero '`$name'."
  )) {
  if (-not $androidWrapperText.Contains($resetEvidenceContract)) {
    throw "Android baseline parser omitted '$resetEvidenceContract'."
  }
}

function Get-FreeLoopbackPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Test-LoopbackPortClosed {
  param([int]$Port)
  $client = [Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.BeginConnect([Net.IPAddress]::Loopback, $Port, $null, $null)
    return -not ($connect.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
  } catch {
    return $true
  } finally {
    $client.Dispose()
  }
}
if (-not $localText.Contains("'rims_android_smoke.ps1'")) {
  throw 'rims_local smoke does not delegate to the Android wrapper.'
}
if (-not $localText.Contains("@('-AndroidDevice', `$AndroidDevice)")) {
  throw 'rims_local smoke does not pass the explicit Android AVD.'
}
foreach ($text in @($webWrapperText, $androidWrapperText)) {
  if (-not $text.Contains("'acceptance-smoke.lock'")) {
    throw 'Web and Android smoke must share the acceptance runtime lock.'
  }
}

$plan = (& $wrapper `
    -ListPlan `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Output Json) -join "`n" | ConvertFrom-Json

Assert-Equal -Actual $plan.target -Expected 'android' -Message 'Android target.'
Assert-Equal `
  -Actual $plan.androidDevice `
  -Expected 'Medium_Phone_API_36.1' `
  -Message 'Explicit Android AVD.'
Assert-Equal `
  -Actual $plan.apiBaseUrl `
  -Expected 'http://10.0.2.2:18080/api/v1' `
  -Message 'Emulator API URL.'
if (@($plan.command | Where-Object { $_ -eq '-d' }).Count -ne 1) {
  throw 'Android command must contain exactly one explicit device flag.'
}
if (@($plan.command | Where-Object { $_ -eq 'all' }).Count -gt 0) {
  throw 'Android command must never use -d all.'
}
if (@($plan.command | Where-Object { $_ -eq '<resolved-serial>' }).Count -ne 1) {
  throw 'Android command did not bind the lifecycle-resolved serial.'
}
Assert-Equal `
  -Actual (@($plan.readinessChecks) -join '|') `
  -Expected 'windows-healthz|emulator-healthz' `
  -Message 'Android readiness checks.'
Assert-Equal `
  -Actual $plan.preparation `
  -Expected 'backend-only-lifecycle+managed-emulator-helper' `
  -Message 'Android smoke preparation must avoid a duplicate flutter run.'
Assert-Equal `
  -Actual $plan.hostBridge `
  -Expected 'on-demand-owned-loopback-ipv4-to-wsl-ipv6-proxy' `
  -Message 'Android host bridge policy.'
Assert-Equal `
  -Actual $plan.flutterLauncher `
  -Expected 'ProcessStartInfo.WorkingDirectory + cmd.exe -> resolved flutter.bat' `
  -Message 'Android Flutter launcher.'
Assert-Equal `
  -Actual $plan.flutterWorkingDirectory `
  -Expected 'rims_frontend' `
  -Message 'Android Flutter working directory.'
Assert-Equal `
  -Actual $plan.e2eResultMarker `
  -Expected 'RIMS_E2E_RESULT' `
  -Message 'Android E2E result marker.'
$e2eTestText = Get-Content `
  -LiteralPath (Join-Path $scriptDir '..\rims_frontend\integration_test\app_e2e_test.dart') `
  -Raw
if (-not $e2eTestText.Contains("debugPrint('RIMS_E2E_RESULT `$") -or
    -not $e2eTestText.Contains('jsonEncode(reportData)')) {
  throw 'App E2E test does not emit machine-readable Android segment data.'
}
Assert-Equal `
  -Actual $plan.artifactDirectory `
  -Expected 'per-run-unique' `
  -Message 'Android artifact directory policy.'
Assert-Equal `
  -Actual $plan.cleanup.hostBridge `
  -Expected 'stop-only-on-pid-and-start-time-match' `
  -Message 'Android host bridge cleanup policy.'
Assert-Equal `
  -Actual (@($plan.failureArtifacts) -join '|') `
  -Expected 'device-screenshot|filtered-logcat|backend-log-tails|flutter-output' `
  -Message 'Android failure artifacts.'
Assert-Equal `
  -Actual $plan.cleanup.preExistingDevice `
  -Expected 'preserve' `
  -Message 'Pre-existing device cleanup policy.'
Assert-Equal `
  -Actual $plan.cleanup.controllerStartedDevice `
  -Expected 'stop-only-on-pid-and-start-time-match' `
  -Message 'Owned device cleanup policy.'

$fieldPlan = (& $wrapper `
    -ListPlan `
    -Phase 'field-operations' `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Output Json) -join "`n" | ConvertFrom-Json
Assert-Equal `
  -Actual $fieldPlan.phase `
  -Expected 'field-operations' `
  -Message 'M10 Android phase.'
if (@($fieldPlan.command | Where-Object {
      $_ -eq 'integration_test/m10_field_operations_test.dart'
    }).Count -ne 1) {
  throw 'M10 Android command omitted the field-operations integration test.'
}
foreach ($define in @(
    '--dart-define=RIMS_E2E_FIELD_OPERATIONS=true',
    '--dart-define=RIMS_E2E_BARCODE=M10-ACTIVE-001',
    '--dart-define=RIMS_E2E_PICKED_FILE=provider-file'
  )) {
  if (@($fieldPlan.command | Where-Object { $_ -eq $define }).Count -ne 1) {
    throw "M10 Android command omitted '$define'."
  }
}
Assert-Equal `
  -Actual (@($fieldPlan.deviceActions) -join '|') `
  -Expected 'camera-deny|camera-grant|home-resume|process-recreation|network-disable-enable|provider-cleanup' `
  -Message 'M10 device action contract.'
Assert-Equal `
  -Actual (@($fieldPlan.failureArtifacts) -join '|') `
  -Expected 'device-screenshot|filtered-logcat|backend-log-tails|flutter-output|upload-provider-log' `
  -Message 'M10 upload failure evidence.'

$offlinePlan = (& $wrapper `
    -ListPlan `
    -Phase 'offline-sync' `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -FaultProxyPort 18081 `
    -Output Json) -join "`n" | ConvertFrom-Json
Assert-Equal `
  -Actual $offlinePlan.phase `
  -Expected 'offline-sync' `
  -Message 'M11 Android phase.'
Assert-Equal -Actual $offlinePlan.backendTargetPort -Expected 18080 -Message 'M11 backend target port.'
Assert-Equal -Actual $offlinePlan.faultProxyPort -Expected 18081 -Message 'M11 fault proxy port.'
$defaultOwnedBridgePort = [int]$offlinePlan.ownedBridgePort
if ($defaultOwnedBridgePort -lt 1 -or $defaultOwnedBridgePort -gt 65535 -or
    $defaultOwnedBridgePort -eq $offlinePlan.faultProxyPort) {
  throw 'M11 plan selected an invalid owned bridge port.'
}
Assert-Equal `
  -Actual $offlinePlan.connectionChain `
  -Expected 'emulator->owned-fault-proxy->owned-host-bridge->verified-wsl-backend' `
  -Message 'M11 owned connection chain.'
Assert-Equal `
  -Actual $offlinePlan.portOwnership.backendTarget `
  -Expected 'verified-managed-wsl-runtime' `
  -Message 'M11 backend target ownership.'
Assert-Equal `
  -Actual $offlinePlan.portOwnership.hostBridge `
  -Expected 'run-owned-pid-and-start-time' `
  -Message 'M11 host bridge ownership.'
Assert-Equal `
  -Actual $offlinePlan.portOwnership.faultProxy `
  -Expected 'run-owned-pid-and-start-time' `
  -Message 'M11 fault proxy ownership.'
Assert-Equal `
  -Actual $offlinePlan.apiBaseUrl `
  -Expected 'http://10.0.2.2:18081/api/v1' `
  -Message 'M11 fault-proxy API URL.'
if (@($offlinePlan.command | Where-Object {
      $_ -eq 'integration_test/m11_offline_sync_test.dart'
    }).Count -ne 1) {
  throw 'M11 Android command omitted the offline-sync integration test.'
}
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$gitCommonDir = (& git -C $repoRoot rev-parse --git-common-dir).Trim()
if (-not [IO.Path]::IsPathRooted($gitCommonDir)) {
  $gitCommonDir = [IO.Path]::GetFullPath((Join-Path $repoRoot $gitCommonDir))
}
$frontendRepository = Split-Path -Parent $gitCommonDir
$frontendBranch = (& git -C $repoRoot branch --show-current).Trim()
$backendSeedCandidates = @(Get-ChildItem `
    -LiteralPath (Join-Path $frontendRepository '.worktrees') `
    -Directory `
    -ErrorAction SilentlyContinue | ForEach-Object {
      Join-Path $_.FullName 'rims-goProgect\scripts\m9_dev_seed.sh'
    } | Where-Object {
      Test-Path -LiteralPath $_ -PathType Leaf
    } | Where-Object {
      (& git -C (Split-Path -Parent (Split-Path -Parent $_)) branch --show-current 2>$null).Trim() -eq $frontendBranch
    })
if ($backendSeedCandidates.Count -ne 1) {
  throw "Expected one matching backend seed script, found $($backendSeedCandidates.Count)."
}
$backendSeedText = Get-Content -LiteralPath $backendSeedCandidates[0] -Raw
foreach ($resetContract in @(
    "remark LIKE 'M9-E2E:%'",
    'DELETE FROM file_attachments',
    "'namespaceDocuments'",
    "'namespaceTransactions'",
    "'namespaceAttachments'",
    "'namespaceAttachmentFiles'",
    "'fixtureStockQuantity'"
    'reset_object_key_output="$('
  )) {
  if (-not $backendSeedText.Contains($resetContract)) {
    throw "M9 reset omitted M11 baseline contract '$resetContract'."
  }
}
if ($backendSeedText.Contains('mapfile -t reset_object_keys < <(')) {
  throw 'M9 reset attachment query failure is hidden by process substitution.'
}
foreach ($cancellationContract in @(
    'networkGeneration',
    'WaitForNetworkActions',
    'throw new InvalidOperationException("adb network command failed',
    'WriteJson(stream, 500, "ADB Failure", "{\"ok\":false',
    'RunAdb(faultArguments);'
  )) {
  if (-not $androidWrapperText.Contains($cancellationContract)) {
    throw "M11 fault proxy omitted cancellation contract '$cancellationContract'."
  }
}
if ($androidWrapperText.Contains('catch (Exception error) { Log("adb-error')) {
  throw 'M11 fault proxy still swallows ADB exceptions.'
}
$proxySourceMatch = [regex]::Match(
  $androidWrapperText,
  '(?s)public static class RimsM11FaultProxy \{.*?\r?\n\}\r?\n''@'
)
if (-not $proxySourceMatch.Success) {
  throw 'M11 fault proxy C# source could not be extracted for execution tests.'
}
if ($proxySourceMatch.Value.Contains('AddressFamily.InterNetworkV6') -or
    -not $proxySourceMatch.Value.Contains(
      'ownedBridge.Connect(IPAddress.Loopback, upstreamPort);'
    )) {
  throw 'M11 fault proxy still has an ambiguous upstream fallback.'
}
if (-not $proxySourceMatch.Value.Contains(
    'listener.Server.ExclusiveAddressUse = true;'
  )) {
  throw 'M11 fault proxy listener is not exclusively owned by its recorded process.'
}
$proxySource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
'@ + "`n" + ($proxySourceMatch.Value -replace "\r?\n'@$", '')
Add-Type -TypeDefinition $proxySource
$proxyType = [RimsM11FaultProxy]
$bindingFlags = [Reflection.BindingFlags]'NonPublic,Static'
$runAdb = $proxyType.GetMethod('RunAdb', $bindingFlags)
$proxyType.GetField('serial', $bindingFlags).SetValue($null, 'emulator-self-test')
$proxyLog = Join-Path ([IO.Path]::GetTempPath()) ('rims-m11-adb-' + [guid]::NewGuid().ToString('N') + '.log')
$proxyType.GetField('logPath', $bindingFlags).SetValue($null, $proxyLog)
try {
  foreach ($adbExecutable in @(
      (Join-Path $env:SystemRoot 'System32\where.exe'),
      (Join-Path ([IO.Path]::GetTempPath()) 'missing-rims-adb.exe')
    )) {
    $proxyType.GetField('adb', $bindingFlags).SetValue($null, $adbExecutable)
    $threw = $false
    try {
      [void]$runAdb.Invoke($null, @('shell svc wifi disable'))
    } catch {
      $threw = $true
    }
    if (-not $threw) {
      throw "Production RunAdb accepted failing executable '$adbExecutable'."
    }
  }
} finally {
  Remove-Item -LiteralPath $proxyLog -Force -ErrorAction SilentlyContinue
}
foreach ($define in @(
    '--dart-define=RIMS_E2E_M11=true',
    '--dart-define=RIMS_E2E_M11_STAGE=true',
    '--dart-define=RIMS_E2E_M11_FAULT_CONTROL_URL=http://10.0.2.2:18081/__rims_m11',
    '--dart-define=RIMS_E2E_BARCODE=M10-ACTIVE-001'
  )) {
  if (@($offlinePlan.command | Where-Object { $_ -eq $define }).Count -ne 1) {
    throw "M11 Android command omitted '$define'."
  }
}
if (@($offlinePlan.command | Where-Object { $_ -eq '--no-uninstall' }).Count -ne 1) {
  throw 'M11 Android command must preserve app data between process stages.'
}
Assert-Equal `
  -Actual (@($offlinePlan.processStages) -join '|') `
  -Expected 'seed|offline-draft|recovery' `
  -Message 'M11 persisted process stages.'
if ($androidWrapperText.Contains('Select-Object -Last 1')) {
  throw 'Android marker parser still accepts the last injected result.'
}
Assert-Equal `
  -Actual (@($offlinePlan.deviceActions) -join '|') `
  -Expected 'airplane-enable-restore|latency-enable-restore|packet-loss-enable-restore|api-unreachable-enable-restore|wifi-disable-enable|process-recreation|stale-session|stale-permission|duplicate-delivery|server-conflict|database-corruption-quarantine' `
  -Message 'M11 device/fault action contract.'
Assert-Equal `
  -Actual $offlinePlan.faultProxy.ownership `
  -Expected 'start-and-stop-exact-owned-process' `
  -Message 'M11 proxy ownership.'
Assert-Equal `
  -Actual $offlinePlan.cleanup.adbNetworkState `
  -Expected 'restore-in-finally' `
  -Message 'M11 ADB restoration.'
$fieldTestText = Get-Content `
  -LiteralPath (Join-Path $scriptDir '..\rims_frontend\integration_test\m10_field_operations_test.dart') `
  -Raw
foreach ($segment in @(
    'cameraLifecycle',
    'scanFeedback',
    'documentSubmission',
    'uploadFirstProgress',
    'uploadTotal',
    'permissionBoundary'
  )) {
  if (-not $fieldTestText.Contains("segments['$segment']")) {
    throw "M10 integration test omitted segment '$segment'."
  }
}
if (-not $fieldTestText.Contains("debugPrint('RIMS_E2E_RESULT `$")) {
  throw 'M10 integration test omitted the machine-readable result marker.'
}
$androidWrapperText = Get-Content -LiteralPath $wrapper -Raw
if (-not $androidWrapperText.Contains("shell 'pidof' 'com.example.rims_frontend'") -or
    -not $androidWrapperText.Contains('Start-FieldPermissionGrantHelper')) {
  throw 'M10 wrapper does not grant camera permission after app launch.'
}

$previousDevice = $env:RIMS_ANDROID_DEVICE
try {
  $env:RIMS_ANDROID_DEVICE = $null
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $missingOutput = @(& powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $wrapper `
        -ListPlan `
        -Output Json 2>&1)
    $missingExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($missingExitCode -eq 0) {
    throw 'Android plan accepted a missing explicit AVD.'
  }
  if (($missingOutput -join ' ') -notmatch 'AndroidDevice|RIMS_ANDROID_DEVICE') {
    throw 'Missing-device error omitted configuration guidance.'
  }
  if (($missingOutput -join ' ') -notmatch 'Medium_Phone_API_36\.1') {
    throw 'Missing-device error omitted available AVD names.'
  }
  if (($missingOutput -join ' ') -notmatch 'Online devices:') {
    throw 'Missing-device error omitted online device names.'
  }
} finally {
  $env:RIMS_ANDROID_DEVICE = $previousDevice
}

$tempRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-android-smoke-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$fixtureProcess = $null
try {
  $occupiedBackendPort = Get-FreeLoopbackPort
  do {
    $networkFaultProxyPort = Get-FreeLoopbackPort
  } while ($networkFaultProxyPort -eq $occupiedBackendPort)
  $fixtureHelper = Join-Path $tempRoot 'dual-backend-fixture.ps1'
  $fixtureReady = Join-Path $tempRoot 'dual-backend-ready.txt'
  $fixtureSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class RimsDualBackendFixture {
  public static void Run(int port, string readyPath) {
    var ipv4 = new TcpListener(IPAddress.Loopback, port);
    var ipv6 = new TcpListener(IPAddress.IPv6Loopback, port);
    ipv6.Server.DualMode = false;
    ipv4.Start();
    ipv6.Start();
    File.WriteAllText(readyPath, "ready");
    Task.Factory.StartNew(
      () => Loop(ipv4, "B"),
      CancellationToken.None,
      TaskCreationOptions.LongRunning,
      TaskScheduler.Default);
    Loop(ipv6, "A");
  }
  static void Loop(TcpListener listener, string identity) {
    while (true) {
      var client = listener.AcceptTcpClient();
      Handle(client, identity);
    }
  }
  static void Handle(TcpClient client, string identity) {
    using (client) {
      var stream = client.GetStream();
      var buffer = new byte[4096];
      stream.Read(buffer, 0, buffer.Length);
      var body = Encoding.UTF8.GetBytes("{\"ok\":true,\"backend\":\"" + identity + "\"}");
      var header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
      stream.Write(header, 0, header.Length);
      stream.Write(body, 0, body.Length);
    }
  }
}
'@
  $fixtureHelperBody = @"
param([int]`$Port, [string]`$ReadyPath)
Add-Type -TypeDefinition @'
$fixtureSource
'@
[RimsDualBackendFixture]::Run(`$Port, `$ReadyPath)
"@
  Set-Content -LiteralPath $fixtureHelper -Value $fixtureHelperBody -Encoding UTF8
  $fixtureProcess = Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fixtureHelper,
      '-Port', "$occupiedBackendPort", '-ReadyPath', $fixtureReady
    ) `
    -WindowStyle Hidden `
    -PassThru
  $fixtureDeadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $fixtureReady -PathType Leaf) -and
      -not $fixtureProcess.HasExited -and
      [DateTime]::UtcNow -lt $fixtureDeadline) {
    Start-Sleep -Milliseconds 100
  }
  if ($fixtureProcess.HasExited -or
      -not (Test-Path -LiteralPath $fixtureReady -PathType Leaf)) {
    throw 'Dual backend fixture did not start.'
  }
  $unownedHealth = Invoke-RestMethod `
    -Uri "http://127.0.0.1:$occupiedBackendPort/healthz" `
    -TimeoutSec 2
  Assert-Equal -Actual $unownedHealth.backend -Expected 'B' -Message 'Unowned IPv4 backend fixture.'

  $occupiedPlan = (& $wrapper `
      -ListPlan `
      -Phase 'offline-sync' `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -BackendPort $occupiedBackendPort `
      -FaultProxyPort $networkFaultProxyPort `
      -Output Json) -join "`n" | ConvertFrom-Json
  Assert-Equal -Actual $occupiedPlan.backendTargetPort -Expected $occupiedBackendPort -Message 'Occupied plan backend target.'
  if ($occupiedPlan.ownedBridgePort -eq $occupiedBackendPort -or
      $occupiedPlan.ownedBridgePort -eq $networkFaultProxyPort) {
    throw 'Occupied backend port was reused as the owned bridge endpoint.'
  }

  $networkReportPath = Join-Path $tempRoot 'owned-network-report.json'
  $networkRecordPath = Join-Path $tempRoot 'owned-network-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -Phase 'offline-sync' `
    -BackendPort $occupiedBackendPort `
    -FaultProxyPort $networkFaultProxyPort `
    -TestMode `
    -TestOwnedNetworkHarness `
    -FailStep 'android-integration-test' `
    -ReportPath $networkReportPath `
    -ArtifactRoot (Join-Path $tempRoot 'owned-network-artifacts') `
    -M11CommandRecordPath $networkRecordPath
  Assert-Equal -Actual $LASTEXITCODE -Expected 23 -Message 'Owned network harness first failure.'
  $networkReport = Get-Content -LiteralPath $networkReportPath -Raw | ConvertFrom-Json
  Assert-StrictNetworkEvidence `
    -Evidence $networkReport.networkEvidence `
    -Message 'Owned network report.'
  Assert-Equal `
    -Actual @($networkReport.networkEvidenceErrors).Count `
    -Expected 0 `
    -Message 'Owned network validator errors.'
  Assert-Equal -Actual $networkReport.backendTargetPort -Expected $occupiedBackendPort -Message 'Report backend target.'
  Assert-Equal -Actual $networkReport.ownedBridgePort -Expected $occupiedPlan.ownedBridgePort -Message 'Report owned bridge.'
  Assert-Equal -Actual $networkReport.faultProxyPort -Expected $networkFaultProxyPort -Message 'Report fault proxy.'
  Assert-Equal -Actual $networkReport.routeValidation.backend -Expected 'A' -Message 'Fault proxy routed to verified backend A.'
  Assert-Equal -Actual $networkReport.hostBridge.owned -Expected $true -Message 'Owned bridge identity.'
  Assert-Equal -Actual $networkReport.faultProxy.owned -Expected $true -Message 'Owned proxy identity.'
  if ([int]$networkReport.hostBridge.windowsPid -le 0 -or
      [string]::IsNullOrWhiteSpace(
        [string]$networkReport.hostBridge.windowsProcessStartTimeUtc
      )) {
    throw 'Owned bridge report omitted PID/start-time identity.'
  }
  if ([int]$networkReport.faultProxy.windowsPid -le 0 -or
      [string]::IsNullOrWhiteSpace(
        [string]$networkReport.faultProxy.windowsProcessStartTimeUtc
      )) {
    throw 'Owned fault proxy report omitted PID/start-time identity.'
  }
  Assert-Equal -Actual $networkReport.hostBridgeCleanup.ok -Expected $true -Message 'Owned bridge cleanup.'
  Assert-Equal -Actual $networkReport.faultProxyCleanup.ok -Expected $true -Message 'Owned proxy cleanup.'
  Assert-Equal -Actual $networkReport.faultProxy.upstreamPort -Expected $networkReport.ownedBridgePort -Message 'Proxy upstream chain.'
  if ($fixtureProcess.HasExited) { throw 'Runner stopped the unowned backend listener.' }
  $preservedHealth = Invoke-RestMethod `
    -Uri "http://127.0.0.1:$occupiedBackendPort/healthz" `
    -TimeoutSec 2
  Assert-Equal -Actual $preservedHealth.backend -Expected 'B' -Message 'Unowned listener preservation.'
  if (-not (Test-LoopbackPortClosed -Port $networkReport.ownedBridgePort)) {
    throw 'Owned bridge listener remained after cleanup.'
  }
  if (-not (Test-LoopbackPortClosed -Port $networkReport.faultProxyPort)) {
    throw 'Owned fault proxy listener remained after cleanup.'
  }

  $networkMutationCases = @(
    @{ Name = 'missing-host-identity'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('hostBridge')
      } },
    @{ Name = 'missing-proxy-identity'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('faultProxy')
      } },
    @{ Name = 'zero-pid'; Mutate = {
        param($value) $value.hostBridge.windowsPid = 0
      } },
    @{ Name = 'string-pid'; Mutate = {
        param($value) $value.faultProxy.windowsPid = '1234'
      } },
    @{ Name = 'bad-start-time'; Mutate = {
        param($value) $value.hostBridge.windowsProcessStartTimeUtc = 'not-a-time'
      } },
    @{ Name = 'string-owned'; Mutate = {
        param($value) $value.faultProxy.owned = 'true'
      } },
    @{ Name = 'bridge-listen-mismatch'; Mutate = {
        param($value) $value.hostBridge.listenPort = $value.ownedBridgePort + 10
      } },
    @{ Name = 'bridge-upstream-mismatch'; Mutate = {
        param($value) $value.hostBridge.upstreamPort = $value.backendTargetPort + 10
      } },
    @{ Name = 'proxy-listen-mismatch'; Mutate = {
        param($value) $value.faultProxy.listenPort = $value.faultProxyPort + 10
      } },
    @{ Name = 'proxy-upstream-mismatch'; Mutate = {
        param($value) $value.faultProxy.upstreamPort = $value.ownedBridgePort + 10
      } },
    @{ Name = 'route-false'; Mutate = {
        param($value) $value.routeValidation.ok = $false
      } },
    @{ Name = 'route-missing'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('routeValidation')
      } },
    @{ Name = 'route-fake-listener'; Mutate = {
        param($value)
        $value.routeValidation.expectedBackendIdentity = 'B'
        $value.routeValidation.observedBackendIdentity = 'B'
        $value.routeValidation.backend = 'B'
      } },
    @{ Name = 'route-unverified-identity'; Mutate = {
        param($value)
        $value.routeValidation.expectedBackendIdentity = 'C'
        $value.routeValidation.observedBackendIdentity = 'C'
        $value.routeValidation.backend = 'C'
      } },
    @{ Name = 'string-port'; Mutate = {
        param($value) $value.backendTargetPort = '18080'
      } },
    @{ Name = 'port-out-of-range'; Mutate = {
        param($value) $value.faultProxyPort = 65536
      } },
    @{ Name = 'port-negative'; Mutate = {
        param($value) $value.ownedBridgePort = -1
      } }
  )
  foreach ($networkCase in $networkMutationCases) {
    $invalidNetwork = $networkReport.networkEvidence |
      ConvertTo-Json -Depth 12 | ConvertFrom-Json
    & $networkCase.Mutate $invalidNetwork
    $invalidNetworkPath = Join-Path $tempRoot "network-$($networkCase.Name).json"
    $invalidNetwork | ConvertTo-Json -Depth 12 | Set-Content `
      -LiteralPath $invalidNetworkPath `
      -Encoding UTF8
    $invalidNetworkReportPath = Join-Path $tempRoot "network-$($networkCase.Name)-report.json"
    $invalidNetworkRecordPath = Join-Path $tempRoot "network-$($networkCase.Name)-commands.json"
    & $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -Phase 'offline-sync' `
      -BackendPort $occupiedBackendPort `
      -FaultProxyPort $networkFaultProxyPort `
      -TestMode `
      -TestNetworkEvidenceFixturePath $invalidNetworkPath `
      -ReportPath $invalidNetworkReportPath `
      -ArtifactRoot (Join-Path $tempRoot "network-$($networkCase.Name)-artifacts") `
      -M11CommandRecordPath $invalidNetworkRecordPath
    Assert-Equal -Actual $LASTEXITCODE -Expected 2 -Message "Android malformed network '$($networkCase.Name)'."
    $invalidNetworkReport = Get-Content -LiteralPath $invalidNetworkReportPath -Raw |
      ConvertFrom-Json
    $invalidNetworkCommands = @(Get-Content -LiteralPath $invalidNetworkRecordPath -Raw |
        ConvertFrom-Json | ForEach-Object { $_ })
    Assert-Equal -Actual $invalidNetworkReport.ok -Expected $false -Message "Android malformed network '$($networkCase.Name)' report."
    Assert-Equal -Actual $invalidNetworkReport.failedStep -Expected 'validate-network-evidence' -Message "Android malformed network '$($networkCase.Name)' gate."
    foreach ($cleanupResult in @(
        $invalidNetworkReport.baselineRestore.ok,
        $invalidNetworkReport.hostBridgeCleanup.ok,
        $invalidNetworkReport.faultProxyCleanup.ok
      )) {
      Assert-Equal -Actual $cleanupResult -Expected $true -Message "Android malformed network '$($networkCase.Name)' cleanup."
    }
    foreach ($cleanupCommand in @(
        'reset-fault-proxy', 'stop-owned-fault-proxy',
        'stop-owned-host-bridge', 'reset-fixtures-final'
      )) {
      if (-not ($invalidNetworkCommands -contains $cleanupCommand)) {
        throw "Android malformed network '$($networkCase.Name)' omitted cleanup '$cleanupCommand'."
      }
    }
  }

  $markerCases = @(
    @{ Name = 'missing'; Lines = @('ordinary output'); Exit = 1 },
    @{ Name = 'duplicate'; Lines = @(
        'RIMS_E2E_RESULT {"ok":true}',
        'RIMS_E2E_RESULT {"ok":true}'
      ); Exit = 1 },
    @{ Name = 'valid-malformed'; Lines = @(
        'RIMS_E2E_RESULT {"ok":true}',
        'RIMS_E2E_RESULT {broken'
      ); Exit = 1 },
    @{ Name = 'malformed'; Lines = @('RIMS_E2E_RESULT {broken'); Exit = 1 },
    @{ Name = 'trailing'; Lines = @(
        'RIMS_E2E_RESULT {"ok":true} injected'
      ); Exit = 1 },
    @{ Name = 'non-object'; Lines = @('RIMS_E2E_RESULT [1,2]'); Exit = 1 },
    @{ Name = 'valid'; Lines = @('RIMS_E2E_RESULT {"ok":true}'); Exit = 0 }
  )
  foreach ($markerCase in $markerCases) {
    $markerPath = Join-Path $tempRoot "marker-$($markerCase.Name).log"
    $markerCase.Lines | Set-Content -LiteralPath $markerPath -Encoding UTF8
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $markerOutput = @(& powershell.exe `
          -NoProfile `
          -ExecutionPolicy Bypass `
          -File $wrapper `
          -AndroidDevice 'Medium_Phone_API_36.1' `
          -TestMode `
          -TestMarkerFixturePath $markerPath `
          -TestExpectedMarker Result 2>&1)
      $markerExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    Assert-Equal `
      -Actual $markerExit `
      -Expected $markerCase.Exit `
      -Message "Strict marker case '$($markerCase.Name)'."
    if ($markerExit -ne 0 -and ($markerOutput -join ' ') -match 'ok.:true') {
      throw "Rejected marker '$($markerCase.Name)' leaked accepted evidence."
    }
  }

  foreach ($invalidFailStep in @('not-a-step', 'write-report')) {
    $invalidReport = Join-Path $tempRoot "invalid-$invalidFailStep.json"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $null = & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $wrapper `
        -AndroidDevice 'Medium_Phone_API_36.1' `
        -TestMode `
        -FailStep $invalidFailStep `
        -ReportPath $invalidReport 2>&1
      $invalidExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($invalidExitCode -eq 0 -or (Test-Path -LiteralPath $invalidReport)) {
      throw "Invalid TestMode FailStep '$invalidFailStep' produced a report."
    }
  }

  $nestedReport = Join-Path $tempRoot 'missing\parent\failure.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -TestMode `
    -FailStep 'doctor-android' `
    -ReportPath $nestedReport `
    -ArtifactRoot (Join-Path $tempRoot 'nested-artifacts')
  if ($LASTEXITCODE -eq 0 -or -not (Test-Path -LiteralPath $nestedReport)) {
    throw 'Android smoke did not create a custom report parent directory.'
  }

  $existingRuntimeReport = Join-Path $tempRoot 'existing-runtime-report.json'
  $existingRuntimeCleanup = Join-Path $tempRoot 'existing-runtime-cleanup.txt'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -TestMode `
    -TestPreExistingRuntime `
    -FailStep 'up-android' `
    -ReportPath $existingRuntimeReport `
    -ArtifactRoot (Join-Path $tempRoot 'existing-runtime-artifacts') `
    -CleanupRecordPath $existingRuntimeCleanup
  Assert-Equal `
    -Actual (Get-Content -LiteralPath $existingRuntimeCleanup -Raw).Trim() `
    -Expected 'preserve-runtime' `
    -Message 'Pre-existing managed runtime cleanup policy.'

  foreach ($runtimeCase in @(
      [pscustomobject]@{ State = 'healthy-pre-existing'; Exit = 23; Disposition = 'reuse'; Cleanup = 'preserve-runtime' },
      [pscustomobject]@{ State = 'stale'; Exit = 1; Disposition = 'reject'; Cleanup = 'preserve-runtime' },
      [pscustomobject]@{ State = 'stopped'; Exit = 23; Disposition = 'start'; Cleanup = 'stop-owned-runtime' }
    )) {
    $runtimeReportPath = Join-Path $tempRoot "runtime-$($runtimeCase.State).json"
    $runtimeCleanupPath = Join-Path $tempRoot "runtime-$($runtimeCase.State)-cleanup.txt"
    & $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -BackendPort 18080 `
      -TestMode `
      -TestRuntimeState $runtimeCase.State `
      -FailStep 'android-integration-test' `
      -ReportPath $runtimeReportPath `
      -ArtifactRoot (Join-Path $tempRoot "runtime-$($runtimeCase.State)-artifacts") `
      -CleanupRecordPath $runtimeCleanupPath
    Assert-Equal -Actual $LASTEXITCODE -Expected $runtimeCase.Exit -Message "Runtime $($runtimeCase.State) exit."
    $runtimeReport = Get-Content -LiteralPath $runtimeReportPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual $runtimeReport.runtimeDisposition -Expected $runtimeCase.Disposition -Message "Runtime $($runtimeCase.State) disposition."
    Assert-Equal -Actual (Get-Content -LiteralPath $runtimeCleanupPath -Raw).Trim() -Expected $runtimeCase.Cleanup -Message "Runtime $($runtimeCase.State) cleanup."
  }

  foreach ($runtimeBaselineCase in @(
      [pscustomobject]@{
        Name = 'pre-existing-mutated'
        State = 'healthy-pre-existing'
        RuntimeAction = 'preserve-runtime'
      },
      [pscustomobject]@{
        Name = 'stopped-mutated'
        State = 'stopped'
        RuntimeAction = 'stop-owned-runtime'
      }
    )) {
    $runtimeReportPath = Join-Path $tempRoot "$($runtimeBaselineCase.Name)-report.json"
    $runtimeRecordPath = Join-Path $tempRoot "$($runtimeBaselineCase.Name)-commands.json"
    $runtimeCleanupPath = Join-Path $tempRoot "$($runtimeBaselineCase.Name)-cleanup.txt"
    & $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -BackendPort 18080 `
      -Phase 'offline-sync' `
      -TestMode `
      -TestRuntimeState $runtimeBaselineCase.State `
      -FailStep 'android-integration-test' `
      -ReportPath $runtimeReportPath `
      -ArtifactRoot (Join-Path $tempRoot "$($runtimeBaselineCase.Name)-artifacts") `
      -CleanupRecordPath $runtimeCleanupPath `
      -M11CommandRecordPath $runtimeRecordPath
    Assert-Equal -Actual $LASTEXITCODE -Expected 23 -Message "$($runtimeBaselineCase.Name) first exit."
    $runtimeReport = Get-Content -LiteralPath $runtimeReportPath -Raw | ConvertFrom-Json
    $runtimeCommands = @(Get-Content -LiteralPath $runtimeRecordPath -Raw |
        ConvertFrom-Json | ForEach-Object { $_ })
    foreach ($requiredCommand in @(
        'inspect-runtime-state',
        'validate-runtime-identity',
        'health-wsl-ipv6-runtime',
        'windows-health-unavailable-before-bridge',
        "start-owned-host-bridge:$defaultOwnedBridgePort",
        'health-windows-after-bridge',
        'reset-fixtures-initial',
        'reset-fixtures-final',
        'verify-fixture-baseline'
      )) {
      if (-not ($runtimeCommands -contains $requiredCommand)) {
        throw "$($runtimeBaselineCase.Name) omitted '$requiredCommand'."
      }
    }
    if ($runtimeCommands.IndexOf("start-owned-host-bridge:$defaultOwnedBridgePort") -gt
        $runtimeCommands.IndexOf('health-windows-after-bridge')) {
      throw "$($runtimeBaselineCase.Name) checked Windows health before its owned bridge."
    }
    Assert-Equal -Actual $runtimeReport.baselineRestore.resetAttempted -Expected $true -Message "$($runtimeBaselineCase.Name) reset attempt."
    Assert-Equal -Actual $runtimeReport.baselineRestore.resetOk -Expected $true -Message "$($runtimeBaselineCase.Name) reset result."
    Assert-Equal -Actual $runtimeReport.baselineRestore.verified -Expected $true -Message "$($runtimeBaselineCase.Name) baseline verification."
    Assert-Equal -Actual (Get-Content -LiteralPath $runtimeCleanupPath -Raw).Trim() -Expected $runtimeBaselineCase.RuntimeAction -Message "$($runtimeBaselineCase.Name) process cleanup."
  }

  $resetFailureReportPath = Join-Path $tempRoot 'final-reset-failure-report.json'
  $resetFailureRecordPath = Join-Path $tempRoot 'final-reset-failure-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Phase 'offline-sync' `
    -TestMode `
    -TestRuntimeState 'healthy-pre-existing' `
    -TestFixtureResetFailure 'final' `
    -FailStep 'android-integration-test' `
    -ReportPath $resetFailureReportPath `
    -ArtifactRoot (Join-Path $tempRoot 'final-reset-failure-artifacts') `
    -M11CommandRecordPath $resetFailureRecordPath
  Assert-Equal -Actual $LASTEXITCODE -Expected 23 -Message 'Final reset must preserve the journey failure.'
  $resetFailureReport = Get-Content -LiteralPath $resetFailureReportPath -Raw | ConvertFrom-Json
  $resetFailureCommands = @(Get-Content -LiteralPath $resetFailureRecordPath -Raw |
      ConvertFrom-Json | ForEach-Object { $_ })
  Assert-Equal -Actual $resetFailureReport.failedStep -Expected 'android-integration-test' -Message 'Final reset first failure.'
  Assert-Equal -Actual $resetFailureReport.baselineRestore.ok -Expected $false -Message 'Final reset cleanup evidence.'
  if (-not ($resetFailureCommands -contains 'reset-fixtures-final') -or
      ($resetFailureCommands -contains 'verify-fixture-baseline')) {
    throw 'Failed final reset must be attempted and must not claim post-verification.'
  }

  $mismatchReportPath = Join-Path $tempRoot 'baseline-mismatch-report.json'
  $mismatchRecordPath = Join-Path $tempRoot 'baseline-mismatch-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Phase 'offline-sync' `
    -TestMode `
    -TestRuntimeState 'healthy-pre-existing' `
    -TestFixtureBaselineMismatch `
    -FailStep 'android-integration-test' `
    -ReportPath $mismatchReportPath `
    -ArtifactRoot (Join-Path $tempRoot 'baseline-mismatch-artifacts') `
    -M11CommandRecordPath $mismatchRecordPath
  Assert-Equal -Actual $LASTEXITCODE -Expected 23 -Message 'Baseline mismatch must preserve the journey failure.'
  $mismatchReport = Get-Content -LiteralPath $mismatchReportPath -Raw | ConvertFrom-Json
  $mismatchCommands = @(Get-Content -LiteralPath $mismatchRecordPath -Raw |
      ConvertFrom-Json | ForEach-Object { $_ })
  Assert-Equal -Actual $mismatchReport.baselineRestore.resetOk -Expected $true -Message 'Mismatch reset command result.'
  Assert-Equal -Actual $mismatchReport.baselineRestore.verified -Expected $false -Message 'Mismatch post-verification.'
  Assert-Equal -Actual $mismatchReport.baselineRestore.ok -Expected $false -Message 'Mismatch baseline result.'
  if ($mismatchCommands -contains 'verify-fixture-baseline') {
    throw 'Mismatched fixture counts claimed baseline verification.'
  }

  $bridgeFailureReportPath = Join-Path $tempRoot 'bridge-failure-report.json'
  $bridgeFailureRecordPath = Join-Path $tempRoot 'bridge-failure-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Phase 'offline-sync' `
    -TestMode `
    -TestRuntimeState 'healthy-pre-existing' `
    -TestBridgeFailure `
    -FailStep 'android-integration-test' `
    -ReportPath $bridgeFailureReportPath `
    -ArtifactRoot (Join-Path $tempRoot 'bridge-failure-artifacts') `
    -M11CommandRecordPath $bridgeFailureRecordPath
  Assert-Equal -Actual $LASTEXITCODE -Expected 1 -Message 'Bridge failure exit.'
  $bridgeFailureReport = Get-Content -LiteralPath $bridgeFailureReportPath -Raw | ConvertFrom-Json
  $bridgeFailureCommands = @(Get-Content -LiteralPath $bridgeFailureRecordPath -Raw |
      ConvertFrom-Json | ForEach-Object { $_ })
  Assert-Equal -Actual $bridgeFailureReport.runtimeDisposition -Expected 'reject' -Message 'Bridge failure disposition.'
  foreach ($command in @("start-owned-host-bridge:$defaultOwnedBridgePort", 'stop-owned-host-bridge', 'preserve-runtime')) {
    if (-not ($bridgeFailureCommands -contains $command)) {
      throw "Bridge failure cleanup omitted '$command'."
    }
  }

  $restoreReportPath = Join-Path $tempRoot 'restore-failure-report.json'
  $restoreArtifactRoot = Join-Path $tempRoot 'restore-failure-artifacts'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -TestMode `
    -FailStep 'baseline-restore' `
    -ReportPath $restoreReportPath `
    -ArtifactRoot $restoreArtifactRoot
  $restoreReport = Get-Content -LiteralPath $restoreReportPath -Raw | ConvertFrom-Json
  Assert-Equal `
    -Actual $restoreReport.failedStep `
    -Expected 'baseline-restore' `
    -Message 'Baseline-only failure step.'
  Assert-Equal `
    -Actual $restoreReport.artifactCollection.ok `
    -Expected $true `
    -Message 'Baseline-only failure artifact collection.'
  foreach ($artifact in @($restoreReport.failureArtifacts.PSObject.Properties.Value)) {
    if ([string]::IsNullOrWhiteSpace([string]$artifact) -or
        -not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
      throw 'Baseline-only failure omitted an artifact.'
    }
  }

  foreach ($ownership in @('pre-existing', 'controller-started')) {
    $reportPath = Join-Path $tempRoot "$ownership-report.json"
    $artifactRoot = Join-Path $tempRoot "$ownership-artifacts"
    $cleanupRecord = Join-Path $tempRoot "$ownership-cleanup.txt"
    & $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -TestMode `
      -FailStep 'android-integration-test' `
      -TestEmulatorOwnership $ownership `
      -ReportPath $reportPath `
      -ArtifactRoot $artifactRoot `
      -CleanupRecordPath $cleanupRecord
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
      throw "Injected Android failure passed for ownership '$ownership'."
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual $report.ok -Expected $false -Message 'Failure report flag.'
    Assert-Equal `
      -Actual $report.failedStep `
      -Expected 'android-integration-test' `
      -Message 'Failure step.'
    Assert-Equal `
      -Actual (@($report.steps | ForEach-Object { $_.name }) -join '|') `
      -Expected 'doctor-android|up-android|reset-fixtures|windows-healthz|emulator-healthz|android-integration-test|write-report' `
      -Message 'Failure short-circuit order.'
    foreach ($artifactName in @(
        'deviceScreenshot',
        'filteredLogcat',
        'backendLogTails',
        'flutterOutput'
      )) {
      $artifactPath = [string]$report.failureArtifacts.$artifactName
      if ([string]::IsNullOrWhiteSpace($artifactPath) -or
          -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Failure artifact '$artifactName' was not captured."
      }
    }
    $expectedCleanup = 'stop-owned-runtime'
    Assert-Equal `
      -Actual (Get-Content -LiteralPath $cleanupRecord -Raw).Trim() `
      -Expected $expectedCleanup `
      -Message "Cleanup action for $ownership emulator."
  }

  $offlineReportPath = Join-Path $tempRoot 'offline-failure-report.json'
  $offlineRecordPath = Join-Path $tempRoot 'offline-command-record.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -FaultProxyPort 18081 `
    -Phase 'offline-sync' `
    -TestMode `
    -FailStep 'android-integration-test' `
    -ReportPath $offlineReportPath `
    -ArtifactRoot (Join-Path $tempRoot 'offline-artifacts') `
    -M11CommandRecordPath $offlineRecordPath
  if ($LASTEXITCODE -ne 23) {
    throw "Injected M11 Android failure exited '$LASTEXITCODE' instead of 23."
  }
  $offlineReport = Get-Content -LiteralPath $offlineReportPath -Raw | ConvertFrom-Json
  $offlineCommands = Get-Content -LiteralPath $offlineRecordPath -Raw | ConvertFrom-Json
  Assert-Equal `
    -Actual (@($offlineCommands) -join '|') `
    -Expected "inspect-runtime-state|start-owned-backend:18080|validate-runtime-identity|health-wsl-ipv6-runtime|windows-health-unavailable-before-bridge|start-owned-host-bridge:$defaultOwnedBridgePort|health-windows-after-bridge|reset-fixtures-initial|snapshot-airplane-mode|snapshot-wifi|start-owned-fault-proxy:18081|prepare-clean-app-data|run-stage:seed|capture-pid:seed|force-stop:seed|confirm-stopped:seed|run-stage:offline-draft|capture-pid:offline-draft|force-stop:offline-draft|confirm-stopped:offline-draft|run-stage:recovery|capture-pid:recovery|force-stop:recovery|confirm-stopped:recovery|reset-fault-proxy|restore-airplane-mode|restore-wifi|stop-owned-fault-proxy|reset-fixtures-final|verify-fixture-baseline|stop-owned-host-bridge|stop-owned-runtime" `
    -Message 'M11 fault proxy and ADB restoration order.'
  Assert-Equal `
    -Actual $offlineReport.failedStep `
    -Expected 'android-integration-test' `
    -Message 'M11 first failure.'
  Assert-Equal `
    -Actual $offlineReport.faultProxy.owned `
    -Expected $true `
    -Message 'M11 fault proxy ownership.'
  Assert-Equal `
    -Actual $offlineReport.faultProxy.windowsPid `
    -Expected 4343 `
    -Message 'M11 fault proxy PID evidence.'
  Assert-Equal `
    -Actual $offlineReport.adbStateRestore.attempted `
    -Expected $true `
    -Message 'M11 ADB state restoration attempt.'
  Assert-Equal `
    -Actual $offlineReport.adbStateRestore.ok `
    -Expected $true `
    -Message 'M11 ADB state restoration result.'
  Assert-Equal `
    -Actual $offlineReport.faultProxyCleanup.attempted `
    -Expected $true `
    -Message 'M11 proxy cleanup attempt.'
  Assert-Equal `
    -Actual $offlineReport.faultProxyCleanup.ok `
    -Expected $true `
    -Message 'M11 proxy cleanup result.'

  foreach ($adbCase in @(
      [pscustomobject]@{ Name = 'nonzero'; Exit = 31 },
      [pscustomobject]@{ Name = 'throw'; Exit = 32 }
    )) {
    $adbReportPath = Join-Path $tempRoot "adb-$($adbCase.Name)-report.json"
    $adbRecordPath = Join-Path $tempRoot "adb-$($adbCase.Name)-commands.json"
    & $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -Phase 'offline-sync' `
      -TestMode `
      -TestAdbFailure $adbCase.Name `
      -FailStep 'android-integration-test' `
      -ReportPath $adbReportPath `
      -ArtifactRoot (Join-Path $tempRoot "adb-$($adbCase.Name)-artifacts") `
      -M11CommandRecordPath $adbRecordPath
    Assert-Equal -Actual $LASTEXITCODE -Expected $adbCase.Exit -Message "ADB $($adbCase.Name) first exit."
    $adbReport = Get-Content -LiteralPath $adbReportPath -Raw | ConvertFrom-Json
    $adbCommands = Get-Content -LiteralPath $adbRecordPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual $adbReport.faultControl.ok -Expected $false -Message "ADB $($adbCase.Name) control response."
    Assert-Equal -Actual $adbReport.failedStep -Expected 'android-integration-test' -Message "ADB $($adbCase.Name) failed step."
    Assert-Equal -Actual $adbReport.adbStateRestore.attempted -Expected $true -Message "ADB $($adbCase.Name) restore attempt."
    foreach ($requiredAdbCommand in @(
        'control-airplane-mode:false', 'restore-airplane-mode', 'restore-wifi'
      )) {
      if (-not (@($adbCommands) -contains $requiredAdbCommand)) {
        throw "ADB $($adbCase.Name) omitted '$requiredAdbCommand'."
      }
    }
  }
} finally {
  if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
    $fixtureProcess.Kill()
    [void]$fixtureProcess.WaitForExit(5000)
  }
  if ($null -ne $fixtureProcess) { $fixtureProcess.Dispose() }
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Android smoke wrapper self-test passed.'
