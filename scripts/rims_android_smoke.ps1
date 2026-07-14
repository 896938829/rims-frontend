param(
  [switch]$ListPlan,
  [switch]$KeepRunning,
  [switch]$IncludeDependencies,
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$AndroidDevice = $env:RIMS_ANDROID_DEVICE,
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$FaultProxyPort = 0,
  [string]$ReportPath,
  [string]$ArtifactRoot,
  [switch]$TestMode,
  [string]$FailStep,
  [ValidateSet('pre-existing', 'controller-started')]
  [string]$TestEmulatorOwnership = 'pre-existing',
  [switch]$TestPreExistingRuntime,
  [ValidateSet('stopped', 'healthy-pre-existing', 'stale')]
  [string]$TestRuntimeState = 'stopped',
  [ValidateSet('none', 'nonzero', 'throw')]
  [string]$TestAdbFailure = 'none',
  [string]$TestMarkerFixturePath,
  [ValidateSet('Result', 'Stage')]
  [string]$TestExpectedMarker = 'Result',
  [string]$CleanupRecordPath,
  [string]$M11CommandRecordPath,
  [ValidateSet('baseline', 'field-operations', 'offline-sync')]
  [string]$Phase = 'baseline'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepNames = @(
  'doctor-android',
  'up-android',
  'reset-fixtures',
  'windows-healthz',
  'emulator-healthz',
  'android-integration-test',
  'runtime-status',
  'write-report'
)

if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
  $emulatorExecutable = Join-Path `
    $env:LOCALAPPDATA `
    'Android\Sdk\emulator\emulator.exe'
  [string[]]$availableAvds = if (Test-Path -LiteralPath $emulatorExecutable -PathType Leaf) {
    @(& $emulatorExecutable -list-avds 2>$null | Where-Object {
        -not [string]::IsNullOrWhiteSpace("$_")
      })
  } else { @() }
  $adbExecutable = Join-Path `
    $env:LOCALAPPDATA `
    'Android\Sdk\platform-tools\adb.exe'
  [string[]]$onlineDevices = if (Test-Path -LiteralPath $adbExecutable -PathType Leaf) {
    @(& $adbExecutable devices 2>$null | ForEach-Object {
        if ("$_" -match '^(?<serial>\S+)\s+device(?:\s|$)') {
          $Matches.serial
        }
      })
  } else { @() }
  $availableText = if (@($availableAvds).Count -gt 0) {
    $availableAvds -join ', '
  } else { 'none detected' }
  $onlineText = if (@($onlineDevices).Count -gt 0) {
    $onlineDevices -join ', '
  } else { 'none detected' }
  throw "Configure -AndroidDevice or RIMS_ANDROID_DEVICE with an installed AVD name. Available AVDs: $availableText. Online devices: $onlineText."
}
if ($TestMode -and
    [string]::IsNullOrWhiteSpace($FailStep) -and
    [string]::IsNullOrWhiteSpace($TestMarkerFixturePath)) {
  throw 'TestMode requires an explicit FailStep.'
}
if ($TestMode -and
    -not [string]::IsNullOrWhiteSpace($FailStep) -and
    $FailStep -notin @(
    @($stepNames | Where-Object { $_ -ne 'write-report' }) + 'baseline-restore'
  )) {
  throw "TestMode FailStep must be one of: $(@(@($stepNames | Where-Object { $_ -ne 'write-report' }) + 'baseline-restore') -join ', ')."
}
if ($KeepRunning) {
  throw 'Android smoke does not support -KeepRunning because its host bridge must remain exactly owned.'
}
if ($FaultProxyPort -eq 0) { $FaultProxyPort = $BackendPort + 1 }
if ($FaultProxyPort -eq $BackendPort -or
    $FaultProxyPort -lt 1 -or
    $FaultProxyPort -gt 65535) {
  throw 'FaultProxyPort must be a valid port distinct from BackendPort.'
}

$effectiveApiPort = if ($Phase -eq 'offline-sync') {
  $FaultProxyPort
} else { $BackendPort }
$apiBaseUrl = "http://10.0.2.2:$effectiveApiPort/api/v1"
$integrationTestPath = switch ($Phase) {
  'field-operations' { 'integration_test/m10_field_operations_test.dart' }
  'offline-sync' { 'integration_test/m11_offline_sync_test.dart' }
  default { 'integration_test/app_e2e_test.dart' }
}
$fieldDefines = if ($Phase -eq 'field-operations') {
  @(
    '--dart-define=RIMS_E2E_FIELD_OPERATIONS=true',
    '--dart-define=RIMS_E2E_BARCODE=M10-ACTIVE-001',
    '--dart-define=RIMS_E2E_PICKED_FILE=provider-file'
  )
} else { @() }
$offlineDefines = if ($Phase -eq 'offline-sync') {
  @(
    '--dart-define=RIMS_E2E_M11=true',
    '--dart-define=RIMS_E2E_M11_STAGE=true',
    "--dart-define=RIMS_E2E_M11_FAULT_CONTROL_URL=http://10.0.2.2:$FaultProxyPort/__rims_m11",
    '--dart-define=RIMS_E2E_FIELD_OPERATIONS=true',
    '--dart-define=RIMS_E2E_BARCODE=M10-ACTIVE-001',
    '--dart-define=RIMS_E2E_PICKED_FILE=m11-offline-attachment'
  )
} else { @() }
$offlineRunnerArguments = if ($Phase -eq 'offline-sync') {
  @('--no-uninstall')
} else { @() }
$failureArtifactNames = @(
  'device-screenshot',
  'filtered-logcat',
  'backend-log-tails',
  'flutter-output'
)
if ($Phase -eq 'field-operations') {
  $failureArtifactNames += 'upload-provider-log'
}
if ($Phase -eq 'offline-sync') {
  $failureArtifactNames += @('fault-proxy-log', 'offline-database-evidence')
}
$plan = [pscustomobject][ordered]@{
  schemaVersion = 1
  target = 'android'
  phase = $Phase
  androidDevice = $AndroidDevice
  apiBaseUrl = $apiBaseUrl
  preparation = 'backend-only-lifecycle+managed-emulator-helper'
  hostBridge = 'on-demand-owned-loopback-ipv4-to-wsl-ipv6-proxy'
  flutterLauncher = 'ProcessStartInfo.WorkingDirectory + cmd.exe -> resolved flutter.bat'
  flutterWorkingDirectory = 'rims_frontend'
  e2eResultMarker = 'RIMS_E2E_RESULT'
  artifactDirectory = 'per-run-unique'
  command = @(
    'flutter', 'test', '--no-pub'
  ) + $offlineRunnerArguments + @(
    $integrationTestPath,
    '-d', '<resolved-serial>',
    "--dart-define=API_BASE_URL=$apiBaseUrl"
  ) + $fieldDefines + $offlineDefines
  deviceActions = if ($Phase -eq 'field-operations') {
    @(
      'camera-deny',
      'camera-grant',
      'home-resume',
      'process-recreation',
      'network-disable-enable',
      'provider-cleanup'
    )
  } elseif ($Phase -eq 'offline-sync') {
    @(
      'airplane-enable-restore',
      'latency-enable-restore',
      'packet-loss-enable-restore',
      'api-unreachable-enable-restore',
      'wifi-disable-enable',
      'process-recreation',
      'stale-session',
      'stale-permission',
      'duplicate-delivery',
      'server-conflict',
      'database-corruption-quarantine'
    )
  } else { @() }
  readinessChecks = @('windows-healthz', 'emulator-healthz')
  failureArtifacts = $failureArtifactNames
  faultProxy = if ($Phase -eq 'offline-sync') {
    [pscustomobject][ordered]@{
      listenPort = $FaultProxyPort
      upstreamPort = $BackendPort
      ownership = 'start-and-stop-exact-owned-process'
      controlPath = '/__rims_m11'
    }
  } else { $null }
  processStages = if ($Phase -eq 'offline-sync') {
    @('seed', 'offline-draft', 'recovery')
  } else { @() }
  cleanup = [pscustomobject][ordered]@{
    preExistingDevice = 'preserve'
    controllerStartedDevice = 'stop-only-on-pid-and-start-time-match'
    hostBridge = 'stop-only-on-pid-and-start-time-match'
    adbNetworkState = if ($Phase -eq 'offline-sync') {
      'restore-in-finally'
    } else { 'not-applicable' }
  }
}

if ($ListPlan) {
  if ($Output -eq 'Json') {
    Write-Output ($plan | ConvertTo-Json -Depth 6 -Compress)
  } else {
    $plan.command -join ' '
  }
  exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$appRoot = Join-Path $repoRoot 'rims_frontend'
$localScript = Join-Path $scriptDir 'rims_local.ps1'
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'
. $commonScript

$runtimePaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
$logRoot = $runtimePaths.logs
$reportRoot = Join-Path $runtimePaths.root 'reports'
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $reportRoot 'latest-android-smoke.json'
}
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $runToken = "$([DateTimeOffset]::Now.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N'))"
  $ArtifactRoot = Join-Path `
    $runtimePaths.root `
    "android-smoke-artifacts\$runToken"
}
New-Item -ItemType Directory -Force -Path $logRoot, $reportRoot | Out-Null

$gitCommonDir = (& git -C $repoRoot rev-parse --git-common-dir).Trim()
if (-not [IO.Path]::IsPathRooted($gitCommonDir)) {
  $gitCommonDir = [IO.Path]::GetFullPath((Join-Path $repoRoot $gitCommonDir))
}
$frontendRepository = Split-Path -Parent $gitCommonDir
if ([string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
  $BackendWorkspaceRoot = Join-Path (Split-Path -Parent $frontendRepository) 'RIMS'
}
if ([string]::IsNullOrWhiteSpace($BackendDir)) {
  $frontendBranch = (& git -C $repoRoot branch --show-current).Trim()
  $backendCandidates = @(Get-ChildItem `
      -LiteralPath (Join-Path $frontendRepository '.worktrees') `
      -Directory `
      -ErrorAction SilentlyContinue | ForEach-Object {
        Join-Path $_.FullName 'rims-goProgect'
      } | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'scripts\m9_dev_seed.sh')
      })
  $matchingCandidate = @($backendCandidates | Where-Object {
      (& git -C $_ branch --show-current 2>$null).Trim() -eq $frontendBranch
    } | Select-Object -First 1)
  $BackendDir = if ($matchingCandidate.Count -gt 0) {
    $matchingCandidate[0]
  } else { Join-Path $BackendWorkspaceRoot 'rims-goProgect' }
}

$steps = [Collections.Generic.List[object]]::new()
$firstExitCode = 0
$failedStep = $null
$startedAt = [DateTimeOffset]::Now
$androidSerial = $null
$emulatorOwned = $false
$emulatorOwnedByRun = $false
$emulatorIdentity = $null
$fixtureCounts = $null
$e2eData = $null
$runtimeOwnedByRun = $false
$runtimeDisposition = 'unknown'
$fixturesMutated = $false
$hostBridgeProcess = $null
$hostBridgeIdentity = $null
$fieldPermissionHelper = $null
$fieldPermissionHelperPath = Join-Path $ArtifactRoot 'grant-camera-after-launch.ps1'
$flutterOutputPath = Join-Path $ArtifactRoot 'flutter-output.log'
$uploadProviderLogPath = Join-Path $ArtifactRoot 'upload-provider.log'
$faultProxyLogPath = Join-Path $ArtifactRoot 'fault-proxy.log'
$databaseEvidencePath = Join-Path $ArtifactRoot 'offline-database-evidence.log'
$faultProxyHelperPath = Join-Path $ArtifactRoot 'm11-fault-proxy.ps1'
$failureArtifacts = [pscustomobject][ordered]@{
  deviceScreenshot = $null
  filteredLogcat = $null
  backendLogTails = $null
  flutterOutput = $flutterOutputPath
}
if ($Phase -eq 'field-operations') {
  $failureArtifacts | Add-Member `
    -MemberType NoteProperty `
    -Name uploadProviderLog `
    -Value $uploadProviderLogPath
}
if ($Phase -eq 'offline-sync') {
  $failureArtifacts | Add-Member -MemberType NoteProperty -Name faultProxyLog -Value $faultProxyLogPath
  $failureArtifacts | Add-Member -MemberType NoteProperty -Name databaseEvidence -Value $databaseEvidencePath
}
$baselineRestore = [pscustomobject][ordered]@{
  attempted = $false
  ok = $false
  error = ''
}
$hostBridgeCleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}
$artifactCollection = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}
$faultProxyProcess = $null
$faultProxyIdentity = $null
$m11Commands = [Collections.Generic.List[string]]::new()
$initialAirplaneMode = $null
$initialWifiEnabled = $null
$adbStateRestore = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}
$faultProxyCleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}
$faultControl = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}

function Throw-AndroidChildFailure {
  param([string]$Message, [int]$ExitCode)
  $exception = [InvalidOperationException]::new($Message)
  $exception.Data['ExitCode'] = $ExitCode
  throw $exception
}

function Invoke-AndroidStep {
  param([string]$Name, [scriptblock]$Action)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $exitCode = 0
  $detail = ''
  try {
    if ($TestMode -and $Name -eq $FailStep) {
      $exitCode = 23
      $detail = 'Injected Android smoke failure.'
    } elseif (-not $TestMode) {
      & $Action
    }
  } catch {
    $exitCode = if ($_.Exception.Data.Contains('ExitCode')) {
      [int]$_.Exception.Data['ExitCode']
    } else { 1 }
    $detail = $_.Exception.Message
  } finally {
    $watch.Stop()
  }
  $ok = $exitCode -eq 0
  $script:steps.Add([pscustomobject][ordered]@{
      name = $Name
      ok = $ok
      exitCode = $exitCode
      durationMs = $watch.ElapsedMilliseconds
      detail = $detail
    })
  if (-not $ok -and $script:firstExitCode -eq 0) {
    $script:firstExitCode = $exitCode
    $script:failedStep = $Name
  }
}

function Invoke-LocalRuntime {
  param([string[]]$Arguments, [int]$TimeoutSeconds = 360)
  $execution = Invoke-RimsExternalCommand `
    -FilePath 'powershell.exe' `
    -Arguments (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localScript
      ) + $Arguments) `
    -TimeoutSeconds $TimeoutSeconds
  if ($execution.ExitCode -ne 0) {
    Throw-AndroidChildFailure `
      -Message "rims_local failed: $(Get-RimsExternalCommandSummary -Result $execution)" `
      -ExitCode $execution.ExitCode
  }
  return $execution
}

function Invoke-WslBackendCommand {
  param([string]$Command, [string[]]$CommandArguments = @())
  $execution = Invoke-RimsExternalCommand `
    -FilePath 'wsl.exe' `
    -Arguments (@(
        '--cd', $BackendDir, 'bash', '-lc', $Command, 'rims-android-smoke'
      ) + $CommandArguments) `
    -TimeoutSeconds 600
  if ($execution.ExitCode -ne 0) {
    Throw-AndroidChildFailure `
      -Message "Backend command failed: $(Get-RimsExternalCommandSummary -Result $execution)" `
      -ExitCode $execution.ExitCode
  }
  return $execution
}

function Get-CurrentAndroidRuntime {
  $state = Read-RimsRuntimeState -Paths $runtimePaths
  if ($null -eq $state -or $null -eq $state.emulator) {
    throw 'Managed Android startup did not persist emulator state.'
  }
  $script:androidSerial = [string]$state.emulator.serial
  $script:emulatorOwned = [bool]$state.emulator.owned
  $script:emulatorIdentity = [pscustomobject][ordered]@{
    avdName = [string]$state.emulator.avdName
    serial = $script:androidSerial
    owned = $script:emulatorOwnedByRun
    windowsPid = $state.emulator.windowsPid
    windowsProcessStartTimeUtc = $state.emulator.windowsProcessStartTimeUtc
  }
  if ([string]::IsNullOrWhiteSpace($script:androidSerial)) {
    throw 'Managed Android startup did not resolve an explicit adb serial.'
  }
}

function Invoke-Adb {
  param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  return Invoke-RimsExternalCommand `
    -FilePath $adb `
    -Arguments $Arguments `
    -TimeoutSeconds $TimeoutSeconds
}

function Resolve-RimsAndroidSmokeRuntimeDisposition {
  param(
    [bool]$StateExists,
    [bool]$RequestMatches,
    [bool]$Healthy
  )
  if (-not $StateExists) { return 'start' }
  if ($RequestMatches -and $Healthy) { return 'reuse' }
  return 'reject'
}

function Get-TestRuntimeDisposition {
  $state = if ($TestPreExistingRuntime) { 'healthy-pre-existing' } else { $TestRuntimeState }
  return Resolve-RimsAndroidSmokeRuntimeDisposition `
    -StateExists:($state -ne 'stopped') `
    -RequestMatches:($state -eq 'healthy-pre-existing') `
    -Healthy:($state -eq 'healthy-pre-existing')
}

function ConvertFrom-RimsStrictE2eMarker {
  param(
    [Parameter(Mandatory = $true)][string]$OutputText,
    [Parameter(Mandatory = $true)][ValidateSet('Result', 'Stage')]
    [string]$ExpectedMarker
  )
  $marker = if ($ExpectedMarker -eq 'Result') {
    'RIMS_E2E_RESULT'
  } else { 'RIMS_E2E_STAGE' }
  $markerLines = @($OutputText -split '\r?\n' | Where-Object {
      $_ -match "^\s*$marker(?:\s|$)"
    })
  if ($markerLines.Count -ne 1) {
    throw "Expected exactly one $marker marker, found $($markerLines.Count)."
  }
  $line = [string]$markerLines[0]
  if ($line -notmatch "^\s*$marker\s+(?<json>\{.*\})\s*$") {
    throw "$marker marker must contain exactly one JSON object."
  }
  try {
    $decoded = $Matches.json | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$marker marker contains invalid JSON."
  }
  if ($null -eq $decoded -or $decoded -is [Array] -or
      $decoded -is [string] -or $decoded -is [ValueType] -or
      @($decoded.PSObject.Properties).Count -eq 0) {
    throw "$marker payload must be a non-empty JSON object."
  }
  return $decoded
}

if ($TestMode -and -not [string]::IsNullOrWhiteSpace($TestMarkerFixturePath)) {
  try {
    $fixtureText = Get-Content -LiteralPath $TestMarkerFixturePath -Raw
    $parsedMarker = ConvertFrom-RimsStrictE2eMarker `
      -OutputText $fixtureText `
      -ExpectedMarker $TestExpectedMarker
    Write-Output ($parsedMarker | ConvertTo-Json -Depth 20 -Compress)
    exit 0
  } catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
  }
}

function Add-M11Command {
  param([string]$Name)
  if ($Phase -eq 'offline-sync') { [void]$script:m11Commands.Add($Name) }
}

function Get-M11AdbText {
  param([string[]]$Arguments)
  $result = Invoke-Adb -Arguments (@('-s', $androidSerial) + $Arguments)
  if ($result.ExitCode -ne 0) {
    throw "ADB state command failed: $($Arguments -join ' ') $($result.StandardError)"
  }
  return ([string]$result.StandardOutput).Trim()
}

function Start-M11FaultProxy {
  if ($Phase -ne 'offline-sync') { return }
  Add-M11Command 'snapshot-airplane-mode'
  Add-M11Command 'snapshot-wifi'
  if ($TestMode) {
    $script:initialAirplaneMode = '0'
    $script:initialWifiEnabled = $true
    $script:faultProxyIdentity = [pscustomobject][ordered]@{
      owned = $true
      windowsPid = 4343
      windowsProcessStartTimeUtc = '2026-07-14T00:00:00Z'
      listenAddress = '127.0.0.1'
      listenPort = $FaultProxyPort
      upstreamPort = $BackendPort
      controlPath = '/__rims_m11'
    }
    Add-M11Command "start-owned-fault-proxy:$FaultProxyPort"
    if ($TestAdbFailure -ne 'none') {
      $script:faultControl.attempted = $true
      $script:faultControl.ok = $false
      $script:faultControl.error = if ($TestAdbFailure -eq 'nonzero') {
        'Injected ADB exit 17 with stderr.'
      } else { 'Injected ADB executor exception.' }
      Add-M11Command 'control-airplane-mode:false'
      Throw-AndroidChildFailure `
        -Message $script:faultControl.error `
        -ExitCode $(if ($TestAdbFailure -eq 'nonzero') { 31 } else { 32 })
    }
    return
  }
  $script:initialAirplaneMode = Get-M11AdbText @(
    'shell', 'settings', 'get', 'global', 'airplane_mode_on'
  )
  $wifiStatus = Get-M11AdbText @('shell', 'cmd', 'wifi', 'status')
  $script:initialWifiEnabled = $wifiStatus -match '(?i)enabled'
  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class RimsM11FaultProxy {
  static readonly object Gate = new object();
  static string mode = "normal";
  static int delayMs = 0;
  static string adb;
  static string serial;
  static string logPath;
  static int upstreamPort;
  static int networkGeneration = 0;
  static int activeNetworkActions = 0;

  public static void Run(int listenPort, int backendPort, string adbPath,
      string deviceSerial, string outputPath) {
    upstreamPort = backendPort;
    adb = adbPath;
    serial = deviceSerial;
    logPath = outputPath;
    Log("proxy-start listen=" + listenPort + " upstream=" + backendPort);
    var listener = new TcpListener(IPAddress.Loopback, listenPort);
    listener.Start();
    while (true) {
      var client = listener.AcceptTcpClient();
      Task.Run(() => Handle(client));
    }
  }

  static void Handle(TcpClient client) {
    using (client) {
      try {
        var request = ReadRequest(client.GetStream());
        if (request == null) return;
        var header = Encoding.ASCII.GetString(request, 0,
          FindHeaderEnd(request) + 4);
        var firstLine = header.Split(new[] { "\r\n" },
          StringSplitOptions.None)[0];
        var parts = firstLine.Split(' ');
        var path = parts.Length > 1 ? parts[1] : "/";
        if (path.StartsWith("/__rims_m11", StringComparison.Ordinal)) {
          HandleControl(client.GetStream(), path);
          return;
        }
        string active;
        int activeDelay;
        lock (Gate) {
          active = mode;
          activeDelay = delayMs;
          if (active.EndsWith("-next", StringComparison.Ordinal)) mode = "normal";
        }
        if (activeDelay > 0) Thread.Sleep(activeDelay);
        Log("request mode=" + active + " path=" + path);
        if (active == "packet-loss-next") return;
        if (active == "unreachable") {
          WriteJson(client.GetStream(), 503, "Service Unavailable",
            "{\"ok\":false,\"fault\":\"unreachable\"}");
          return;
        }
        if (active == "stale-session-next") {
          WriteJson(client.GetStream(), 401, "Unauthorized",
            "{\"code\":\"AUTHENTICATION_REQUIRED\",\"message\":\"Injected stale session\"}");
          return;
        }
        if (active == "stale-permission-next") {
          WriteJson(client.GetStream(), 403, "Forbidden",
            "{\"code\":\"PERMISSION_DENIED\",\"message\":\"Injected stale permission\"}");
          return;
        }
        if (active == "server-conflict-next") {
          WriteJson(client.GetStream(), 409, "Conflict",
            "{\"code\":\"CONFLICT\",\"message\":\"Injected server conflict\"}");
          return;
        }
        if (active == "unknown-response-next") {
          Forward(request, null);
          return;
        }
        Forward(request, client.GetStream());
        if (active == "duplicate-delivery-next") Forward(request, null);
      } catch (Exception error) {
        Log("proxy-error " + error.GetType().Name + " " + error.Message);
      }
    }
  }

  static void HandleControl(NetworkStream stream, string path) {
    var action = Query(path, "action") ?? "status";
    Log("control action=" + action);
    var waitForNetworkActions = false;
    lock (Gate) {
      switch (action) {
        case "reset":
          mode = "normal";
          delayMs = 0;
          networkGeneration++;
          waitForNetworkActions = true;
          break;
        case "latency": delayMs = ParseInt(Query(path, "delayMs"), 750); break;
        case "latency-off": delayMs = 0; break;
        case "packet-loss": mode = "packet-loss-next"; break;
        case "unreachable": mode = "unreachable"; break;
        case "unreachable-off": mode = "normal"; break;
        case "stale-session": mode = "stale-session-next"; break;
        case "stale-permission": mode = "stale-permission-next"; break;
        case "unknown-response": mode = "unknown-response-next"; break;
        case "duplicate-delivery": mode = "duplicate-delivery-next"; break;
        case "server-conflict": mode = "server-conflict-next"; break;
      }
    }
    try {
      if (waitForNetworkActions) WaitForNetworkActions();
      if (action == "airplane-mode") {
        StartNetworkAction(
          "shell cmd connectivity airplane-mode enable",
          "shell cmd connectivity airplane-mode disable",
          ParseInt(Query(path, "restoreMs"), 3000));
      } else if (action == "wifi-switch") {
        StartNetworkAction(
          "shell svc wifi disable",
          "shell svc wifi enable",
          ParseInt(Query(path, "restoreMs"), 1500));
      }
      string current;
      int currentDelay;
      lock (Gate) { current = mode; currentDelay = delayMs; }
      WriteJson(stream, 200, "OK", "{\"ok\":true,\"mode\":\"" +
        current + "\",\"delayMs\":" + currentDelay + "}");
    } catch (Exception error) {
      Log("control-adb-error " + error.GetType().Name + " " + error.Message);
      WriteJson(stream, 500, "ADB Failure", "{\"ok\":false,\"error\":\"adb-command-failed\"}");
    }
  }

  static void Forward(byte[] request, NetworkStream destination) {
    using (var upstream = ConnectUpstream()) {
      var stream = upstream.GetStream();
      var normalized = ForceConnectionClose(request);
      stream.Write(normalized, 0, normalized.Length);
      var buffer = new byte[32768];
      int read;
      while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) {
        if (destination != null) destination.Write(buffer, 0, read);
      }
    }
  }

  static TcpClient ConnectUpstream() {
    try {
      var ipv4 = new TcpClient(AddressFamily.InterNetwork);
      ipv4.Connect(IPAddress.Loopback, upstreamPort);
      return ipv4;
    } catch {
      var ipv6 = new TcpClient(AddressFamily.InterNetworkV6);
      ipv6.Connect(IPAddress.IPv6Loopback, upstreamPort);
      return ipv6;
    }
  }

  static byte[] ReadRequest(NetworkStream stream) {
    var data = new List<byte>();
    var one = new byte[1];
    while (FindHeaderEnd(data.ToArray()) < 0) {
      if (stream.Read(one, 0, 1) == 0) return null;
      data.Add(one[0]);
      if (data.Count > 1024 * 1024) throw new InvalidDataException("header too large");
    }
    var bytes = data.ToArray();
    var headerEnd = FindHeaderEnd(bytes);
    var header = Encoding.ASCII.GetString(bytes, 0, headerEnd + 4);
    var contentLength = 0;
    foreach (var line in header.Split(new[] { "\r\n" }, StringSplitOptions.None)) {
      if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
        int.TryParse(line.Substring(line.IndexOf(':') + 1).Trim(), out contentLength);
    }
    while (data.Count < headerEnd + 4 + contentLength) {
      var buffer = new byte[Math.Min(32768, headerEnd + 4 + contentLength - data.Count)];
      var read = stream.Read(buffer, 0, buffer.Length);
      if (read == 0) break;
      for (var i = 0; i < read; i++) data.Add(buffer[i]);
    }
    return data.ToArray();
  }

  static int FindHeaderEnd(byte[] data) {
    for (var i = 0; i + 3 < data.Length; i++)
      if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) return i;
    return -1;
  }

  static byte[] ForceConnectionClose(byte[] request) {
    var end = FindHeaderEnd(request);
    var header = Encoding.ASCII.GetString(request, 0, end);
    var lines = new List<string>();
    foreach (var line in header.Split(new[] { "\r\n" }, StringSplitOptions.None))
      if (!line.StartsWith("Connection:", StringComparison.OrdinalIgnoreCase)) lines.Add(line);
    lines.Add("Connection: close");
    var replaced = Encoding.ASCII.GetBytes(string.Join("\r\n", lines) + "\r\n\r\n");
    var result = new byte[replaced.Length + request.Length - end - 4];
    Buffer.BlockCopy(replaced, 0, result, 0, replaced.Length);
    Buffer.BlockCopy(request, end + 4, result, replaced.Length, request.Length - end - 4);
    return result;
  }

  static void WriteJson(NetworkStream stream, int status, string label, string json) {
    var body = Encoding.UTF8.GetBytes(json);
    var header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " " + label +
      "\r\nContent-Type: application/json\r\nContent-Length: " + body.Length +
      "\r\nConnection: close\r\n\r\n");
    stream.Write(header, 0, header.Length);
    stream.Write(body, 0, body.Length);
  }

  static string Query(string path, string name) {
    var index = path.IndexOf('?');
    if (index < 0) return null;
    foreach (var pair in path.Substring(index + 1).Split('&')) {
      var bits = pair.Split(new[] { '=' }, 2);
      if (Uri.UnescapeDataString(bits[0]) == name)
        return bits.Length > 1 ? Uri.UnescapeDataString(bits[1]) : "";
    }
    return null;
  }

  static int ParseInt(string value, int fallback) {
    int parsed;
    return int.TryParse(value, out parsed) ? parsed : fallback;
  }

  static void StartNetworkAction(
      string faultArguments, string restoreArguments, int restoreMs) {
    RunAdb(faultArguments);
    int generation;
    lock (Gate) {
      generation = ++networkGeneration;
      activeNetworkActions++;
    }
    Task.Run(async () => {
      try {
        if (!await DelayWhileCurrent(generation, restoreMs)) return;
        RunAdb(restoreArguments);
      } catch (Exception error) {
        Log("adb-restore-error " + error.GetType().Name + " " + error.Message);
      } finally {
        lock (Gate) activeNetworkActions--;
      }
    });
  }

  static async Task<bool> DelayWhileCurrent(int generation, int milliseconds) {
    var remaining = Math.Max(0, milliseconds);
    while (remaining > 0) {
      var delay = Math.Min(25, remaining);
      await Task.Delay(delay);
      remaining -= delay;
      lock (Gate) if (generation != networkGeneration) return false;
    }
    lock (Gate) return generation == networkGeneration;
  }

  static void WaitForNetworkActions() {
    var deadline = DateTime.UtcNow.AddSeconds(10);
    while (DateTime.UtcNow < deadline) {
      lock (Gate) if (activeNetworkActions == 0) return;
      Thread.Sleep(25);
    }
    throw new TimeoutException("network fault action did not stop after reset");
  }

  static void RunAdb(string arguments) {
    var info = new ProcessStartInfo(adb, "-s \"" + serial + "\" " + arguments) {
      UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardOutput = true, RedirectStandardError = true
    };
    using (var process = Process.Start(info)) {
      if (process == null) throw new InvalidOperationException("adb process did not start");
      var stdoutTask = process.StandardOutput.ReadToEndAsync();
      var stderrTask = process.StandardError.ReadToEndAsync();
      if (!process.WaitForExit(30000)) {
        process.Kill();
        process.WaitForExit();
        throw new TimeoutException("adb network command timed out");
      }
      var stdout = stdoutTask.Result.Trim();
      var stderr = stderrTask.Result.Trim();
      Log("adb exit=" + process.ExitCode + " args=" + arguments);
      if (process.ExitCode != 0) {
        throw new InvalidOperationException("adb network command failed exit=" +
          process.ExitCode + " stdout=" + stdout + " stderr=" + stderr);
      }
    }
  }

  static void Log(string line) {
    lock (Gate) File.AppendAllText(logPath,
      DateTimeOffset.UtcNow.ToString("o") + " " + line + Environment.NewLine);
  }
}
'@
  $helper = @"
param([int]`$ListenPort, [int]`$BackendPort, [string]`$Adb, [string]`$Serial, [string]`$LogPath)
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
$source
'@
[RimsM11FaultProxy]::Run(`$ListenPort, `$BackendPort, `$Adb, `$Serial, `$LogPath)
"@
  New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
  Set-Content -LiteralPath $faultProxyHelperPath -Value $helper -Encoding UTF8
  $helperArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $faultProxyHelperPath,
    '-ListenPort', "$FaultProxyPort", '-BackendPort', "$BackendPort",
    '-Adb', $adb, '-Serial', $androidSerial, '-LogPath', $faultProxyLogPath
  ) | ForEach-Object { ConvertTo-RimsWindowsCommandLineArgument -Value "$_" }
  $script:faultProxyProcess = Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList ($helperArguments -join ' ') `
    -WindowStyle Hidden `
    -PassThru
  $script:faultProxyIdentity = [pscustomobject][ordered]@{
    owned = $true
    windowsPid = $script:faultProxyProcess.Id
    windowsProcessStartTimeUtc = $script:faultProxyProcess.StartTime.ToUniversalTime().ToString('o')
    listenAddress = '127.0.0.1'
    listenPort = $FaultProxyPort
    upstreamPort = $BackendPort
    controlPath = '/__rims_m11'
  }
  Add-M11Command "start-owned-fault-proxy:$FaultProxyPort"
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do {
    if ($script:faultProxyProcess.HasExited) {
      throw 'M11 fault proxy exited before becoming ready.'
    }
    try {
      $status = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$FaultProxyPort/__rims_m11?action=status" `
        -TimeoutSec 2
      if ($status.ok -eq $true) { return }
    } catch { }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'M11 fault proxy did not become ready.'
}

function Restore-M11FaultHarness {
  if ($Phase -ne 'offline-sync') { return }
  $script:adbStateRestore.attempted = $true
  $restoreErrors = [Collections.Generic.List[string]]::new()
  Add-M11Command 'reset-fault-proxy'
  Add-M11Command 'restore-airplane-mode'
  Add-M11Command 'restore-wifi'
  Add-M11Command 'stop-owned-fault-proxy'
  if (-not $TestMode -and $null -ne $faultProxyIdentity) {
    try {
      [void](Invoke-RestMethod `
          -Uri "http://127.0.0.1:$FaultProxyPort/__rims_m11?action=reset" `
          -TimeoutSec 12)
    } catch { [void]$restoreErrors.Add("proxy reset: $($_.Exception.Message)") }
    try {
      $airplaneAction = if ($initialAirplaneMode -eq '1') { 'enable' } else { 'disable' }
      [void](Get-M11AdbText @('shell', 'cmd', 'connectivity', 'airplane-mode', $airplaneAction))
    } catch { [void]$restoreErrors.Add("airplane mode: $($_.Exception.Message)") }
    try {
      $wifiAction = if ($initialWifiEnabled) { 'enable' } else { 'disable' }
      [void](Get-M11AdbText @('shell', 'svc', 'wifi', $wifiAction))
    } catch { [void]$restoreErrors.Add("wifi: $($_.Exception.Message)") }
  }
  $script:faultProxyCleanup.attempted = $true
  if (-not $TestMode -and $null -ne $faultProxyProcess) {
    try {
      $process = Get-Process -Id $faultProxyIdentity.windowsPid -ErrorAction SilentlyContinue
      if ($null -ne $process) {
        $actualStart = $process.StartTime.ToUniversalTime().ToString('o')
        if ($actualStart -ne $faultProxyIdentity.windowsProcessStartTimeUtc) {
          throw 'M11 fault proxy PID was reused; cleanup refused.'
        }
        if (-not $process.HasExited) {
          $process.Kill()
          if (-not $process.WaitForExit(5000)) { throw 'M11 fault proxy did not stop.' }
        }
      }
    } catch { [void]$restoreErrors.Add("proxy stop: $($_.Exception.Message)") }
    $faultProxyProcess.Dispose()
    $script:faultProxyProcess = $null
  }
  Remove-Item -LiteralPath $faultProxyHelperPath -Force -ErrorAction SilentlyContinue
  $script:adbStateRestore.ok = $restoreErrors.Count -eq 0
  $script:adbStateRestore.error = $restoreErrors -join '; '
  $script:faultProxyCleanup.ok = $restoreErrors.Count -eq 0
  $script:faultProxyCleanup.error = $restoreErrors -join '; '
  if ($restoreErrors.Count -gt 0 -and $script:firstExitCode -eq 0) {
    $script:firstExitCode = 1
    $script:failedStep = 'baseline-restore'
  }
}

function Invoke-AndroidFlutterTest {
  $flutter = Resolve-RimsCommandPath -Name 'flutter'
  if ([string]::IsNullOrWhiteSpace($flutter)) {
    throw 'flutter was not found on PATH.'
  }
  $flutterArguments = @(
    'test', '--no-pub'
  ) + $offlineRunnerArguments + @(
    $integrationTestPath,
    '-d', $androidSerial,
    "--dart-define=API_BASE_URL=$apiBaseUrl"
  ) + $fieldDefines + $offlineDefines
  $flutterCommand = (@($flutter) + $flutterArguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value "$_"
    }) -join ' '
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $env:ComSpec
  $startInfo.Arguments = '/d /c ' + $flutterCommand
  $startInfo.WorkingDirectory = $appRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    [void]$process.Start()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $deviceProcessId = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(1200)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
      if ($Phase -eq 'offline-sync' -and $null -eq $deviceProcessId) {
        $pidResult = Invoke-Adb `
          -Arguments @('-s', $androidSerial, 'shell', 'pidof', 'com.example.rims_frontend') `
          -TimeoutSeconds 5
        $pidText = ([string]$pidResult.StandardOutput).Trim()
        if ($pidResult.ExitCode -eq 0 -and $pidText -match '^\d+$') {
          $deviceProcessId = [int64]$pidText
        }
      }
      [void]$process.WaitForExit(100)
    }
    $timedOut = -not $process.HasExited
    if ($timedOut) {
      Stop-RimsProcessTree -Process $process
    }
    $standardOutput = Receive-RimsAsyncText `
      -Task $outputTask `
      -TimeoutMilliseconds 3000
    $standardError = Receive-RimsAsyncText `
      -Task $errorTask `
      -TimeoutMilliseconds 3000
    $exitCode = if ($timedOut) {
      124
    } elseif ($process.HasExited) {
      $process.ExitCode
    } else { -1 }
    return [pscustomobject][ordered]@{
      ExitCode = $exitCode
      TimedOut = $timedOut
      ProcessId = $process.Id
      DeviceProcessId = $deviceProcessId
      StandardOutput = $standardOutput
      StandardError = $standardError
    }
  } finally {
    $process.Dispose()
  }
}


function Stop-M11StageProcess {
  param([string]$Stage)
  Add-M11Command "force-stop:$Stage"
  [void](Get-M11AdbText @('shell', 'am', 'force-stop', 'com.example.rims_frontend'))
  Add-M11Command "confirm-stopped:$Stage"
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    $pidResult = Invoke-Adb `
      -Arguments @('-s', $androidSerial, 'shell', 'pidof', 'com.example.rims_frontend') `
      -TimeoutSeconds 5
    $pidText = ([string]$pidResult.StandardOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($pidText)) { return }
    if ($pidResult.ExitCode -ne 0) {
      throw "ADB pid confirmation failed for stage '$Stage': $($pidResult.StandardError)"
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Android app process remained alive after force-stop for stage '$Stage'."
}

function Invoke-M11ProcessStages {
  $stageNames = @('seed', 'offline-draft', 'recovery')
  Add-M11Command 'prepare-clean-app-data'
  if ($TestMode) {
    foreach ($stage in $stageNames) {
      Add-M11Command "run-stage:$stage"
      Add-M11Command "capture-pid:$stage"
      Add-M11Command "force-stop:$stage"
      Add-M11Command "confirm-stopped:$stage"
    }
    return
  }

  $packagePath = Invoke-Adb `
    -Arguments @('-s', $androidSerial, 'shell', 'pm', 'path', 'com.example.rims_frontend')
  if ($packagePath.ExitCode -eq 0 -and
      -not [string]::IsNullOrWhiteSpace([string]$packagePath.StandardOutput)) {
    $clearResult = Invoke-Adb `
      -Arguments @('-s', $androidSerial, 'shell', 'pm', 'clear', 'com.example.rims_frontend')
    if ($clearResult.ExitCode -ne 0 -or
        ([string]$clearResult.StandardOutput).Trim() -ne 'Success') {
      throw "Failed to clear prior M11 app data: $($clearResult.StandardError)"
    }
  }

  $processStages = [Collections.Generic.List[object]]::new()
  foreach ($stage in $stageNames) {
    Add-M11Command "run-stage:$stage"
    $stageStartedAt = [DateTimeOffset]::UtcNow
    $stageFailure = $null
    try {
      $execution = Invoke-AndroidFlutterTest
      @(
        "===== stage $stage stdout =====",
        $execution.StandardOutput,
        "===== stage $stage stderr =====",
        $execution.StandardError
      ) | Add-Content -LiteralPath $flutterOutputPath -Encoding UTF8
      if ($execution.ExitCode -ne 0) {
        Throw-AndroidChildFailure `
          -Message "Android M11 stage '$stage' failed: $(Get-RimsExternalCommandSummary -Result $execution)" `
          -ExitCode $execution.ExitCode
      }
      Add-M11Command "capture-pid:$stage"
      if ($null -eq $execution.DeviceProcessId) {
        throw "M11 stage '$stage' had no observable app process while Flutter was running."
      }
      $devicePid = [int64]$execution.DeviceProcessId
      if ($stage -ne 'recovery') {
        $marker = ConvertFrom-RimsStrictE2eMarker `
          -OutputText ([string]$execution.StandardOutput) `
          -ExpectedMarker Stage
        if ([string]$marker.stage -ne $stage -or [int64]$marker.processId -ne $devicePid) {
          throw "M11 stage marker identity mismatch for '$stage'."
        }
      } else {
        $script:e2eData = ConvertFrom-RimsStrictE2eMarker `
          -OutputText ([string]$execution.StandardOutput) `
          -ExpectedMarker Result
      }
      [void]$processStages.Add([pscustomobject][ordered]@{
          stage = $stage
          processId = $devicePid
          startedAt = $stageStartedAt.ToString('o')
        })
    } catch {
      $stageFailure = $_
    } finally {
      try {
        Stop-M11StageProcess -Stage $stage
      } catch {
        if ($null -eq $stageFailure) { $stageFailure = $_ }
      }
    }
    if ($null -ne $stageFailure) { throw $stageFailure }
  }
  if ($null -eq $script:e2eData) { throw 'M11 recovery stage omitted result evidence.' }
  $script:e2eData | Add-Member `
    -MemberType NoteProperty `
    -Name processStages `
    -Value @($processStages) `
    -Force
}


function Test-WindowsHealthzOnce {
  try {
    $health = Invoke-RestMethod `
      -Uri "http://127.0.0.1:$BackendPort/healthz" `
      -TimeoutSec 2
    return $null -ne $health
  } catch {
    return $false
  }
}

function Start-AndroidHostBridge {
  if (Test-WindowsHealthzOnce) { return }
  $source = @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
public static class RimsAndroidHostBridge {
  public static void Run(int port) {
    var listener = new TcpListener(IPAddress.Loopback, port);
    listener.Start();
    while (true) {
      var client = listener.AcceptTcpClient();
      Task.Run(() => Handle(client, port));
    }
  }
  private static async Task Handle(TcpClient client, int port) {
    using (client)
    using (var upstream = new TcpClient(AddressFamily.InterNetworkV6)) {
      await upstream.ConnectAsync(IPAddress.IPv6Loopback, port);
      var clientStream = client.GetStream();
      var upstreamStream = upstream.GetStream();
      await Task.WhenAny(
        clientStream.CopyToAsync(upstreamStream),
        upstreamStream.CopyToAsync(clientStream));
    }
  }
}
'@
  $launcher = "Add-Type -TypeDefinition @'`n$source`n'@; [RimsAndroidHostBridge]::Run($BackendPort)"
  $encoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($launcher)
  )
  $script:hostBridgeProcess = Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) `
    -WindowStyle Hidden `
    -PassThru
  $script:hostBridgeIdentity = [pscustomobject][ordered]@{
    owned = $true
    windowsPid = $script:hostBridgeProcess.Id
    windowsProcessStartTimeUtc = `
      $script:hostBridgeProcess.StartTime.ToUniversalTime().ToString('o')
    listenAddress = '127.0.0.1'
    listenPort = $BackendPort
    upstreamAddress = '::1'
    upstreamPort = $BackendPort
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    if ($script:hostBridgeProcess.HasExited) {
      throw 'Android host bridge exited before becoming ready.'
    }
    if (Test-WindowsHealthzOnce) { return }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Android host bridge did not expose IPv4 port $BackendPort."
}

function Stop-AndroidHostBridge {
  if ($null -eq $script:hostBridgeProcess) { return }
  $script:hostBridgeCleanup.attempted = $true
  try {
    $process = Get-Process `
      -Id $script:hostBridgeIdentity.windowsPid `
      -ErrorAction SilentlyContinue
    if ($null -eq $process) {
      $script:hostBridgeCleanup.ok = $true
      return
    }
    $actualStart = $process.StartTime.ToUniversalTime().ToString('o')
    if ($actualStart -ne $script:hostBridgeIdentity.windowsProcessStartTimeUtc) {
      throw 'Android host bridge PID was reused; cleanup refused.'
    }
    if (-not $process.HasExited) {
      $process.Kill()
      if (-not $process.WaitForExit(5000)) {
        throw 'Android host bridge did not exit within five seconds.'
      }
    }
    $script:hostBridgeCleanup.ok = $true
  } catch {
    $script:hostBridgeCleanup.ok = $false
    $script:hostBridgeCleanup.error = $_.Exception.Message
    throw
  }
}

function Test-EmulatorHealthz {
  [void](Invoke-Adb -Arguments @('-s', $androidSerial, 'shell', 'input', 'keyevent', '82'))
  $healthUrl = "http://10.0.2.2:$BackendPort/healthz"
  $commands = @(
    "curl -fsS '$healthUrl'",
    "toybox wget -q -O - '$healthUrl'",
    "(echo -e 'GET /healthz HTTP/1.0\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n'; sleep 2) | toybox nc -w 5 10.0.2.2 $BackendPort"
  )
  foreach ($command in $commands) {
    $execution = Invoke-Adb `
      -Arguments @('-s', $androidSerial, 'shell', $command) `
      -TimeoutSeconds 15
    $response = "$($execution.StandardOutput)`n$($execution.StandardError)"
    if ($execution.ExitCode -eq 0 -and $response -match '200|ok|healthy') {
      return
    }
  }
  throw "Emulator '$androidSerial' could not reach $healthUrl."
}

function Collect-AndroidFailureArtifacts {
  New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
  $screenshot = Join-Path $ArtifactRoot 'device-failure.png'
  $logcat = Join-Path $ArtifactRoot 'filtered-logcat.log'
  $backendTails = Join-Path $ArtifactRoot 'backend-log-tails.log'
  if ($TestMode) {
    Set-Content -LiteralPath $screenshot -Value 'test screenshot' -Encoding ASCII
    Set-Content -LiteralPath $logcat -Value 'test logcat' -Encoding UTF8
    Set-Content -LiteralPath $backendTails -Value 'test backend tails' -Encoding UTF8
    Set-Content -LiteralPath $flutterOutputPath -Value 'test flutter output' -Encoding UTF8
    if ($Phase -eq 'field-operations') {
      Set-Content `
        -LiteralPath $uploadProviderLogPath `
        -Value 'test upload provider' `
        -Encoding UTF8
    }
    if ($Phase -eq 'offline-sync') {
      Set-Content -LiteralPath $faultProxyLogPath -Value 'test fault proxy' -Encoding UTF8
      Set-Content -LiteralPath $databaseEvidencePath -Value 'test database evidence' -Encoding UTF8
    }
  } else {
    if (-not [string]::IsNullOrWhiteSpace($androidSerial)) {
      $remoteScreenshot = '/sdcard/rims-android-smoke-failure.png'
      $capture = Invoke-Adb `
        -Arguments @('-s', $androidSerial, 'shell', 'screencap', '-p', $remoteScreenshot)
      if ($capture.ExitCode -eq 0) {
        $pull = Invoke-Adb `
          -Arguments @('-s', $androidSerial, 'pull', $remoteScreenshot, $screenshot)
        [void](Invoke-Adb `
            -Arguments @('-s', $androidSerial, 'shell', 'rm', '-f', $remoteScreenshot))
        if ($pull.ExitCode -ne 0) {
          Set-Content -LiteralPath "$screenshot.capture-error.txt" `
            -Value $pull.StandardError `
            -Encoding UTF8
          $screenshot = "$screenshot.capture-error.txt"
        }
      }
      $logcatResult = Invoke-Adb `
        -Arguments @(
          '-s', $androidSerial, 'logcat', '-d', '-v', 'threadtime',
          '*:S', 'flutter:V', 'AndroidRuntime:E', 'ActivityManager:W'
        ) `
        -TimeoutSeconds 30
      @($logcatResult.StandardOutput, $logcatResult.StandardError) | Set-Content `
        -LiteralPath $logcat `
        -Encoding UTF8
    } else {
      $screenshot = Join-Path $ArtifactRoot 'device-screenshot-unavailable.txt'
      $logcat = Join-Path $ArtifactRoot 'filtered-logcat-unavailable.txt'
      Set-Content `
        -LiteralPath $screenshot `
        -Value 'No Android serial was resolved before failure.' `
        -Encoding UTF8
      Set-Content `
        -LiteralPath $logcat `
        -Value 'No Android serial was resolved before failure.' `
        -Encoding UTF8
    }
    $tailLines = [Collections.Generic.List[string]]::new()
    foreach ($name in @('backend.stdout.log', 'backend.stderr.log')) {
      $path = Join-Path $logRoot $name
      [void]$tailLines.Add("===== $name =====")
      if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path -Tail 80 | ForEach-Object {
          [void]$tailLines.Add([string]$_)
        }
      }
    }
    $tailLines | Set-Content -LiteralPath $backendTails -Encoding UTF8
    if ($Phase -eq 'field-operations') {
      @(
        'provider=compile-time deterministic selection',
        'cleanup=owned by integration process and baseline restore'
      ) | Add-Content -LiteralPath $uploadProviderLogPath -Encoding UTF8
    }
    if ($Phase -eq 'offline-sync') {
      if (-not (Test-Path -LiteralPath $faultProxyLogPath -PathType Leaf)) {
        Set-Content `
          -LiteralPath $faultProxyLogPath `
          -Value 'Fault proxy did not start before failure.' `
          -Encoding UTF8
      }
      Set-Content `
        -LiteralPath $databaseEvidencePath `
        -Value 'Database evidence is emitted by the M11 integration result.' `
        -Encoding UTF8
    }
  }
  if (-not (Test-Path -LiteralPath $screenshot -PathType Leaf)) {
    $screenshot = Join-Path $ArtifactRoot 'device-screenshot-unavailable.txt'
    Set-Content `
      -LiteralPath $screenshot `
      -Value 'The device screenshot could not be captured.' `
      -Encoding UTF8
  }
  if (-not (Test-Path -LiteralPath $logcat -PathType Leaf)) {
    $logcat = Join-Path $ArtifactRoot 'filtered-logcat-unavailable.txt'
    Set-Content `
      -LiteralPath $logcat `
      -Value 'Filtered logcat could not be captured.' `
      -Encoding UTF8
  }
  if (-not (Test-Path -LiteralPath $flutterOutputPath -PathType Leaf)) {
    $script:flutterOutputPath = Join-Path $ArtifactRoot 'flutter-output-not-started.txt'
    Set-Content `
      -LiteralPath $script:flutterOutputPath `
      -Value 'The Flutter integration test did not start before this failure.' `
      -Encoding UTF8
    $script:failureArtifacts.flutterOutput = $script:flutterOutputPath
  }
  $script:failureArtifacts.deviceScreenshot = $screenshot
  $script:failureArtifacts.filteredLogcat = $logcat
  $script:failureArtifacts.backendLogTails = $backendTails
}

function Invoke-FieldOperationsDeviceSetup {
  if ($Phase -ne 'field-operations') { return }
  $commands = [Collections.Generic.List[string[]]]::new()
  $commands.Add(@('shell', 'am', 'force-stop', 'com.example.rims_frontend'))
  $commands.Add(@(
      'shell', 'pm', 'revoke', 'com.example.rims_frontend',
      'android.permission.CAMERA'
    ))
  $commands.Add(@('shell', 'input', 'keyevent', 'HOME'))
  $commands.Add(@(
      'shell', 'pm', 'grant', 'com.example.rims_frontend',
      'android.permission.CAMERA'
    ))
  $commands.Add(@('shell', 'svc', 'wifi', 'disable'))
  $commands.Add(@('shell', 'svc', 'wifi', 'enable'))
  $lines = [Collections.Generic.List[string]]::new()
  foreach ($command in $commands) {
    $result = Invoke-Adb `
      -Arguments (@('-s', $androidSerial) + $command) `
      -TimeoutSeconds 30
    [void]$lines.Add(
      "$($command -join ' ') exit=$($result.ExitCode) $($result.StandardError)"
    )
  }
  $lines | Set-Content -LiteralPath $uploadProviderLogPath -Encoding UTF8
  Start-Sleep -Seconds 2
}

function Start-FieldPermissionGrantHelper {
  if ($Phase -ne 'field-operations') { return }
  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $source = @'
param([string]$Adb, [string]$Serial, [string]$LogPath)
$ErrorActionPreference = 'Continue'
for ($attempt = 0; $attempt -lt 240; $attempt += 1) {
  $pidText = (& $Adb -s $Serial shell 'pidof' 'com.example.rims_frontend' 2>&1) -join ' '
  if (-not [string]::IsNullOrWhiteSpace($pidText)) {
    Start-Sleep -Milliseconds 300
    $grant = (& $Adb -s $Serial shell pm grant com.example.rims_frontend android.permission.CAMERA 2>&1) -join ' '
    "post-install-camera-grant pid=$pidText exit=$LASTEXITCODE $grant" |
      Add-Content -LiteralPath $LogPath -Encoding UTF8
    $packageEvidence = (& $Adb -s $Serial shell dumpsys package com.example.rims_frontend 2>&1 |
        Select-String 'android.permission.CAMERA: granted=') -join ' '
    $cameraFeatures = (& $Adb -s $Serial shell pm list features 2>&1 |
        Select-String 'camera') -join ' '
    "camera-permission-evidence $packageEvidence" |
      Add-Content -LiteralPath $LogPath -Encoding UTF8
    "camera-feature-evidence $cameraFeatures" |
      Add-Content -LiteralPath $LogPath -Encoding UTF8
    exit $LASTEXITCODE
  }
  Start-Sleep -Milliseconds 250
}
'post-install-camera-grant timed out waiting for app process' |
  Add-Content -LiteralPath $LogPath -Encoding UTF8
exit 124
'@
  Set-Content `
    -LiteralPath $fieldPermissionHelperPath `
    -Value $source `
    -Encoding UTF8
  $helperArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    $fieldPermissionHelperPath, '-Adb', $adb, '-Serial', $androidSerial,
    '-LogPath', $uploadProviderLogPath
  ) | ForEach-Object {
    ConvertTo-RimsWindowsCommandLineArgument -Value "$_"
  }
  $script:fieldPermissionHelper = Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList ($helperArguments -join ' ') `
    -WindowStyle Hidden `
    -PassThru
}

function Stop-FieldPermissionGrantHelper {
  if ($null -ne $script:fieldPermissionHelper -and
      -not $script:fieldPermissionHelper.HasExited) {
    $script:fieldPermissionHelper.Kill()
    [void]$script:fieldPermissionHelper.WaitForExit(5000)
  }
  if ($null -ne $script:fieldPermissionHelper) {
    $script:fieldPermissionHelper.Dispose()
    $script:fieldPermissionHelper = $null
  }
  Remove-Item `
    -LiteralPath $fieldPermissionHelperPath `
    -Force `
    -ErrorAction SilentlyContinue
}

function Remove-FieldOperationsProvider {
  if ($Phase -ne 'field-operations' -or
      [string]::IsNullOrWhiteSpace($androidSerial)) {
    return
  }
  $result = Invoke-Adb `
    -Arguments @(
      '-s', $androidSerial, 'shell', 'run-as', 'com.example.rims_frontend',
      'rm', '-rf', 'cache/.rims-e2e-provider'
    ) `
    -TimeoutSeconds 30
  Add-Content `
    -LiteralPath $uploadProviderLogPath `
    -Value "provider-cleanup exit=$($result.ExitCode) $($result.StandardError)" `
    -Encoding UTF8
}

function Invoke-AndroidArtifactCollection {
  if ($script:artifactCollection.attempted) { return }
  $script:artifactCollection.attempted = $true
  try {
    Collect-AndroidFailureArtifacts
    $script:artifactCollection.ok = $true
  } catch {
    $script:artifactCollection.ok = $false
    $script:artifactCollection.error = $_.Exception.Message
  }
}

function Restore-AndroidBaseline {
  $script:baselineRestore.attempted = $true
  try {
    Restore-M11FaultHarness
  } catch {
    $script:adbStateRestore.ok = $false
    $script:adbStateRestore.error = $_.Exception.Message
    $script:faultProxyCleanup.ok = $false
    $script:faultProxyCleanup.error = $_.Exception.Message
    if ($script:firstExitCode -eq 0) {
      $script:firstExitCode = 1
      $script:failedStep = 'baseline-restore'
    }
  }
  if ($TestMode) {
    $action = if ($script:runtimeDisposition -in @('reuse', 'reject')) {
      'preserve-runtime'
    } elseif ($script:runtimeOwnedByRun) {
      'stop-owned-runtime'
    } elseif ($TestEmulatorOwnership -eq 'controller-started') {
      'stop-exact'
    } else { 'preserve' }
    if ($CleanupRecordPath) {
      Set-Content -LiteralPath $CleanupRecordPath -Value $action -Encoding ASCII
    }
    if ($FailStep -eq 'baseline-restore') {
      $script:baselineRestore.ok = $false
      $script:baselineRestore.error = 'Injected baseline restore failure.'
      if ($script:firstExitCode -eq 0) {
        $script:firstExitCode = 23
        $script:failedStep = 'baseline-restore'
      }
    } else {
      $script:baselineRestore.ok = $true
    }
    return
  }
  $cleanupErrors = [Collections.Generic.List[string]]::new()
  try {
    Stop-FieldPermissionGrantHelper
  } catch {
    [void]$cleanupErrors.Add("camera grant helper: $($_.Exception.Message)")
  }
  try {
    Remove-FieldOperationsProvider
  } catch {
    [void]$cleanupErrors.Add("field provider: $($_.Exception.Message)")
  }
  try {
    Stop-AndroidHostBridge
  } catch {
    [void]$cleanupErrors.Add("host bridge: $($_.Exception.Message)")
  }
  if ($script:runtimeOwnedByRun) {
    try {
      [void](Invoke-LocalRuntime -Arguments @(
            '-Command', 'down', '-Target', 'android',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
            '-AndroidDevice', $AndroidDevice
          ))
    } catch {
      [void]$cleanupErrors.Add("runtime down: $($_.Exception.Message)")
    }
    try {
      [void](Invoke-LocalRuntime -Arguments @(
            '-Command', 'reset', '-Target', 'none',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot
          ))
    } catch {
      [void]$cleanupErrors.Add("fixture reset: $($_.Exception.Message)")
    }
  } elseif ($script:emulatorOwnedByRun) {
    try {
      $state = Read-RimsRuntimeState -Paths $runtimePaths
      $emulatorCleanup = Stop-RimsOwnedEmulator -State $state
      if (-not $emulatorCleanup.ok) { throw $emulatorCleanup.detail }
      $state.emulator = $null
      $state.target = 'none'
      Write-RimsRuntimeState -Paths $runtimePaths -State $state
    } catch {
      [void]$cleanupErrors.Add("owned emulator: $($_.Exception.Message)")
    }
  }
  $script:baselineRestore.ok = $cleanupErrors.Count -eq 0
  $script:baselineRestore.error = $cleanupErrors -join '; '
  if (-not $script:baselineRestore.ok -and $script:firstExitCode -eq 0) {
    $script:firstExitCode = 1
    $script:failedStep = 'baseline-restore'
  }
}

function Write-AndroidReport {
  param([string]$OutputPath)
  $frontendCommit = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
  $backendCommit = (& git -C $BackendDir rev-parse HEAD 2>$null).Trim()
  $report = [pscustomobject][ordered]@{
    schemaVersion = 1
    target = 'android'
    ok = $script:firstExitCode -eq 0
    exitCode = $script:firstExitCode
    failedStep = $script:failedStep
    startedAt = $startedAt.ToString('o')
    finishedAt = [DateTimeOffset]::Now.ToString('o')
    frontendCommit = $frontendCommit
    backendCommit = $backendCommit
    backendDir = $BackendDir
    runtimeOwnedByRun = [bool]$script:runtimeOwnedByRun
    runtimeDisposition = $script:runtimeDisposition
    androidDevice = $AndroidDevice
    androidSerial = $script:androidSerial
    apiBaseUrl = $apiBaseUrl
    emulator = $script:emulatorIdentity
    fixtureCounts = $script:fixtureCounts
    e2e = $script:e2eData
    hostBridge = $script:hostBridgeIdentity
    hostBridgeCleanup = $hostBridgeCleanup
    faultProxy = $script:faultProxyIdentity
    faultProxyCleanup = $faultProxyCleanup
    faultControl = $faultControl
    adbStateRestore = $adbStateRestore
    baselineRestore = $baselineRestore
    artifactCollection = $artifactCollection
    failureArtifacts = $failureArtifacts
    toolVersions = [pscustomobject][ordered]@{
      powershell = $PSVersionTable.PSVersion.ToString()
      flutter = if ($TestMode) { $null } else {
        ((& flutter --version 2>$null | Select-Object -First 1) -join '').Trim()
      }
      adb = if ($TestMode) { $null } else {
        $adbVersion = Invoke-Adb -Arguments @('version')
        (([string]$adbVersion.StandardOutput -split '\r?\n')[0]).Trim()
      }
    }
    steps = @($script:steps)
  }
  $report | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath $OutputPath `
    -Encoding UTF8
}

$lockPath = Join-Path $runtimePaths.root 'acceptance-smoke.lock'
$smokeLock = $null
try {
  $smokeLock = [IO.File]::Open(
    $lockPath,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
  )
} catch {
  throw "Another managed Android smoke owns the runtime lock: $lockPath"
}

$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
  New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}

try {
  foreach ($name in $stepNames) {
    if ($name -eq 'write-report') { break }
    if ($firstExitCode -ne 0) { break }
    if ($TestMode -and $name -eq 'up-android') {
      $runtimeDisposition = Get-TestRuntimeDisposition
      if ($runtimeDisposition -eq 'reject') {
        $script:firstExitCode = 1
        $script:failedStep = 'up-android'
      } else {
        $androidSerial = 'emulator-5554'
        $runtimeOwnedByRun = $runtimeDisposition -eq 'start'
        $emulatorOwnedByRun = $runtimeOwnedByRun -and $TestEmulatorOwnership -eq 'controller-started'
        $emulatorOwned = $emulatorOwnedByRun
        $emulatorIdentity = [pscustomobject][ordered]@{
          avdName = $AndroidDevice
          serial = $androidSerial
          owned = $emulatorOwned
          windowsPid = if ($emulatorOwned) { 4242 } else { $null }
          windowsProcessStartTimeUtc = if ($emulatorOwned) {
            '2026-07-12T00:00:00Z'
          } else { $null }
        }
      }
    }
    if ($TestMode -and
        $name -eq 'android-integration-test' -and
        $Phase -eq 'offline-sync') {
      try {
        Start-M11FaultProxy
        Invoke-M11ProcessStages
      } catch {
        $script:firstExitCode = if ($_.Exception.Data.Contains('ExitCode')) {
          [int]$_.Exception.Data['ExitCode']
        } else { 1 }
        $script:failedStep = 'android-integration-test'
      }
    }
    $action = switch ($name) {
      'doctor-android' {
        {
          [void](Invoke-LocalRuntime -Arguments @(
                '-Command', 'doctor', '-Target', 'android', '-Output', 'Json',
                '-BackendDir', $BackendDir,
                '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
                '-AndroidDevice', $AndroidDevice
              ))
        }
      }
      'up-android' {
        {
          $existingState = Read-RimsRuntimeState -Paths $runtimePaths
          $stateExists = $null -ne $existingState
          $hadEmulator = $stateExists -and $null -ne $existingState.emulator
          $requestMatches = $stateExists -and (Test-RimsRuntimeRequestMatchesState `
              -State $existingState `
              -BackendDir $BackendDir `
              -BackendWorkspaceRoot $BackendWorkspaceRoot `
              -BackendPort $BackendPort)
          $healthy = $stateExists -and $requestMatches -and (Test-WindowsHealthzOnce)
          $script:runtimeDisposition = Resolve-RimsAndroidSmokeRuntimeDisposition `
            -StateExists:$stateExists `
            -RequestMatches:$requestMatches `
            -Healthy:$healthy
          if ($script:runtimeDisposition -eq 'reject') {
            throw 'Managed runtime state is stale, unhealthy, or does not match the requested backend identity.'
          }
          $script:runtimeOwnedByRun = $script:runtimeDisposition -eq 'start'
          $arguments = @(
            '-Command', 'up', '-Target', 'none',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot
          )
          if ($IncludeDependencies) { $arguments += '-IncludeDependencies' }
          [void](Invoke-LocalRuntime -Arguments $arguments -TimeoutSeconds 600)
          $state = Read-RimsRuntimeState -Paths $runtimePaths
          if ($null -eq $state) {
            throw 'Backend startup did not persist managed runtime state.'
          }
          [void](Resolve-RimsAndroidRuntime `
              -State $state `
              -Paths $runtimePaths `
              -AndroidDevice $AndroidDevice)
          Get-CurrentAndroidRuntime
          $script:emulatorOwnedByRun = $script:emulatorOwned -and -not $hadEmulator
          $script:emulatorIdentity.owned = $script:emulatorOwnedByRun
        }
      }
      'reset-fixtures' {
        {
          $wslWorkspace = ConvertTo-RimsWslPath -WindowsPath $BackendWorkspaceRoot
          $execution = Invoke-WslBackendCommand `
            -Command 'RIMS_ALLOW_DEV_SEED=1 RIMS_WORKSPACE_ROOT="$1" bash scripts/m9_dev_seed.sh --reset' `
            -CommandArguments @($wslWorkspace)
          $counts = Get-RimsM9FixtureCountsFromOutput `
            -Output ([string]$execution.StandardOutput)
          if (-not $counts.ok) {
            Throw-AndroidChildFailure -Message $counts.detail -ExitCode 1
          }
          $script:fixtureCounts = $counts
          $script:fixturesMutated = $true
        }
      }
      'windows-healthz' {
        {
          Start-AndroidHostBridge
          if (-not (Test-WindowsHealthzOnce)) {
            throw 'Windows backend health remained unavailable after host bridge setup.'
          }
        }
      }
      'emulator-healthz' { { Test-EmulatorHealthz } }
      'android-integration-test' {
        {
          Start-M11FaultProxy
          New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
          [void](Invoke-Adb -Arguments @('-s', $androidSerial, 'logcat', '-c'))
          Invoke-FieldOperationsDeviceSetup
          Start-FieldPermissionGrantHelper
          if ($Phase -eq 'offline-sync') {
            Invoke-M11ProcessStages
            return
          }
          $execution = Invoke-AndroidFlutterTest
          @($execution.StandardOutput, $execution.StandardError) | Set-Content `
            -LiteralPath $flutterOutputPath `
            -Encoding UTF8
          if ($Phase -eq 'field-operations') {
            @(([string]$execution.StandardOutput -split '\r?\n') | Where-Object {
                $_ -match 'attachment|upload|progress|RIMS_E2E_RESULT'
              }) | Add-Content `
              -LiteralPath $uploadProviderLogPath `
              -Encoding UTF8
          }
          if ($execution.ExitCode -ne 0) {
            Throw-AndroidChildFailure `
              -Message "Android integration test failed: $(Get-RimsExternalCommandSummary -Result $execution)" `
              -ExitCode $execution.ExitCode
          }
          try {
            $script:e2eData = ConvertFrom-RimsStrictE2eMarker `
              -OutputText ([string]$execution.StandardOutput) `
              -ExpectedMarker Result
          } catch {
            Throw-AndroidChildFailure -Message $_.Exception.Message -ExitCode 1
          }
        }
      }
      'runtime-status' {
        {
          [void](Invoke-LocalRuntime -Arguments @(
                '-Command', 'status', '-Target', 'android', '-Output', 'Json',
                '-BackendDir', $BackendDir,
                '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
                '-AndroidDevice', $AndroidDevice
              ))
        }
      }
    }
    Invoke-AndroidStep -Name $name -Action $action
  }
} finally {
  if ($firstExitCode -ne 0) {
    if ($runtimeOwnedByRun -and [string]::IsNullOrWhiteSpace($androidSerial)) {
      try { Get-CurrentAndroidRuntime } catch {}
    }
    Invoke-AndroidArtifactCollection
  }
  Restore-AndroidBaseline
  if ($firstExitCode -ne 0 -and -not $artifactCollection.attempted) {
    Invoke-AndroidArtifactCollection
  }
}

if (-not [string]::IsNullOrWhiteSpace($M11CommandRecordPath)) {
  $m11RecordDirectory = Split-Path -Parent $M11CommandRecordPath
  if (-not [string]::IsNullOrWhiteSpace($m11RecordDirectory)) {
    New-Item -ItemType Directory -Force -Path $m11RecordDirectory | Out-Null
  }
  @($m11Commands) | ConvertTo-Json | Set-Content `
    -LiteralPath $M11CommandRecordPath `
    -Encoding UTF8
}

$reportTemporary = "$ReportPath.tmp-$PID"
try {
  $writeWatch = [Diagnostics.Stopwatch]::StartNew()
  $writeStep = [pscustomobject][ordered]@{
    name = 'write-report'
    ok = $true
    exitCode = 0
    durationMs = 0
    detail = ''
  }
  $steps.Add($writeStep)
  Write-AndroidReport -OutputPath $reportTemporary
  $writeWatch.Stop()
  $writeStep.durationMs = [Math]::Max(1, $writeWatch.ElapsedMilliseconds)
  Write-AndroidReport -OutputPath $reportTemporary
  Move-Item -LiteralPath $reportTemporary -Destination $ReportPath -Force
} catch {
  Remove-Item -LiteralPath $reportTemporary -Force -ErrorAction SilentlyContinue
  if ($firstExitCode -eq 0) {
    $firstExitCode = 1
    $failedStep = 'write-report'
  }
  throw
} finally {
  if ($null -ne $smokeLock) {
    $smokeLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}

if ($Output -eq 'Json') {
  Get-Content -LiteralPath $ReportPath -Raw | Write-Output
} else {
  Write-Host "Android smoke report: $ReportPath"
}
exit $firstExitCode
