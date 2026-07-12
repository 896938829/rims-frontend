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
if (-not $localText.Contains("'rims_android_smoke.ps1'")) {
  throw 'rims_local smoke does not delegate to the Android wrapper.'
}
if (-not $localText.Contains("@('-AndroidDevice', `$AndroidDevice)")) {
  throw 'rims_local smoke does not pass the explicit Android AVD.'
}
foreach ($text in @($webWrapperText, (Get-Content -LiteralPath $wrapper -Raw))) {
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
    '--dart-define=RIMS_E2E_BARCODE=M9-PAGE-0001',
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
    $expectedCleanup = if ($ownership -eq 'pre-existing') {
      'preserve'
    } else { 'stop-exact' }
    Assert-Equal `
      -Actual (Get-Content -LiteralPath $cleanupRecord -Raw).Trim() `
      -Expected $expectedCleanup `
      -Message "Cleanup action for $ownership emulator."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Android smoke wrapper self-test passed.'
