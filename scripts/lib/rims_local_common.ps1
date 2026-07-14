$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rimsLocalModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$rimsLocalModules = @(
  'rims_local_core.ps1',
  'rims_local_state_lock.ps1',
  'rims_local_process_ownership.ps1',
  'rims_local_wsl_execution.ps1',
  'rims_local_doctor.ps1',
  'rims_local_compose_resources.ps1',
  'rims_local_fixtures.ps1',
  'rims_local_frontend.ps1',
  'rims_local_tls.ps1',
  'rims_local_lifecycle.ps1'
)

foreach ($rimsLocalModule in $rimsLocalModules) {
  . (Join-Path $rimsLocalModuleRoot $rimsLocalModule)
}

Remove-Variable -Name rimsLocalModule -ErrorAction SilentlyContinue
Remove-Variable -Name rimsLocalModules -ErrorAction SilentlyContinue
Remove-Variable -Name rimsLocalModuleRoot -ErrorAction SilentlyContinue
