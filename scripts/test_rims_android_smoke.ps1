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
Assert-Equal `
  -Actual $offlinePlan.apiBaseUrl `
  -Expected 'http://10.0.2.2:18081/api/v1' `
  -Message 'M11 fault-proxy API URL.'
if (@($offlinePlan.command | Where-Object {
      $_ -eq 'integration_test/m11_offline_sync_test.dart'
    }).Count -ne 1) {
  throw 'M11 Android command omitted the offline-sync integration test.'
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
try {
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
    -Expected 'snapshot-airplane-mode|snapshot-wifi|start-owned-fault-proxy:18081|prepare-clean-app-data|run-stage:seed|capture-pid:seed|force-stop:seed|confirm-stopped:seed|run-stage:offline-draft|capture-pid:offline-draft|force-stop:offline-draft|confirm-stopped:offline-draft|run-stage:recovery|capture-pid:recovery|force-stop:recovery|confirm-stopped:recovery|reset-fault-proxy|restore-airplane-mode|restore-wifi|stop-owned-fault-proxy' `
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
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Android smoke wrapper self-test passed.'
