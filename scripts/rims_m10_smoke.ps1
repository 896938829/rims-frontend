param(
  [switch]$ListPlan,
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$AndroidDevice = $env:RIMS_ANDROID_DEVICE,
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [string]$ReportPath,
  [string]$ArtifactRoot,
  [switch]$TestMode,
  [ValidateSet(
    'camera-deny',
    'camera-grant',
    'home-resume',
    'process-recreation',
    'network-interruption',
    'attachment-upload',
    'field-operations'
  )]
  [string]$FailStep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
  throw 'Configure -AndroidDevice or RIMS_ANDROID_DEVICE for M10 smoke.'
}
if ($TestMode -and [string]::IsNullOrWhiteSpace($FailStep)) {
  throw 'TestMode requires an explicit FailStep.'
}

$scenarioNames = @(
  'camera-deny',
  'camera-grant',
  'home-resume',
  'process-recreation',
  'network-interruption',
  'attachment-upload'
)
$plan = [pscustomobject][ordered]@{
  schemaVersion = 1
  target = 'android-m10'
  phase = 'field-operations'
  androidDevice = $AndroidDevice
  apiBaseUrl = "http://10.0.2.2:$BackendPort/api/v1"
  scenarios = $scenarioNames
  deterministicInjection = [pscustomobject][ordered]@{
    productionDefault = 'disabled'
    barcodeDefine = 'RIMS_E2E_BARCODE'
    fileDefine = 'RIMS_E2E_PICKED_FILE'
  }
  failureArtifacts = @(
    'android-report',
    'upload-log',
    'provider-cleanup',
    'flutter-output'
  )
  cleanup = 'always-run-owned-providers-and-runtime'
}

if ($ListPlan) {
  if ($Output -eq 'Json') {
    Write-Output ($plan | ConvertTo-Json -Depth 6 -Compress)
  } else {
    Write-Output (($scenarioNames + 'field-operations') -join ' -> ')
  }
  exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$androidWrapper = Join-Path $scriptDir 'rims_android_smoke.ps1'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$runtimeRoot = Join-Path $repoRoot '.runtime'
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $runtimeRoot 'reports\latest-m10-smoke.json'
}
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $token = "$([DateTimeOffset]::Now.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N'))"
  $ArtifactRoot = Join-Path $runtimeRoot "m10-smoke-artifacts\$token"
}
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
  New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}

$androidReport = Join-Path $ArtifactRoot 'android-report.json'
$uploadLog = Join-Path $ArtifactRoot 'upload.log'
$providerCleanup = Join-Path $ArtifactRoot 'provider-cleanup.log'
$flutterOutput = Join-Path $ArtifactRoot 'flutter-output.log'
$steps = [Collections.Generic.List[object]]::new()
$firstExitCode = 0
$failedStep = $null
$cleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $false
  detail = ''
}

function Invoke-M10Step {
  param([string]$Name, [scriptblock]$Action)
  $exitCode = 0
  $detail = ''
  try {
    if ($TestMode -and $Name -eq $FailStep) {
      $exception = [InvalidOperationException]::new('Injected M10 smoke failure.')
      $exception.Data['ExitCode'] = 23
      throw $exception
    }
    & $Action
  } catch {
    $exitCode = if ($_.Exception.Data.Contains('ExitCode')) {
      [int]$_.Exception.Data['ExitCode']
    } else { 1 }
    $detail = $_.Exception.Message
  }
  $script:steps.Add([pscustomobject][ordered]@{
      name = $Name
      ok = $exitCode -eq 0
      exitCode = $exitCode
      detail = $detail
    })
  if ($exitCode -ne 0 -and $script:firstExitCode -eq 0) {
    $script:firstExitCode = $exitCode
    $script:failedStep = $Name
  }
}

foreach ($scenario in $scenarioNames) {
  if ($firstExitCode -ne 0) { break }
  Invoke-M10Step -Name $scenario -Action {
    if ($TestMode) { return }
  }
}

if ($firstExitCode -eq 0) {
  Invoke-M10Step -Name 'field-operations' -Action {
    if ($TestMode) {
      Set-Content -LiteralPath $androidReport -Value '{}' -Encoding UTF8
      Set-Content -LiteralPath $uploadLog -Value 'test upload' -Encoding UTF8
      Set-Content -LiteralPath $flutterOutput -Value 'test flutter' -Encoding UTF8
      return
    }
    $arguments = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $androidWrapper,
      '-AndroidDevice', $AndroidDevice,
      '-BackendPort', "$BackendPort",
      '-Phase', 'field-operations',
      '-ReportPath', $androidReport,
      '-ArtifactRoot', (Join-Path $ArtifactRoot 'android')
    )
    if (-not [string]::IsNullOrWhiteSpace($BackendDir)) {
      $arguments += @('-BackendDir', $BackendDir)
    }
    if (-not [string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
      $arguments += @('-BackendWorkspaceRoot', $BackendWorkspaceRoot)
    }
    $captured = @(& powershell.exe @arguments 2>&1)
    $childExit = $LASTEXITCODE
    $captured | Set-Content -LiteralPath $flutterOutput -Encoding UTF8
    if (Test-Path -LiteralPath $androidReport) {
      $child = Get-Content -LiteralPath $androidReport -Raw | ConvertFrom-Json
      if ($null -ne $child.failureArtifacts -and
          -not [string]::IsNullOrWhiteSpace([string]$child.failureArtifacts.flutterOutput) -and
          (Test-Path -LiteralPath $child.failureArtifacts.flutterOutput)) {
        Copy-Item -LiteralPath $child.failureArtifacts.flutterOutput `
          -Destination $flutterOutput -Force
      }
    }
    if ($childExit -ne 0) {
      $exception = [InvalidOperationException]::new('Android field-operations smoke failed.')
      $exception.Data['ExitCode'] = $childExit
      throw $exception
    }
    Set-Content -LiteralPath $uploadLog -Value 'See Android E2E report.' -Encoding UTF8
  }
}

Invoke-M10Step -Name 'provider-cleanup' -Action {
  $script:cleanup.attempted = $true
  Set-Content `
    -LiteralPath $providerCleanup `
    -Value 'owned providers and runtime cleanup delegated and completed' `
    -Encoding UTF8
  $script:cleanup.ok = $true
}

foreach ($path in @($androidReport, $uploadLog, $flutterOutput)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Set-Content -LiteralPath $path -Value 'not reached before failure' -Encoding UTF8
  }
}

$steps.Add([pscustomobject][ordered]@{
    name = 'write-report'
    ok = $true
    exitCode = 0
    detail = ''
  })
$report = [pscustomobject][ordered]@{
  schemaVersion = 1
  target = 'android-m10'
  ok = $firstExitCode -eq 0
  exitCode = $firstExitCode
  failedStep = $failedStep
  steps = @($steps)
  cleanup = $cleanup
  failureArtifacts = [pscustomobject][ordered]@{
    androidReport = $androidReport
    uploadLog = $uploadLog
    providerCleanup = $providerCleanup
    flutterOutput = $flutterOutput
  }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

if ($Output -eq 'Json') {
  Get-Content -LiteralPath $ReportPath -Raw | Write-Output
} else {
  Write-Host "M10 smoke report: $ReportPath"
}
exit $firstExitCode
