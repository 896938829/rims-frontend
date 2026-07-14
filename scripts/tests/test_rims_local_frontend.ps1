$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$frontendModule = Join-Path $scriptDir 'lib\rims_local_frontend.ps1'
$androidGradleProperties = Join-Path `
  (Split-Path -Parent $scriptDir) `
  'rims_frontend\android\gradle.properties'
$androidSettings = Join-Path `
  (Split-Path -Parent $scriptDir) `
  'rims_frontend\android\settings.gradle.kts'
$androidGradleWrapperProperties = Join-Path `
  (Split-Path -Parent $scriptDir) `
  'rims_frontend\android\gradle\wrapper\gradle-wrapper.properties'

if (-not (Test-Path -LiteralPath $frontendModule -PathType Leaf)) {
  throw 'Frontend lifecycle module is required.'
}

. $commonScript
Remove-Item -LiteralPath 'Function:\Test-RimsFlutterAppStartedMachineOutput' `
  -Force `
  -ErrorAction SilentlyContinue
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
Assert-Contains `
  -Collection $android.arguments `
  -Expected '--machine' `
  -Message 'Android Flutter launch must emit machine events for app readiness.'
Assert-True `
  -Value ((Get-Content -LiteralPath $androidGradleProperties) -contains 'kotlin.incremental=false') `
  -Message 'Android builds must disable the Kotlin 2.3.20 incremental cache.'
Assert-True `
  -Value ((Get-Content -LiteralPath $androidGradleProperties) -contains 'kotlin.compiler.execution.strategy=in-process') `
  -Message 'Android builds must avoid the Kotlin 2.3.20 compiler daemon deadlock.'
Assert-True `
  -Value ((Get-Content -LiteralPath $androidGradleProperties) -contains 'org.gradle.daemon=false') `
  -Message 'Android builds must not leave a persistent Gradle daemon.'
Assert-True `
  -Value ((Get-Content -LiteralPath $androidGradleProperties) -contains 'org.gradle.workers.max=4') `
  -Message 'Android build worker concurrency must remain bounded.'
Assert-True `
  -Value ((Get-Content -LiteralPath $androidGradleProperties) -contains 'android.builtInKotlin=false') `
  -Message 'Legacy Kotlin plugin compatibility must remain enabled.'
$androidSettingsText = Get-Content -LiteralPath $androidSettings -Raw
Assert-True `
  -Value ($androidSettingsText -like '*id("com.android.application") version "8.11.1" apply false*') `
  -Message 'Android Gradle Plugin must remain on the API 36 compatible legacy-KGP baseline.'
$androidGradleWrapperText = Get-Content -LiteralPath $androidGradleWrapperProperties -Raw
Assert-True `
  -Value ($androidGradleWrapperText -like '*gradle-8.13-bin.zip*') `
  -Message 'Gradle wrapper must match the AGP 8.11.1 compatibility baseline.'
$singleMachineStarted = @'
[{"event":"app.started","params":{"appId":"rims"}}]
'@
$multiMachineStarted = @'
[{"event":"daemon.connected"},{"event":"app.start"},{"event":"app.started","params":{"appId":"rims"}}]
'@
$otherMachineEvents = @'
[{"event":"daemon.connected"},{"event":"app.start"}]
'@

Assert-True `
  -Value (Test-RimsFlutterAppStartedMachineOutput `
      -Output '{"event":"app.started","params":{"appId":"rims"}}') `
  -Message 'A valid Flutter app.started machine event was not accepted.'
Assert-True `
  -Value (Test-RimsFlutterAppStartedMachineOutput `
      -Output $singleMachineStarted) `
  -Message 'A single-event Flutter machine array was not accepted.'
Assert-True `
  -Value (Test-RimsFlutterAppStartedMachineOutput `
      -Output $multiMachineStarted) `
  -Message 'A multi-event Flutter machine array was not accepted.'
Assert-False `
  -Value (Test-RimsFlutterAppStartedMachineOutput `
      -Output '{"event":"app.progress"}') `
  -Message 'Flutter machine output without app.started was accepted.'
Assert-False `
  -Value (Test-RimsFlutterAppStartedMachineOutput `
      -Output $otherMachineEvents) `
  -Message 'A Flutter machine array without app.started was accepted.'
Assert-False `
  -Value (Test-RimsFlutterAppStartedMachineOutput -Output '{not-json') `
  -Message 'Invalid Flutter machine output was accepted.'
Assert-False `
  -Value (Test-RimsFlutterAppStartedMachineOutput -Output '[]') `
  -Message 'An empty Flutter machine array was accepted.'

$sharedLogPath = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-flutter-shared-' + [guid]::NewGuid().ToString('N') + '.log')
$sharedLogWriter = $null
try {
  $sharedLogWriter = [IO.FileStream]::new(
    $sharedLogPath,
    [IO.FileMode]::Create,
    [IO.FileAccess]::Write,
    [IO.FileShare]::ReadWrite
  )
  $sharedLogBytes = [Text.Encoding]::UTF8.GetBytes($singleMachineStarted)
  $sharedLogWriter.Write($sharedLogBytes, 0, $sharedLogBytes.Length)
  $sharedLogWriter.Flush()
  Assert-True `
    -Value ((Read-RimsSharedTextFile -Path $sharedLogPath).Contains('app.started')) `
    -Message 'Flutter readiness could not read a log held open for redirected output.'
} finally {
  if ($null -ne $sharedLogWriter) {
    $sharedLogWriter.Dispose()
  }
  Remove-Item -LiteralPath $sharedLogPath -Force -ErrorAction SilentlyContinue
}

$originalOwnedProcessCheck = (Get-Command `
    -Name Test-RimsNestedOwnedProcess `
    -CommandType Function).ScriptBlock
$machineReadAttempts = [pscustomobject]@{ value = 0 }
try {
  Set-Item -LiteralPath 'Function:\Test-RimsNestedOwnedProcess' -Value {
    param($State, $PropertyName)
    return $true
  }
  $machineReadiness = Wait-RimsFlutterAppStarted `
    -State ([pscustomobject]@{ frontend = [pscustomobject]@{} }) `
    -OutputPath 'C:\unused\frontend.stdout.log' `
    -TimeoutSeconds 2 `
    -ReadOutputAction {
      $machineReadAttempts.value++
      if ($machineReadAttempts.value -eq 1) {
        throw 'Injected transient stdout read failure.'
      }
      return '[{"event":"app.started"}]'
    }
  Assert-True `
    -Value $machineReadiness `
    -Message 'A transient Flutter stdout read failure ended machine readiness early.'
  Assert-True `
    -Value ($machineReadAttempts.value -ge 2) `
    -Message 'Flutter machine readiness did not retry stdout after a transient read failure.'
} finally {
  Set-Item `
    -LiteralPath 'Function:\Test-RimsNestedOwnedProcess' `
    -Value $originalOwnedProcessCheck
}

$flutterDiagnostics = @(Get-RimsFlutterLaunchDiagnosticLines -Text @'
RIMS_FLUTTER_LAUNCH gate-open target=android executable=C:\flutter\bin\flutter.bat argumentCount=7
RIMS_FLUTTER_LAUNCH invoke-before target=android
RIMS_FLUTTER_LAUNCH invoke-after target=android exitCode=1
unrelated output DB_PASSWORD=must-not-return
'@)
Assert-Equal `
  -Actual ($flutterDiagnostics -join '|') `
  -Expected 'gate-open target=android executable=C:\flutter\bin\flutter.bat argumentCount=7|invoke-before target=android|invoke-after target=android exitCode=1' `
  -Message 'Flutter launch diagnostics were not extracted without unrelated output.'
Assert-Equal `
  -Actual (Get-RimsAndroidMachineReadinessTimeoutSeconds) `
  -Expected 900 `
  -Message 'Android machine readiness timeout is too short for a bounded cold build.'

$emulatorLauncherScript = New-RimsHiddenEmulatorLauncherScript
if (-not $emulatorLauncherScript.Contains('Start-Process')) {
  throw 'Gated emulator launcher does not start the emulator through Start-Process.'
}
if (-not $emulatorLauncherScript.Contains('-WindowStyle Hidden')) {
  throw 'Gated emulator launcher does not keep the emulator child hidden.'
}
if (-not $emulatorLauncherScript.Contains("'-no-window'")) {
  throw 'Gated emulator launcher does not pass -no-window to the emulator child.'
}
if (-not $emulatorLauncherScript.Contains("'-no-snapshot-load'")) {
  throw 'Gated emulator launcher must cold-load controller-owned AVD state.'
}
if (-not $emulatorLauncherScript.Contains('WaitForExit')) {
  throw 'Gated emulator launcher does not wait for its emulator child.'
}
if ($emulatorLauncherScript.Contains('& $p.executable -avd $p.avdName')) {
  throw 'Gated emulator launcher still invokes emulator.exe directly.'
}
$bootReadinessSource = (Get-Item 'Function:\Wait-RimsAndroidBootCompleted').ScriptBlock.ToString()
foreach ($readinessContract in @(
    "'shell', 'service', 'check', 'activity'",
    "'shell', 'cmd', 'package', 'path', 'android'"
  )) {
  if (-not $bootReadinessSource.Contains($readinessContract)) {
    throw "Android boot readiness omitted '$readinessContract'."
  }
}

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

$sameSerialCalls = New-Object 'Collections.Generic.List[string]'
$sameSerialDifferentAvd = Find-RimsRunningAndroidTarget `
  -RequestedDevice 'emulator-5554' `
  -OnlineSerials @('emulator-5554') `
  -AvdNameAction {
    param($serial)
    [void]$sameSerialCalls.Add($serial)
    return 'Different_AVD'
  }
Assert-False `
  -Value $sameSerialDifferentAvd.found `
  -Message 'A serial equal to the requested AVD name was accepted without AVD verification.'
Assert-Equal `
  -Actual ($sameSerialCalls -join '|') `
  -Expected 'emulator-5554' `
  -Message 'A serial equal to the requested AVD name bypassed emu avd name verification.'

$noRunningTarget = Find-RimsRunningAndroidTarget `
  -RequestedDevice 'Medium_Phone_API_36.1' `
  -OnlineSerials @() `
  -AvdNameAction { throw 'No serial should be inspected.' }
Assert-False `
  -Value $noRunningTarget.found `
  -Message 'An empty adb device list must permit a new owned emulator launch.'

$existingWebState = [pscustomobject]@{
  target = 'web'
  frontendPort = 18091
  frontend = [pscustomobject]@{ target = 'web' }
  emulator = $null
}
$noneCompatibility = Get-RimsFrontendRequestCompatibility `
  -State $existingWebState `
  -Target 'none' `
  -FrontendPort 18091 `
  -AndroidDevice ''
Assert-False `
  -Value $noneCompatibility.matches `
  -Message 'Target none accepted a state that still manages a frontend.'

$webPortCompatibility = Get-RimsFrontendRequestCompatibility `
  -State $existingWebState `
  -Target 'web' `
  -FrontendPort 18092 `
  -AndroidDevice ''
Assert-False `
  -Value $webPortCompatibility.matches `
  -Message 'Web frontend accepted a different requested port.'

$existingAndroidState = [pscustomobject]@{
  target = 'android'
  frontendPort = 18091
  frontend = [pscustomobject]@{ target = 'android' }
  emulator = [pscustomobject]@{ avdName = 'Medium_Phone_API_36.1' }
}
$androidAvdCompatibility = Get-RimsFrontendRequestCompatibility `
  -State $existingAndroidState `
  -Target 'android' `
  -FrontendPort 18091 `
  -AndroidDevice 'Different_AVD'
Assert-False `
  -Value $androidAvdCompatibility.matches `
  -Message 'Android frontend accepted a different requested AVD.'

$unmanagedProbeCalls = New-Object 'Collections.Generic.List[string]'
$unmanagedOnline = Get-RimsUnmanagedAndroidEmulatorHealth `
  -Emulator ([pscustomobject]@{
      serial = 'emulator-5554'
      avdName = 'Medium_Phone_API_36.1'
    }) `
  -OnlineSerialsAction {
    [void]$unmanagedProbeCalls.Add('devices')
    return @('emulator-5554')
  } `
  -AvdNameAction {
    param($serial)
    [void]$unmanagedProbeCalls.Add("avd:$serial")
    return 'Medium_Phone_API_36.1'
  }
Assert-True `
  -Value $unmanagedOnline.healthy `
  -Message 'An online unmanaged emulator with an exact AVD was unhealthy.'
Assert-Equal `
  -Actual ($unmanagedProbeCalls -join '|') `
  -Expected 'devices|avd:emulator-5554' `
  -Message 'Unmanaged emulator health did not revalidate adb devices and the exact AVD.'

$unmanagedOffline = Get-RimsUnmanagedAndroidEmulatorHealth `
  -Emulator ([pscustomobject]@{
      serial = 'emulator-5554'
      avdName = 'Medium_Phone_API_36.1'
    }) `
  -OnlineSerialsAction { return @() } `
  -AvdNameAction { throw 'Offline serial must not be treated as healthy.' }
Assert-False `
  -Value $unmanagedOffline.healthy `
  -Message 'An offline unmanaged emulator was healthy.'

$unmanagedWrongAvd = Get-RimsUnmanagedAndroidEmulatorHealth `
  -Emulator ([pscustomobject]@{
      serial = 'emulator-5554'
      avdName = 'Medium_Phone_API_36.1'
    }) `
  -OnlineSerialsAction { return @('emulator-5554') } `
  -AvdNameAction { param($serial) return 'Different_AVD' }
Assert-False `
  -Value $unmanagedWrongAvd.healthy `
  -Message 'An unmanaged emulator with the wrong AVD was healthy.'

$ownedNotBooted = Get-RimsAndroidEmulatorHealth `
  -Emulator ([pscustomobject]@{
      serial = 'emulator-5554'
      avdName = 'Medium_Phone_API_36.1'
    }) `
  -OnlineSerialsAction { return @('emulator-5554') } `
  -AvdNameAction { param($serial) return 'Medium_Phone_API_36.1' } `
  -BootCompletedAction { param($serial) return $false }
Assert-False `
  -Value $ownedNotBooted.healthy `
  -Message 'A not-booted owned emulator was healthy.'

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

$emulatorLaunchSnapshots = New-Object 'Collections.Generic.List[object]'
$emulatorCleanupCount = [pscustomobject]@{ value = 0 }
$emulatorLaunchState = New-TestFrontendState
$emulatorLaunchState.cleanupPending = $true
$emulatorLaunchState.emulator = [pscustomobject]@{
  avdName = 'Medium_Phone_API_36.1'
  serial = $null
  owned = $false
  windowsPid = $null
  windowsProcessStartTimeUtc = $null
  cleanupPending = $true
}
$emulatorLaunch = Invoke-RimsAndroidEmulatorLaunchStateMachine `
  -State $emulatorLaunchState `
  -PersistStateAction {
    param($state)
    [void]$emulatorLaunchSnapshots.Add(($state | ConvertTo-Json -Depth 8 | ConvertFrom-Json))
  } `
  -SpawnAction {
    return [pscustomobject]@{
      ok = $true
      identity = [pscustomobject]@{
        windowsPid = 7201
        windowsProcessStartTimeUtc = '2026-01-01T00:00:03.0000000Z'
      }
    }
  } `
  -SerialAction { return 'emulator-5554' } `
  -BootAction { return $true } `
  -CleanupAction { $emulatorCleanupCount.value++; return $true }
Assert-True -Value $emulatorLaunch.ok -Message 'Controller-owned emulator launch failed.'
Assert-Equal `
  -Actual $emulatorLaunchState.emulator.serial `
  -Expected 'emulator-5554' `
  -Message 'Controller-owned emulator serial was not persisted.'
Assert-True `
  -Value $emulatorLaunchState.emulator.owned `
  -Message 'Controller-owned emulator did not persist exact process ownership.'
Assert-False `
  -Value $emulatorLaunchState.cleanupPending `
  -Message 'Healthy controller-owned emulator remained cleanup-pending.'
Assert-Equal `
  -Actual $emulatorCleanupCount.value `
  -Expected 0 `
  -Message 'Healthy controller-owned emulator was rolled back.'

$emulatorGateOrder = New-Object 'Collections.Generic.List[string]'
$emulatorGateState = New-TestFrontendState
$emulatorGateState.cleanupPending = $true
$emulatorGateState.emulator = [pscustomobject]@{
  avdName = 'Medium_Phone_API_36.1'
  serial = $null
  owned = $false
  windowsPid = $null
  windowsProcessStartTimeUtc = $null
  cleanupPending = $true
}
$emulatorGate = Invoke-RimsAndroidEmulatorLaunchStateMachine `
  -State $emulatorGateState `
  -PersistStateAction { param($state) [void]$emulatorGateOrder.Add('persist') } `
  -SpawnAction {
    [void]$emulatorGateOrder.Add('spawn')
    return [pscustomobject]@{
      ok = $true
      identity = [pscustomobject]@{
        windowsPid = 7203
        windowsProcessStartTimeUtc = '2026-01-01T00:00:05.0000000Z'
      }
    }
  } `
  -ActivateAction { [void]$emulatorGateOrder.Add('activate') } `
  -SerialAction { [void]$emulatorGateOrder.Add('serial'); return 'emulator-5558' } `
  -BootAction { param($serial) return $true } `
  -CleanupAction { return $true }
Assert-True -Value $emulatorGate.ok -Message 'Gated emulator launch failed.'
Assert-Equal `
  -Actual ($emulatorGateOrder[0..2] -join '|') `
  -Expected 'spawn|persist|activate' `
  -Message 'Emulator activation opened before durable launcher ownership.'

$emulatorTimeoutState = New-TestFrontendState
$emulatorTimeoutState.cleanupPending = $true
$emulatorTimeoutState.emulator = [pscustomobject]@{
  avdName = 'Medium_Phone_API_36.1'
  serial = $null
  owned = $false
  windowsPid = $null
  windowsProcessStartTimeUtc = $null
  cleanupPending = $true
}
$emulatorTimeoutCleanup = [pscustomobject]@{ value = 0 }
$emulatorTimeout = Invoke-RimsAndroidEmulatorLaunchStateMachine `
  -State $emulatorTimeoutState `
  -PersistStateAction { param($state) } `
  -SpawnAction {
    return [pscustomobject]@{
      ok = $true
      identity = [pscustomobject]@{
        windowsPid = 7202
        windowsProcessStartTimeUtc = '2026-01-01T00:00:04.0000000Z'
      }
    }
  } `
  -SerialAction { return 'emulator-5556' } `
  -BootAction { return $false } `
  -CleanupAction { $emulatorTimeoutCleanup.value++; return $true }
Assert-False -Value $emulatorTimeout.ok -Message 'Android boot timeout launch passed.'
Assert-Equal `
  -Actual $emulatorTimeoutCleanup.value `
  -Expected 1 `
  -Message 'Android boot timeout did not roll back its exact owned emulator.'
Assert-True `
  -Value $emulatorTimeoutState.cleanupPending `
  -Message 'Android boot timeout discarded cleanup-pending ownership.'

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

  $pendingBackend = Start-TestSleepProcess -TrackedProcesses $tracked
  $pendingFrontend = Start-TestSleepProcess -TrackedProcesses $tracked
  $pendingEmulator = Start-TestSleepProcess -TrackedProcesses $tracked
  $pendingPort = Get-TestEphemeralPort
  $pendingLifecycleState = New-TestRuntimeState `
    -Process $pendingBackend `
    -RuntimePaths $runtimePaths `
    -BackendPort $pendingPort `
    -CleanupPending $true
  $pendingLifecycleState.target = 'android'
  $pendingLifecycleState | Add-Member -MemberType NoteProperty -Name frontend -Value ([pscustomobject]@{
    target = 'android'
    windowsPid = $pendingFrontend.Id
    windowsProcessStartTimeUtc = $pendingFrontend.StartTime.ToUniversalTime().ToString('o')
    cleanupPending = $true
  }) -Force
  $pendingLifecycleState | Add-Member -MemberType NoteProperty -Name emulator -Value ([pscustomobject]@{
    owned = $true
    serial = 'emulator-5554'
    avdName = 'Medium_Phone_API_36.1'
    windowsPid = $pendingEmulator.Id
    windowsProcessStartTimeUtc = $pendingEmulator.StartTime.ToUniversalTime().ToString('o')
    cleanupPending = $true
  }) -Force
  Write-RimsRuntimeState -Paths $runtimePaths -State $pendingLifecycleState
  $pendingLifecycleStatus = Invoke-RimsLocalStatus `
    -ScriptDirectory $scriptDir `
    -BackendDir 'C:\test-backend-source' `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -BackendPort $pendingPort
  $pendingFrontendComponents = @($pendingLifecycleStatus.components | Where-Object {
      $_.name -eq 'frontend'
    })
  $pendingEmulatorComponents = @($pendingLifecycleStatus.components | Where-Object {
      $_.name -eq 'emulator'
    })
  Assert-Equal `
    -Actual $pendingFrontendComponents.Count `
    -Expected 1 `
    -Message 'Cleanup-pending status omitted the frontend component.'
  Assert-Equal `
    -Actual $pendingEmulatorComponents.Count `
    -Expected 1 `
    -Message 'Cleanup-pending status omitted the emulator component.'
  Assert-False `
    -Value $pendingFrontendComponents[0].ok `
    -Message 'Cleanup-pending frontend was healthy.'
  Assert-False `
    -Value $pendingEmulatorComponents[0].ok `
    -Message 'Cleanup-pending emulator was healthy.'
  Remove-RimsRuntimeState -Paths $runtimePaths

  $downBackend = Start-TestSleepProcess -TrackedProcesses $tracked
  $downFrontend = Start-TestSleepProcess -TrackedProcesses $tracked
  $downEmulator = Start-TestSleepProcess -TrackedProcesses $tracked
  $downPort = Get-TestEphemeralPort
  $downState = New-TestRuntimeState `
    -Process $downBackend `
    -RuntimePaths $runtimePaths `
    -BackendPort $downPort
  $downState.target = 'android'
  $downState | Add-Member -MemberType NoteProperty -Name frontend -Value ([pscustomobject]@{
    target = 'android'
    windowsPid = $downFrontend.Id
    windowsProcessStartTimeUtc = $downFrontend.StartTime.ToUniversalTime().ToString('o')
    cleanupPending = $false
  }) -Force
  $downState | Add-Member -MemberType NoteProperty -Name emulator -Value ([pscustomobject]@{
    owned = $true
    serial = 'emulator-5554'
    avdName = 'Medium_Phone_API_36.1'
    windowsPid = $downEmulator.Id
    windowsProcessStartTimeUtc = $downEmulator.StartTime.ToUniversalTime().ToString('o')
    cleanupPending = $false
  }) -Force
  Write-RimsRuntimeState -Paths $runtimePaths -State $downState
  $fullDown = Invoke-RimsLocalDown `
    -ScriptDirectory $scriptDir `
    -BackendDir 'C:\test-backend-source' `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -BackendPort $downPort
  Assert-True -Value $fullDown.ok -Message 'Exact down did not complete the full frontend lifecycle.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $downBackend.Id) `
    -Message 'Exact down left the controller-owned backend alive.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $downFrontend.Id) `
    -Message 'Exact down left the controller-owned frontend alive.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $downEmulator.Id) `
    -Message 'Exact down left the controller-owned emulator alive.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Exact down retained state after the full lifecycle completed.'

  $resolveAndroidToolFunction = (Get-Item 'Function:\Resolve-RimsAndroidTool').ScriptBlock
  $resolveAdbDevicesFunction = (Get-Item 'Function:\Get-RimsAdbDeviceSerials').ScriptBlock
  $resolveInstalledAvdsFunction = (Get-Item 'Function:\Get-RimsInstalledAndroidAvds').ScriptBlock
  $resolveSerialWaitFunction = (Get-Item 'Function:\Wait-RimsAndroidSerialForAvd').ScriptBlock
  $resolveBootWaitFunction = (Get-Item 'Function:\Wait-RimsAndroidBootCompleted').ScriptBlock
  $resolvedEmulatorProcess = Start-TestSleepProcess -TrackedProcesses $tracked
  try {
    Set-Item -LiteralPath 'Function:\Resolve-RimsAndroidTool' -Value {
      param($CommandName, $SdkRelativePath)
      return $CommandName
    }
    Set-Item -LiteralPath 'Function:\Get-RimsAdbDeviceSerials' -Value {
      param($AdbExecutable)
      return @()
    }
    Set-Item -LiteralPath 'Function:\Get-RimsInstalledAndroidAvds' -Value {
      param($EmulatorExecutable)
      return @('Medium_Phone_API_36.1')
    }
    Set-Item -LiteralPath 'Function:\Wait-RimsAndroidSerialForAvd' -Value {
      param($AdbExecutable, $AvdName, $TimeoutSeconds)
      return 'emulator-5554'
    }
    Set-Item -LiteralPath 'Function:\Wait-RimsAndroidBootCompleted' -Value {
      param($AdbExecutable, $Serial, $TimeoutSeconds, $ProbeAction)
      return $true
    }
    Set-Item -LiteralPath 'Function:\Start-Process' -Value {
      param($FilePath, $ArgumentList, $RedirectStandardOutput, $RedirectStandardError, $WindowStyle, [switch]$PassThru)
      return $resolvedEmulatorProcess
    }
    $resolvedAndroidState = New-TestFrontendState
    $resolvedAndroid = Resolve-RimsAndroidRuntime `
      -State $resolvedAndroidState `
      -Paths $runtimePaths `
      -AndroidDevice 'Medium_Phone_API_36.1'
    Assert-Equal `
      -Actual $resolvedAndroid.serial `
      -Expected 'emulator-5554' `
      -Message 'Resolved Android runtime returned the wrong serial.'
    if (-not $resolvedAndroid.detail.Contains('emulator-5554')) {
      throw 'Resolved Android runtime detail omitted the launched serial.'
    }
  } finally {
    Set-Item -LiteralPath 'Function:\Resolve-RimsAndroidTool' -Value $resolveAndroidToolFunction
    Set-Item -LiteralPath 'Function:\Get-RimsAdbDeviceSerials' -Value $resolveAdbDevicesFunction
    Set-Item -LiteralPath 'Function:\Get-RimsInstalledAndroidAvds' -Value $resolveInstalledAvdsFunction
    Set-Item -LiteralPath 'Function:\Wait-RimsAndroidSerialForAvd' -Value $resolveSerialWaitFunction
    Set-Item -LiteralPath 'Function:\Wait-RimsAndroidBootCompleted' -Value $resolveBootWaitFunction
    Remove-Item -LiteralPath 'Function:\Start-Process' -Force
    Remove-RimsRuntimeState -Paths $runtimePaths
  }

  $newBackendOnFrontendFailure = Start-TestSleepProcess -TrackedProcesses $tracked
  $newBackendFailurePort = Get-TestEphemeralPort
  $newBackendFailureState = New-TestRuntimeState `
    -Process $newBackendOnFrontendFailure `
    -RuntimePaths $runtimePaths `
    -BackendPort $newBackendFailurePort
  $newBackendFailure = Complete-RimsFailedUpResult `
    -Result (New-RimsLocalResult -Command 'up') `
    -Paths $runtimePaths `
    -State $newBackendFailureState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -FailureContext 'Injected frontend launch failure.' `
    -BackendPort $newBackendFailurePort `
    -Remediation 'Retry the frontend launch.'
  Assert-False `
    -Value $newBackendFailure.ok `
    -Message 'Frontend failure reported a newly-created backend start as successful.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $newBackendOnFrontendFailure.Id) `
    -Message 'Frontend failure did not roll back the backend created by this invocation.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Frontend failure retained state after newly-created backend rollback.'

  $existingBackendOnFrontendFailure = Start-TestSleepProcess -TrackedProcesses $tracked
  $existingBackendFailurePort = Get-TestEphemeralPort
  $existingBackendFailureState = New-TestRuntimeState `
    -Process $existingBackendOnFrontendFailure `
    -RuntimePaths $runtimePaths `
    -BackendPort $existingBackendFailurePort
  Write-RimsRuntimeState -Paths $runtimePaths -State $existingBackendFailureState
  $doctorFunction = (Get-Item 'Function:\Invoke-RimsLocalDoctor').ScriptBlock
  $healthFunction = (Get-Item 'Function:\Test-RimsHealthEndpoint').ScriptBlock
  $startFrontendFunction = (Get-Item 'Function:\Start-RimsManagedFrontend').ScriptBlock
  try {
    Set-Item -LiteralPath 'Function:\Invoke-RimsLocalDoctor' -Value {
      param($Target, $BackendDir, $BackendWorkspaceRoot, $AndroidDevice, $ScriptDirectory)
      return [pscustomobject]@{
        name = 'testDoctor'
        ok = $true
        required = $true
        detail = 'Injected doctor success.'
        remediation = ''
      }
    }
    Set-Item -LiteralPath 'Function:\Test-RimsHealthEndpoint' -Value {
      param($Url, $TimeoutSeconds)
      return $true
    }
    Set-Item -LiteralPath 'Function:\Start-RimsManagedFrontend' -Value {
      param($State, $Paths, $Target, $BackendPort, $FrontendPort, $AndroidDevice)
      return [pscustomobject]@{
        ok = $false
        detail = 'Injected frontend launch failure.'
        cleanupPending = $false
      }
    }
    $existingBackendFailure = Invoke-RimsLocalUp `
      -Target 'web' `
      -ScriptDirectory $scriptDir `
      -BackendDir 'C:\test-backend-source' `
      -BackendWorkspaceRoot 'C:\test-backend-runtime' `
      -BackendPort $existingBackendFailurePort `
      -FrontendPort 18091 `
      -AndroidDevice ''
    Assert-False `
      -Value $existingBackendFailure.ok `
      -Message 'Existing backend frontend failure reported success.'
    Assert-True `
      -Value (Test-TestProcessAlive -ProcessId $existingBackendOnFrontendFailure.Id) `
      -Message 'Frontend failure stopped the backend that existed before up.'
  } finally {
    Set-Item -LiteralPath 'Function:\Invoke-RimsLocalDoctor' -Value $doctorFunction
    Set-Item -LiteralPath 'Function:\Test-RimsHealthEndpoint' -Value $healthFunction
    Set-Item -LiteralPath 'Function:\Start-RimsManagedFrontend' -Value $startFrontendFunction
    Remove-RimsRuntimeState -Paths $runtimePaths
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

$restartRuntimeRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-restart-lock-' + [guid]::NewGuid().ToString('N'))
$restartOriginalRuntime = [Environment]::GetEnvironmentVariable(
  'RIMS_RUNTIME_DIR',
  'Process'
)
$restartDownFunction = (Get-Item 'Function:\Invoke-RimsLocalDownUnlocked').ScriptBlock
$restartUpFunction = (Get-Item 'Function:\Invoke-RimsLocalUpUnlocked').ScriptBlock
$restartCalls = [pscustomobject]@{ down = 0; up = 0 }
$restartBackend = $null
try {
  [Environment]::SetEnvironmentVariable('RIMS_RUNTIME_DIR', $restartRuntimeRoot, 'Process')
  $restartPaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  $restartBackend = Start-TestSleepProcess -TrackedProcesses $tracked
  $restartBackendId = $restartBackend.Id
  $restartPort = Get-TestEphemeralPort
  $restartState = New-TestRuntimeState `
    -Process $restartBackend `
    -RuntimePaths $restartPaths `
    -BackendPort $restartPort
  Write-RimsRuntimeState -Paths $restartPaths -State $restartState
  Set-Item -LiteralPath 'Function:\Invoke-RimsLocalDownUnlocked' -Value {
    param($ScriptDirectory, $BackendDir, $BackendWorkspaceRoot, $BackendPort, $IncludeDependencies)
    $restartCalls.down++
    return Complete-RimsLocalResult `
      -Result (New-RimsLocalResult -Command 'down') `
      -Ok $true `
      -ExitCode 0
  }
  Set-Item -LiteralPath 'Function:\Invoke-RimsLocalUpUnlocked' -Value {
    param($Target, $ScriptDirectory, $BackendDir, $BackendWorkspaceRoot, $BackendPort, $FrontendPort, $AndroidDevice, $IncludeDependencies)
    $restartCalls.up++
    return Complete-RimsLocalResult `
      -Result (New-RimsLocalResult -Command 'up') `
      -Ok $true `
      -ExitCode 0
  }
  $restartResult = Invoke-RimsLocalRestart `
    -Target 'none' `
    -ScriptDirectory $scriptDir `
    -BackendDir 'C:\test-backend-source' `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -BackendPort $restartPort `
    -FrontendPort 18091 `
    -AndroidDevice ''
  Assert-True -Value $restartResult.ok -Message 'Restart deadlocked or failed under its lifecycle lock.'
  Assert-Equal `
    -Actual $restartCalls.down `
    -Expected 1 `
    -Message 'Restart did not execute its unlocked down operation exactly once.'
  Assert-Equal `
    -Actual $restartCalls.up `
    -Expected 1 `
    -Message 'Restart did not execute its unlocked up operation exactly once.'
} finally {
  Set-Item -LiteralPath 'Function:\Invoke-RimsLocalDownUnlocked' -Value $restartDownFunction
  Set-Item -LiteralPath 'Function:\Invoke-RimsLocalUpUnlocked' -Value $restartUpFunction
  if ($null -ne $restartBackend) {
    $restartCleanupState = [pscustomobject]@{
      restartHelper = [pscustomobject]@{
        windowsPid = $restartBackend.Id
        windowsProcessStartTimeUtc = $restartBackend.StartTime.ToUniversalTime().ToString('o')
      }
    }
    [void](Stop-RimsNestedOwnedProcess `
        -State $restartCleanupState `
        -PropertyName 'restartHelper')
    $restartBackend.Dispose()
  }
  [Environment]::SetEnvironmentVariable('RIMS_RUNTIME_DIR', $restartOriginalRuntime, 'Process')
  Remove-Item -LiteralPath $restartRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-False `
  -Value (Test-TestProcessAlive -ProcessId $restartBackendId) `
  -Message 'Restart lock test leaked its helper process.'

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
