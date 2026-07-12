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
  [string]$ReportPath,
  [string]$ArtifactRoot,
  [switch]$TestMode,
  [string]$FailStep,
  [ValidateSet('pre-existing', 'controller-started')]
  [string]$TestEmulatorOwnership = 'pre-existing',
  [switch]$TestPreExistingRuntime,
  [string]$CleanupRecordPath,
  [ValidateSet('baseline', 'field-operations')]
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
if ($TestMode -and [string]::IsNullOrWhiteSpace($FailStep)) {
  throw 'TestMode requires an explicit FailStep.'
}
if ($TestMode -and $FailStep -notin @(
    @($stepNames | Where-Object { $_ -ne 'write-report' }) + 'baseline-restore'
  )) {
  throw "TestMode FailStep must be one of: $(@(@($stepNames | Where-Object { $_ -ne 'write-report' }) + 'baseline-restore') -join ', ')."
}
if ($KeepRunning) {
  throw 'Android smoke does not support -KeepRunning because its host bridge must remain exactly owned.'
}

$apiBaseUrl = "http://10.0.2.2:$BackendPort/api/v1"
$integrationTestPath = if ($Phase -eq 'field-operations') {
  'integration_test/m10_field_operations_test.dart'
} else { 'integration_test/app_e2e_test.dart' }
$fieldDefines = if ($Phase -eq 'field-operations') {
  @(
    '--dart-define=RIMS_E2E_FIELD_OPERATIONS=true',
    '--dart-define=RIMS_E2E_BARCODE=M9-PAGE-0001',
    '--dart-define=RIMS_E2E_PICKED_FILE=<provider-file>'
  )
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
    'flutter', 'test', '--no-pub',
    $integrationTestPath,
    '-d', '<resolved-serial>',
    "--dart-define=API_BASE_URL=$apiBaseUrl"
  ) + $fieldDefines
  deviceActions = if ($Phase -eq 'field-operations') {
    @(
      'camera-deny',
      'camera-grant',
      'home-resume',
      'process-recreation',
      'network-disable-enable',
      'provider-cleanup'
    )
  } else { @() }
  readinessChecks = @('windows-healthz', 'emulator-healthz')
  failureArtifacts = $failureArtifactNames
  cleanup = [pscustomobject][ordered]@{
    preExistingDevice = 'preserve'
    controllerStartedDevice = 'stop-only-on-pid-and-start-time-match'
    hostBridge = 'stop-only-on-pid-and-start-time-match'
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
$emulatorIdentity = $null
$fixtureCounts = $null
$e2eData = $null
$runtimeOwnedByRun = $false
$fixturesMutated = $false
$hostBridgeProcess = $null
$hostBridgeIdentity = $null
$flutterOutputPath = Join-Path $ArtifactRoot 'flutter-output.log'
$uploadProviderLogPath = Join-Path $ArtifactRoot 'upload-provider.log'
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
    owned = $script:emulatorOwned
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

function Invoke-AndroidFlutterTest {
  $flutter = Resolve-RimsCommandPath -Name 'flutter'
  if ([string]::IsNullOrWhiteSpace($flutter)) {
    throw 'flutter was not found on PATH.'
  }
  $flutterArguments = @(
    'test', '--no-pub', $integrationTestPath,
    '-d', $androidSerial,
    "--dart-define=API_BASE_URL=$apiBaseUrl"
  ) + $fieldDefines
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
    $timedOut = -not $process.WaitForExit(1200 * 1000)
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
      StandardOutput = $standardOutput
      StandardError = $standardError
    }
  } finally {
    $process.Dispose()
  }
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
      ) | Set-Content -LiteralPath $uploadProviderLogPath -Encoding UTF8
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
  if ($TestMode) {
    $action = if ($TestPreExistingRuntime) {
      'preserve-runtime'
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
    androidDevice = $AndroidDevice
    androidSerial = $script:androidSerial
    apiBaseUrl = $apiBaseUrl
    emulator = $script:emulatorIdentity
    fixtureCounts = $script:fixtureCounts
    e2e = $script:e2eData
    hostBridge = $script:hostBridgeIdentity
    hostBridgeCleanup = $hostBridgeCleanup
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
    if ($TestMode -and $name -eq 'up-android' -and -not $TestPreExistingRuntime) {
      $androidSerial = 'emulator-5554'
      $emulatorOwned = $TestEmulatorOwnership -eq 'controller-started'
      $runtimeOwnedByRun = $true
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
          if (Test-Path -LiteralPath $runtimePaths.state) {
            throw 'Managed runtime state already exists; run down before Android smoke.'
          }
          $script:runtimeOwnedByRun = $true
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
          New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
          [void](Invoke-Adb -Arguments @('-s', $androidSerial, 'logcat', '-c'))
          Invoke-FieldOperationsDeviceSetup
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
          $resultLine = @(([string]$execution.StandardOutput -split '\r?\n') |
              Where-Object { $_ -match '^RIMS_E2E_RESULT\s+\{' } |
              Select-Object -Last 1)
          if ($resultLine.Count -eq 0 -or
              $resultLine[0] -notmatch '^RIMS_E2E_RESULT\s+(?<json>\{.*\})$') {
            Throw-AndroidChildFailure `
              -Message 'Android integration test omitted RIMS_E2E_RESULT data.' `
              -ExitCode 1
          }
          $script:e2eData = $Matches.json | ConvertFrom-Json
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
