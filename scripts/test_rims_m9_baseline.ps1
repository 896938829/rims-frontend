$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$collector = Join-Path $scriptDir 'rims_m9_baseline.ps1'
if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) {
  throw "Missing M9 baseline collector: $collector"
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

$tempRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-m9-baseline-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $samplePath = Join-Path $tempRoot 'samples.json'
  $outputPath = Join-Path $tempRoot 'baseline.json'
  [pscustomobject]@{
    operations = @(
      [pscustomobject]@{
        name = 'healthz'
        thresholdMs = 19
        samples = @(1..20 | ForEach-Object {
            [pscustomobject]@{ durationMs = $_; ok = $true }
          })
      },
      [pscustomobject]@{
        name = 'inventory-page-1'
        thresholdMs = 10
        samples = @(
          [pscustomobject]@{ durationMs = 4; ok = $true },
          [pscustomobject]@{ durationMs = 12; ok = $false }
        )
      }
    )
  } | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath $samplePath `
    -Encoding UTF8

  & $collector `
    -SampleDataPath $samplePath `
    -OutputPath $outputPath
  if ($LASTEXITCODE -ne 1) {
    throw 'Threshold-failing sample baseline did not return exit code 1.'
  }
  $report = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
  $health = @($report.operations | Where-Object { $_.name -eq 'healthz' })[0]
  Assert-Equal -Actual $health.minMs -Expected 1 -Message 'Health minimum.'
  Assert-Equal -Actual $health.medianMs -Expected 10.5 -Message 'Health median.'
  Assert-Equal -Actual $health.p95Ms -Expected 19 -Message 'Health p95.'
  Assert-Equal -Actual $health.maxMs -Expected 20 -Message 'Health maximum.'
  Assert-Equal -Actual $health.successCount -Expected 20 -Message 'Health success count.'
  Assert-Equal -Actual $health.failureCount -Expected 0 -Message 'Health failure count.'
  Assert-Equal -Actual $health.thresholdPassed -Expected $true -Message 'Health threshold.'

  $inventory = @($report.operations | Where-Object {
      $_.name -eq 'inventory-page-1'
    })[0]
  Assert-Equal -Actual $inventory.successCount -Expected 1 -Message 'Inventory success count.'
  Assert-Equal -Actual $inventory.failureCount -Expected 1 -Message 'Inventory failure count.'
  Assert-Equal -Actual $inventory.thresholdPassed -Expected $false -Message 'Inventory threshold.'
  Assert-Equal -Actual $report.ok -Expected $false -Message 'Overall threshold result.'
  if (@($health.rawSamples).Count -ne 20) {
    throw 'Baseline report did not preserve all raw samples.'
  }

  $invalidPath = Join-Path $tempRoot 'invalid.json'
  Set-Content `
    -LiteralPath $invalidPath `
    -Value '{"operations":[]}' `
    -Encoding UTF8
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & powershell.exe `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $collector `
      -SampleDataPath $invalidPath `
      -OutputPath (Join-Path $tempRoot 'invalid-output.json') 2>&1
    $invalidExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($invalidExitCode -eq 0) {
    throw 'Empty sample operations produced a green baseline.'
  }

  foreach ($invalidNumericCase in @(
      '{"operations":[{"name":"boolean-threshold","thresholdMs":true,"samples":[{"durationMs":1,"ok":true}]}]}',
      '{"operations":[{"name":"boolean-duration","thresholdMs":10,"samples":[{"durationMs":false,"ok":true}]}]}'
    )) {
    Set-Content `
      -LiteralPath $invalidPath `
      -Value $invalidNumericCase `
      -Encoding UTF8
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $null = & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $collector `
        -SampleDataPath $invalidPath `
        -OutputPath (Join-Path $tempRoot 'invalid-numeric-output.json') 2>&1
      $invalidNumericExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($invalidNumericExitCode -eq 0) {
      throw 'Boolean baseline data was accepted as numeric.'
    }
  }

  $unsafePath = Join-Path $tempRoot 'unsafe.json'
  Set-Content `
    -LiteralPath $unsafePath `
    -Value '{"operations":[{"name":"unsafe","thresholdMs":10,"samples":[{"durationMs":1,"ok":false,"detail":"Authorization: Bearer secret-token"}]}]}' `
    -Encoding UTF8
  & $collector `
    -SampleDataPath $unsafePath `
    -OutputPath (Join-Path $tempRoot 'unsafe-output.json')
  if ($LASTEXITCODE -ne 1) {
    throw 'Failing unsafe sample did not return exit code 1.'
  }
  $unsafeReport = Get-Content `
    -LiteralPath (Join-Path $tempRoot 'unsafe-output.json') `
    -Raw
  if ($unsafeReport -match 'secret-token' -or $unsafeReport -notmatch '\[REDACTED\]') {
    throw 'Sample failure detail was not sanitized.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'M9 baseline calculation self-test passed.'
