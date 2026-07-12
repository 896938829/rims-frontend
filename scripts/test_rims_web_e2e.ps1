$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptDir 'rims_web_e2e.ps1'
$expectedSteps = @(
  'doctor-web',
  'up-backend',
  'reset-fixtures',
  'frontend-smoke',
  'backend-go-test',
  'backend-build',
  'backend-m8-smoke',
  'web-integration-test',
  'runtime-status',
  'write-report'
)

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

if (-not (Test-Path -LiteralPath $wrapper)) {
  throw "Missing Web E2E wrapper: $wrapper"
}

$listedSteps = @(& $wrapper -ListSteps)
Assert-Equal `
  -Actual ($listedSteps -join '|') `
  -Expected ($expectedSteps -join '|') `
  -Message 'Web E2E step order changed.'

$tempRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-web-e2e-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$staleScreenshot = [IO.Path]::GetFullPath((Join-Path `
    $scriptDir `
    '..\rims_frontend\build\screenshots\m9-stale-wrapper-self-test.png'))
try {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $staleScreenshot) | Out-Null
  Set-Content -LiteralPath $staleScreenshot -Value 'stale' -Encoding ASCII
  (Get-Item -LiteralPath $staleScreenshot).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
  $invalidReportPath = Join-Path $tempRoot 'invalid-green-report.json'
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & powershell.exe `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $wrapper `
      -TestMode `
      -ReportPath $invalidReportPath 2>&1
    $invalidExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($invalidExitCode -eq 0 -or (Test-Path -LiteralPath $invalidReportPath)) {
    throw 'TestMode produced an unexecuted green acceptance report.'
  }

  foreach ($invalidCount in @('0.4', '-0.4', '1.5', '2147483648')) {
    $invalidCountReport = Join-Path $tempRoot "invalid-count-$($invalidCount.Replace('.', '_')).json"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $null = & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $wrapper `
        -TestMode `
        -FailStep 'doctor-web' `
        -P0Count $invalidCount `
        -ReportPath $invalidCountReport 2>&1
      $invalidCountExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($invalidCountExitCode -eq 0 -or (Test-Path -LiteralPath $invalidCountReport)) {
      throw "Invalid defect count '$invalidCount' was accepted."
    }
  }

  $reportPath = Join-Path $tempRoot 'failure-report.json'
  $cleanupPath = Join-Path $tempRoot 'cleanup.txt'
  $driverCleanupPath = Join-Path $tempRoot 'driver-cleanup.txt'
  & $wrapper `
    -TestMode `
    -FailStep 'frontend-smoke' `
    -FailExitCode 23 `
    -TestActionFailure `
    -TestDriverStartedHere `
    -TestRestoreFailure `
    -ReportPath $reportPath `
    -CleanupRecordPath $cleanupPath `
    -DriverCleanupRecordPath $driverCleanupPath
  $failureExitCode = $LASTEXITCODE
  Write-Host 'Injected failure run completed.'
  if ($failureExitCode -eq 0) {
    throw 'Injected Web E2E child failure returned success.'
  }
  if (-not (Test-Path -LiteralPath $reportPath)) {
    throw 'Injected failure did not write a JSON report.'
  }
  $failureReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert-Equal -Actual $failureReport.ok -Expected $false -Message 'Failure report ok flag.'
  Assert-Equal -Actual $failureReport.exitCode -Expected 23 -Message 'Failure exit code.'
  Assert-Equal `
    -Actual $failureReport.failedStep `
    -Expected 'frontend-smoke' `
    -Message 'Failure report failed step.'
  Assert-Equal `
    -Actual (@($failureReport.steps | ForEach-Object { $_.name }) -join '|') `
    -Expected 'doctor-web|up-backend|reset-fixtures|frontend-smoke|write-report' `
    -Message 'Dependent steps were not short-circuited.'
  Assert-Equal `
    -Actual (Get-Content -LiteralPath $cleanupPath -Raw).Trim() `
    -Expected 'down' `
    -Message 'Failure cleanup did not stop managed services.'
  Assert-Equal -Actual $failureReport.baselineRestore.ok -Expected $false -Message 'Baseline restore status.'
  Assert-Equal -Actual $failureReport.driverCleanup.ok -Expected $true -Message 'Driver cleanup status.'
  if ([string]::IsNullOrWhiteSpace($failureReport.baselineRestore.error)) {
    throw 'Baseline restore failure detail was hidden.'
  }
  Assert-Equal -Actual $failureReport.expectedFixtureCounts.products -Expected 45 -Message 'Expected fixture product count.'
  Assert-Equal -Actual $failureReport.fixtureCounts -Expected $null -Message 'Unobserved fixture counts were fabricated.'
  Assert-Equal -Actual $failureReport.acceptanceStatus -Expected 'not-evaluated' -Message 'Acceptance status.'
  if (@($failureReport.logTails.PSObject.Properties).Count -eq 0) {
    throw 'Failure report omitted managed log tails.'
  }
  if ($failureReport.integrationFailureDetails -isnot [array]) {
    throw 'Integration failure details did not preserve JSON array shape.'
  }
  Assert-Equal -Actual @($failureReport.integrationFailureDetails).Count -Expected 0 -Message 'Historical failure details leaked.'
  if (@($failureReport.screenshots) -contains $staleScreenshot) {
    throw 'Historical screenshot leaked into the current report.'
  }
  foreach ($property in @($failureReport.logTails.PSObject.Properties)) {
    foreach ($line in @($property.Value)) {
      if ($line -isnot [string]) {
        throw "Log tail '$($property.Name)' contains a non-string value."
      }
    }
  }
  foreach ($name in @('powershell', 'wsl', 'go', 'chrome', 'chromeDriver')) {
    if ($null -eq $failureReport.toolVersions.PSObject.Properties[$name]) {
      throw "Tool version '$name' is missing."
    }
  }
  $writeStep = @($failureReport.steps | Where-Object { $_.name -eq 'write-report' })[0]
  if ($writeStep.durationMs -lt 1) {
    throw 'write-report duration was not measured.'
  }
  Assert-Equal `
    -Actual (Get-Content -LiteralPath $driverCleanupPath -Raw).Trim() `
    -Expected 'stop' `
    -Message 'Controller-owned test driver was not stopped.'

  $keepReportPath = Join-Path $tempRoot 'keep-report.json'
  $keepCleanupPath = Join-Path $tempRoot 'keep-cleanup.txt'
  $keepDriverCleanupPath = Join-Path $tempRoot 'keep-driver-cleanup.txt'
  & $wrapper `
    -TestMode `
    -FailStep 'frontend-smoke' `
    -TestDriverStartedHere `
    -KeepRunning `
    -ReportPath $keepReportPath `
    -CleanupRecordPath $keepCleanupPath `
    -DriverCleanupRecordPath $keepDriverCleanupPath
  Write-Host 'Injected KeepRunning run completed.'
  if ($LASTEXITCODE -eq 0) {
    throw 'Injected KeepRunning failure returned success.'
  }
  Assert-Equal `
    -Actual (Get-Content -LiteralPath $keepCleanupPath -Raw).Trim() `
    -Expected 'keep' `
    -Message 'KeepRunning did not preserve managed services.'
  Assert-Equal `
    -Actual (Get-Content -LiteralPath $keepDriverCleanupPath -Raw).Trim() `
    -Expected 'stop' `
    -Message 'KeepRunning left the controller-owned driver unmanaged.'
} finally {
  Remove-Item -LiteralPath $staleScreenshot -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host 'Web E2E wrapper self-test passed.'
