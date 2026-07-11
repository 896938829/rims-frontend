$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$testRoot = Join-Path $scriptDir 'tests'
$testFiles = @(
  'test_rims_local_support.ps1',
  'test_rims_local_ownership.ps1',
  'test_rims_local_lock.ps1',
  'test_rims_local_compose.ps1',
  'test_rims_local_wsl.ps1',
  'test_rims_local_launch.ps1',
  'test_rims_local_fixtures.ps1',
  'test_rims_local_reset.ps1',
  'test_rims_local_frontend.ps1',
  'test_rims_local_core.ps1',
  'test_rims_local_cli.ps1'
)

try {
  foreach ($testFile in $testFiles) {
    . (Join-Path $testRoot $testFile)
  }
  Write-Host 'Local runtime aggregate test passed.'
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
