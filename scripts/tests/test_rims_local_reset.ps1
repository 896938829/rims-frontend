$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requiredResetFunctions = @(
  'Invoke-RimsLocalResetUnlocked',
  'Invoke-RimsLocalReset'
)
foreach ($functionName in $requiredResetFunctions) {
  if (-not (Test-Path -LiteralPath "Function:\$functionName")) {
    throw "Reset lifecycle function '$functionName' is required."
  }
}

$savedFunctions = @{}
$mockedFunctions = @(
  'Invoke-RimsLocalDoctor',
  'Resolve-RimsLifecyclePaths',
  'Read-RimsRuntimeState',
  'Get-RimsWslLifecycleContext',
  'Get-RimsPostgresStatus',
  'Invoke-RimsBackendMigrations',
  'Invoke-RimsM9Fixtures'
)
foreach ($functionName in $mockedFunctions) {
  $savedFunctions[$functionName] = (Get-Item "Function:\$functionName").ScriptBlock
}

$fixtureResetObserved = [pscustomobject]@{ value = $false }
try {
  Set-Item 'Function:\Invoke-RimsLocalDoctor' -Value {
    param($Target, $BackendDir, $BackendWorkspaceRoot, $AndroidDevice, $ScriptDirectory)
    return [pscustomobject]@{
      name = 'doctor'
      ok = $true
      required = $true
      detail = 'ready'
      remediation = ''
    }
  }
  Set-Item 'Function:\Resolve-RimsLifecyclePaths' -Value {
    param($BackendDir, $BackendWorkspaceRoot)
    return [pscustomobject]@{
      success = $true
      backendPath = 'C:\backend\rims-goProgect'
      workspacePath = 'C:\runtime'
    }
  }
  Set-Item 'Function:\Read-RimsRuntimeState' -Value {
    param($Paths)
    return $null
  }
  Set-Item 'Function:\Get-RimsWslLifecycleContext' -Value {
    param($BackendDir, $BackendWorkspaceRoot, $RuntimePaths)
    return [pscustomobject]@{
      ok = $true
      detail = ''
      wsl = 'wsl.exe'
      environment = '/runtime/.env'
      backend = '/backend/rims-goProgect'
      workspace = '/runtime'
    }
  }
  Set-Item 'Function:\Get-RimsPostgresStatus' -Value {
    param($Context)
    return [pscustomobject]@{
      ok = $true
      healthy = $true
      status = 'healthy'
      detail = 'healthy'
    }
  }
  Set-Item 'Function:\Invoke-RimsBackendMigrations' -Value {
    param($Context)
    return [pscustomobject]@{ ok = $true; detail = 'migrated' }
  }
  Set-Item 'Function:\Invoke-RimsM9Fixtures' -Value {
    param($Context, [switch]$Reset)
    $fixtureResetObserved.value = [bool]$Reset
    return [pscustomobject]@{
      ok = $true
      mode = 'reset'
      detail = 'reset complete'
      counts = [pscustomobject]@{
        database = 'appdb'
        products = 45
        operatorUsers = 1
        warehouses = 1
        operatorBindings = 2
        inventories = 90
        nonStandardInventories = 25
        documents = 15
        transactions = 15
      }
    }
  }

  $reset = Invoke-RimsLocalResetUnlocked `
    -Target 'none' `
    -ScriptDirectory $scriptDir `
    -BackendDir 'C:\backend\rims-goProgect' `
    -BackendWorkspaceRoot 'C:\runtime' `
    -BackendPort 18080
  Assert-True -Value $reset.ok -Message 'Healthy reset lifecycle failed.'
  Assert-True -Value $fixtureResetObserved.value -Message 'Reset lifecycle seeded without reset mode.'
  Assert-Equal -Actual $reset.command -Expected 'reset' -Message 'Reset command name changed.'
  $fixtureComponent = @($reset.components | Where-Object { $_.name -eq 'fixtures' })
  Assert-Equal -Actual $fixtureComponent.Count -Expected 1 -Message 'Reset fixture component missing.'
  Assert-Equal -Actual $fixtureComponent[0].products -Expected 45 -Message 'Reset fixture counts missing.'

  $invalidTarget = Invoke-RimsLocalResetUnlocked `
    -Target 'web' `
    -ScriptDirectory $scriptDir `
    -BackendDir 'C:\backend\rims-goProgect' `
    -BackendWorkspaceRoot 'C:\runtime' `
    -BackendPort 18080
  Assert-False -Value $invalidTarget.ok -Message 'Reset accepted a frontend target.'
  Assert-True `
    -Value (($invalidTarget.errors -join ' ').Contains('Target none')) `
    -Message 'Reset target failure was unclear.'
} finally {
  foreach ($functionName in $mockedFunctions) {
    Set-Item "Function:\$functionName" -Value $savedFunctions[$functionName]
  }
}

Write-Host 'Local reset lifecycle tests passed.'
