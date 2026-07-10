$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$frontendModule = Join-Path $scriptDir 'lib\rims_local_frontend.ps1'

if (-not (Test-Path -LiteralPath $frontendModule -PathType Leaf)) {
  throw 'Frontend lifecycle module is required.'
}

. $frontendModule

$web = New-FlutterLaunchSpec `
  -Target 'web' `
  -FrontendDirectory 'C:\repo\rims_frontend' `
  -BackendPort 18080 `
  -FrontendPort 18091
Assert-Equal -Actual $web.target -Expected 'web' -Message 'Web target changed.'
Assert-Equal `
  -Actual $web.workingDirectory `
  -Expected 'C:\repo\rims_frontend' `
  -Message 'Web working directory changed.'
Assert-True `
  -Value ($web.arguments -is [array]) `
  -Message 'Flutter launch arguments must remain an array.'
Assert-Contains -Collection $web.arguments -Expected 'web-server' -Message 'Web device missing.'
Assert-Contains -Collection $web.arguments -Expected '127.0.0.1' -Message 'Web host missing.'
Assert-Contains -Collection $web.arguments -Expected '18091' -Message 'Web port missing.'
Assert-Contains `
  -Collection $web.arguments `
  -Expected '--no-pub' `
  -Message 'Managed Flutter launch must not perform unbounded dependency resolution.'
Assert-Contains `
  -Collection $web.arguments `
  -Expected '--dart-define=API_BASE_URL=http://localhost:18080/api/v1' `
  -Message 'Web API URL changed.'

$android = New-FlutterLaunchSpec `
  -Target 'android' `
  -FrontendDirectory 'C:\repo\rims_frontend' `
  -BackendPort 18080 `
  -FrontendPort 18091 `
  -AndroidSerial 'emulator-5554'
Assert-Contains -Collection $android.arguments -Expected '-d' -Message 'Android device flag missing.'
Assert-Contains `
  -Collection $android.arguments `
  -Expected 'emulator-5554' `
  -Message 'Android serial missing.'
Assert-Contains `
  -Collection $android.arguments `
  -Expected '--dart-define=API_BASE_URL=http://10.0.2.2:18080/api/v1' `
  -Message 'Android API URL changed.'

$noneRejected = $false
try {
  [void](New-FlutterLaunchSpec `
      -Target 'none' `
      -FrontendDirectory 'C:\repo\rims_frontend' `
      -BackendPort 18080 `
      -FrontendPort 18091)
} catch {
  $noneRejected = $true
}
Assert-True -Value $noneRejected -Message 'Target none must not produce a Flutter command.'

$metacharRejected = $false
try {
  [void](New-FlutterLaunchSpec `
      -Target 'android' `
      -FrontendDirectory 'C:\repo\rims_frontend' `
      -BackendPort 18080 `
      -FrontendPort 18091 `
      -AndroidSerial 'emulator-5554;whoami')
} catch {
  $metacharRejected = $true
}
Assert-True `
  -Value $metacharRejected `
  -Message 'Android serial command metacharacters must be rejected.'

$parsedSerials = @(Get-RimsAdbDeviceSerialsFromOutput -Output @'
List of devices attached
emulator-5554 device product:sdk model:Medium transport_id:1
emulator-5556 offline
R58M123 device

'@)
Assert-Equal -Actual $parsedSerials.Count -Expected 2 -Message 'adb parser count changed.'
Assert-Contains -Collection $parsedSerials -Expected 'emulator-5554' -Message 'adb emulator missing.'
Assert-Contains -Collection $parsedSerials -Expected 'R58M123' -Message 'adb device missing.'

$mappingCalls = New-Object 'Collections.Generic.List[string]'
$mapped = Find-RimsRunningAndroidTarget `
  -RequestedDevice 'Medium_Phone_API_36.1' `
  -OnlineSerials @('emulator-5554', 'emulator-5556') `
  -AvdNameAction {
    param($serial)
    [void]$mappingCalls.Add($serial)
    if ($serial -eq 'emulator-5556') { return 'Medium_Phone_API_36.1' }
    return 'Other_AVD'
  }
Assert-True -Value $mapped.found -Message 'Running AVD was not mapped.'
Assert-Equal -Actual $mapped.serial -Expected 'emulator-5556' -Message 'AVD mapped to wrong serial.'
Assert-Equal `
  -Actual ($mappingCalls -join '|') `
  -Expected 'emulator-5554|emulator-5556' `
  -Message 'AVD mapping did not inspect serials explicitly.'

$noRunningTarget = Find-RimsRunningAndroidTarget `
  -RequestedDevice 'Medium_Phone_API_36.1' `
  -OnlineSerials @() `
  -AvdNameAction { throw 'No serial should be inspected.' }
Assert-False `
  -Value $noRunningTarget.found `
  -Message 'An empty adb device list must permit a new owned emulator launch.'

function New-TestFrontendState {
  return [pscustomobject][ordered]@{
    lifecycleStage = 'healthy'
    healthy = $true
    cleanupPending = $false
    frontend = [pscustomobject][ordered]@{
      target = 'web'
      windowsPid = $null
      windowsProcessStartTimeUtc = $null
      cleanupPending = $false
    }
    emulator = $null
  }
}

$snapshots = New-Object 'Collections.Generic.List[object]'
$activationCount = [pscustomobject]@{ value = 0 }
$cleanupCount = [pscustomobject]@{ value = 0 }
$readyState = New-TestFrontendState
$ready = Invoke-RimsFrontendLaunchStateMachine `
  -State $readyState `
  -PersistStateAction {
    param($state)
    [void]$snapshots.Add(($state | ConvertTo-Json -Depth 8 | ConvertFrom-Json))
  } `
  -SpawnAction {
    $identity = $readyState.frontend
    $identity.windowsPid = 7101
    $identity.windowsProcessStartTimeUtc = '2026-01-01T00:00:00.0000000Z'
    return [pscustomobject]@{ ok = $true; identity = $identity }
  } `
  -ActivateAction { $activationCount.value++ } `
  -ReadinessAction { return $true } `
  -CleanupAction { $cleanupCount.value++; return $true }
Assert-True -Value $ready.ok -Message 'Ready frontend state machine failed.'
Assert-Equal -Actual $snapshots.Count -Expected 3 -Message 'Frontend state transitions changed.'
Assert-Equal `
  -Actual $snapshots[0].frontend.windowsPid `
  -Expected $null `
  -Message 'Frontend process existed before provisional state.'
Assert-Equal `
  -Actual $snapshots[1].frontend.windowsPid `
  -Expected 7101 `
  -Message 'Frontend exact tuple was not durable before activation.'
Assert-Equal -Actual $activationCount.value -Expected 1 -Message 'Frontend activation count changed.'
Assert-Equal -Actual $cleanupCount.value -Expected 0 -Message 'Ready frontend was rolled back.'

$snapshots.Clear()
$activationCount.value = 0
$cleanupCount.value = 0
$failedState = New-TestFrontendState
$failed = Invoke-RimsFrontendLaunchStateMachine `
  -State $failedState `
  -PersistStateAction {
    param($state)
    [void]$snapshots.Add(($state | ConvertTo-Json -Depth 8 | ConvertFrom-Json))
  } `
  -SpawnAction {
    $identity = $failedState.frontend
    $identity.windowsPid = 7102
    $identity.windowsProcessStartTimeUtc = '2026-01-01T00:00:01.0000000Z'
    return [pscustomobject]@{ ok = $true; identity = $identity }
  } `
  -ActivateAction { $activationCount.value++ } `
  -ReadinessAction { return $false } `
  -CleanupAction { $cleanupCount.value++; return $true }
Assert-False -Value $failed.ok -Message 'Frontend readiness timeout passed.'
Assert-True `
  -Value $failed.ownershipPersisted `
  -Message 'Readiness failure lost durable ownership.'
Assert-Equal -Actual $cleanupCount.value -Expected 1 -Message 'Failed frontend was not rolled back.'

$activationCount.value = 0
$cleanupCount.value = 0
$persistCount = [pscustomobject]@{ value = 0 }
$gateState = New-TestFrontendState
$gateFailure = Invoke-RimsFrontendLaunchStateMachine `
  -State $gateState `
  -PersistStateAction {
    param($state)
    $persistCount.value++
    if ($persistCount.value -eq 2) { throw 'Injected tuple persistence failure.' }
  } `
  -SpawnAction {
    $identity = $gateState.frontend
    $identity.windowsPid = 7103
    $identity.windowsProcessStartTimeUtc = '2026-01-01T00:00:02.0000000Z'
    return [pscustomobject]@{ ok = $true; identity = $identity }
  } `
  -ActivateAction { $activationCount.value++ } `
  -ReadinessAction { return $true } `
  -CleanupAction { $cleanupCount.value++; return $true }
Assert-False -Value $gateFailure.ok -Message 'Tuple persistence failure passed.'
Assert-Equal -Actual $activationCount.value -Expected 0 -Message 'Gate opened before durable tuple.'
Assert-Equal -Actual $cleanupCount.value -Expected 1 -Message 'Ungated process was not rolled back.'

$bootAttempts = [pscustomobject]@{ value = 0 }
$bootTimedOut = Wait-RimsAndroidBootCompleted `
  -AdbExecutable 'adb.exe' `
  -Serial 'emulator-5554' `
  -TimeoutSeconds 1 `
  -ProbeAction {
    param($adb, $serial)
    $bootAttempts.value++
    return $false
  }
Assert-False -Value $bootTimedOut -Message 'Android boot timeout passed.'
Assert-True -Value ($bootAttempts.value -gt 0) -Message 'Android boot was never probed.'

$runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('rims-frontend-test-' + [guid]::NewGuid().ToString('N'))
$originalRuntime = $env:RIMS_RUNTIME_DIR
$tracked = New-Object 'Collections.Generic.List[Diagnostics.Process]'
try {
  $env:RIMS_RUNTIME_DIR = $runtimeRoot
  $runtimePaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  Initialize-RimsRuntimeDirectories -Paths $runtimePaths

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $portState = [pscustomobject]@{
      frontendPath = Split-Path -Parent $scriptDir
      target = 'none'
    }
    $conflict = Start-RimsManagedFrontend `
      -State $portState `
      -Paths $runtimePaths `
      -Target 'web' `
      -BackendPort 18080 `
      -FrontendPort $port `
      -AndroidDevice ''
    Assert-False -Value $conflict.ok -Message 'Occupied Web port was adopted.'
    Assert-False `
      -Value $conflict.cleanupPending `
      -Message 'Unmanaged Web listener became cleanup-pending.'
  } finally {
    $listener.Stop()
  }

  $ownedProcess = Start-TestSleepProcess -TrackedProcesses $tracked
  $ownedState = New-TestFrontendState
  $ownedState.frontend.windowsPid = $ownedProcess.Id
  $ownedState.frontend.windowsProcessStartTimeUtc = `
    $ownedProcess.StartTime.ToUniversalTime().ToString('o')
  $ownedCleanup = Stop-RimsNestedOwnedProcess `
    -State $ownedState `
    -PropertyName 'frontend'
  Assert-True -Value $ownedCleanup.ok -Message 'Exactly owned frontend did not stop.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $ownedProcess.Id) `
    -Message 'Exactly owned frontend remains alive.'

  $foreignProcess = Start-TestSleepProcess -TrackedProcesses $tracked
  $foreignState = New-TestFrontendState
  $foreignState.frontend.windowsPid = $foreignProcess.Id
  $foreignState.frontend.windowsProcessStartTimeUtc = '2000-01-01T00:00:00.0000000Z'
  $foreignCleanup = Stop-RimsNestedOwnedProcess `
    -State $foreignState `
    -PropertyName 'frontend'
  Assert-True -Value $foreignCleanup.ok -Message 'Foreign tuple cleanup should be a no-op.'
  Assert-True `
    -Value (Test-TestProcessAlive -ProcessId $foreignProcess.Id) `
    -Message 'PID-only match terminated a foreign process.'

  $unmanagedEmulator = Start-TestSleepProcess -TrackedProcesses $tracked
  $emulatorState = New-TestFrontendState
  $emulatorState.emulator = [pscustomobject]@{
    owned = $false
    windowsPid = $unmanagedEmulator.Id
    windowsProcessStartTimeUtc = $unmanagedEmulator.StartTime.ToUniversalTime().ToString('o')
  }
  $unmanagedCleanup = Stop-RimsOwnedEmulator -State $emulatorState
  Assert-True -Value $unmanagedCleanup.ok -Message 'Unmanaged emulator cleanup failed.'
  Assert-True `
    -Value (Test-TestProcessAlive -ProcessId $unmanagedEmulator.Id) `
    -Message 'Pre-existing emulator was terminated.'
} finally {
  foreach ($process in $tracked) {
    if (Test-TestProcessAlive -ProcessId $process.Id) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $process.Dispose()
  }
  $env:RIMS_RUNTIME_DIR = $originalRuntime
  if (Test-Path -LiteralPath $runtimeRoot) {
    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
  }
}

$restartDefinition = (Get-Command `
    -Name 'Invoke-RimsLocalRestartUnlocked' `
    -CommandType Function).Definition
if (-not $restartDefinition.Contains('Invoke-RimsLocalDownUnlocked') -or
    -not $restartDefinition.Contains('Invoke-RimsLocalUpUnlocked')) {
  throw 'Restart no longer composes unlocked down/up operations under one lock.'
}

$missingBackend = Join-Path `
  ([IO.Path]::GetTempPath()) `
  'rims-health-DB_PASSWORD=frontend-json-secret'
$jsonHealth = Invoke-LocalCli -Arguments @(
  '-Command', 'health',
  '-Output', 'Json',
  '-BackendDir', $missingBackend,
  '-BackendWorkspaceRoot', $missingBackend,
  '-BackendPort', '18080'
)
Assert-Equal `
  -Actual $jsonHealth.StandardError `
  -Expected '' `
  -Message 'JSON health wrote diagnostics to stderr.'
$jsonHealthResult = ConvertFrom-SingleJson `
  -Text $jsonHealth.StandardOutput `
  -Context 'Frontend health JSON'
Assert-Equal `
  -Actual $jsonHealthResult.command `
  -Expected 'health' `
  -Message 'Health JSON command changed.'
if ($jsonHealth.StandardOutput.Contains('frontend-json-secret')) {
  throw 'Health JSON leaked a sensitive value.'
}

Write-Host 'Frontend local lifecycle tests passed.'
