$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptDir 'rims_m10_smoke.ps1'

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
  throw "Missing M10 smoke wrapper: $wrapper"
}

$plan = (& $wrapper `
    -ListPlan `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -Output Json) -join "`n" | ConvertFrom-Json

Assert-Equal -Actual $plan.target -Expected 'android-m10' -Message 'Target.'
Assert-Equal `
  -Actual $plan.phase `
  -Expected 'field-operations' `
  -Message 'Android phase.'
Assert-Equal `
  -Actual (@($plan.scenarios) -join '|') `
  -Expected 'camera-deny|camera-grant|home-resume|process-recreation|network-interruption|attachment-upload' `
  -Message 'Fault scenario order.'
Assert-Equal `
  -Actual $plan.deterministicInjection.productionDefault `
  -Expected 'disabled' `
  -Message 'Production injection boundary.'
Assert-Equal `
  -Actual $plan.deterministicInjection.barcodeDefine `
  -Expected 'RIMS_E2E_BARCODE' `
  -Message 'Barcode injection define.'
Assert-Equal `
  -Actual $plan.deterministicInjection.fileDefine `
  -Expected 'RIMS_E2E_PICKED_FILE' `
  -Message 'File injection define.'
Assert-Equal `
  -Actual (@($plan.failureArtifacts) -join '|') `
  -Expected 'android-report|upload-log|provider-cleanup|flutter-output' `
  -Message 'Failure evidence.'
Assert-Equal `
  -Actual $plan.cleanup `
  -Expected 'always-run-owned-providers-and-runtime' `
  -Message 'Cleanup policy.'

$tempRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-m10-smoke-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $reportPath = Join-Path $tempRoot 'm10-failure.json'
  $artifactRoot = Join-Path $tempRoot 'artifacts'
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & powershell.exe `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $wrapper `
      -AndroidDevice 'Medium_Phone_API_36.1' `
      -TestMode `
      -FailStep 'network-interruption' `
      -ReportPath $reportPath `
      -ArtifactRoot $artifactRoot 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 23) {
    throw "Injected first failure returned '$exitCode' instead of 23."
  }
  $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert-Equal `
    -Actual $report.failedStep `
    -Expected 'network-interruption' `
    -Message 'First failure.'
  Assert-Equal `
    -Actual (@($report.steps | ForEach-Object { $_.name }) -join '|') `
    -Expected 'camera-deny|camera-grant|home-resume|process-recreation|network-interruption|provider-cleanup|write-report' `
    -Message 'Failure short-circuit and cleanup order.'
  Assert-Equal `
    -Actual $report.cleanup.ok `
    -Expected $true `
    -Message 'Provider cleanup result.'
  foreach ($artifactName in @('androidReport', 'uploadLog', 'providerCleanup', 'flutterOutput')) {
    $path = [string]$report.failureArtifacts.$artifactName
    if ([string]::IsNullOrWhiteSpace($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "M10 failure artifact '$artifactName' is missing."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'M10 smoke wrapper self-test passed.'
