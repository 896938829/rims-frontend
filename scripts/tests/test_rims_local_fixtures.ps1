$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fixtureModule = Join-Path $scriptDir 'lib\rims_local_fixtures.ps1'
if (-not (Test-Path -LiteralPath $fixtureModule -PathType Leaf)) {
  throw 'Fixture lifecycle module is required.'
}

. $fixtureModule

$fixtureOutput = @'
BEGIN
COMMIT
RIMS_M9_FIXTURE_COUNTS {"database" : "appdb", "products" : 45, "operatorUsers" : 1, "warehouses" : 1, "operatorBindings" : 2, "inventories" : 90, "nonStandardInventories" : 25, "documents" : 15, "transactions" : 15}
'@
$counts = Get-RimsM9FixtureCountsFromOutput -Output $fixtureOutput
Assert-True -Value $counts.ok -Message 'Fixture counts marker was not parsed.'
Assert-Equal -Actual $counts.database -Expected 'appdb' -Message 'Fixture database changed.'
Assert-Equal -Actual $counts.products -Expected 45 -Message 'Fixture product count changed.'
Assert-Equal -Actual $counts.inventories -Expected 90 -Message 'Fixture inventory count changed.'
Assert-Equal -Actual $counts.documents -Expected 15 -Message 'Fixture document count changed.'
Assert-Equal -Actual $counts.transactions -Expected 15 -Message 'Fixture transaction count changed.'

$missingCounts = Get-RimsM9FixtureCountsFromOutput -Output 'seed completed without counts'
Assert-False -Value $missingCounts.ok -Message 'Missing fixture counts marker was accepted.'

$fixtureContext = [pscustomobject]@{
  wsl = 'C:\Windows\system32\wsl.exe'
  environment = '/mnt/e/runtime root/.env'
  backend = '/mnt/e/backend source/rims-goProgect'
  workspace = '/mnt/e/runtime root'
}
$seedSpec = New-RimsM9FixtureLaunchSpec -Context $fixtureContext
Assert-Equal -Actual $seedSpec.filePath -Expected $fixtureContext.wsl -Message 'Fixture WSL executable changed.'
Assert-True -Value ($seedSpec.arguments -is [array]) -Message 'Fixture arguments must remain an array.'
Assert-Contains -Collection $seedSpec.arguments -Expected $fixtureContext.environment -Message 'Fixture env path missing.'
Assert-Contains -Collection $seedSpec.arguments -Expected $fixtureContext.backend -Message 'Fixture backend path missing.'
Assert-Contains -Collection $seedSpec.arguments -Expected $fixtureContext.workspace -Message 'Fixture workspace path missing.'
Assert-False -Value ($seedSpec.arguments -contains '--reset') -Message 'Normal seed unexpectedly requested reset.'
Assert-False `
  -Value ([string]$seedSpec.script).Contains($fixtureContext.backend) `
  -Message 'Fixture backend path was interpolated into Bash source.'

$resetSpec = New-RimsM9FixtureLaunchSpec -Context $fixtureContext -Reset
Assert-Contains -Collection $resetSpec.arguments -Expected '--reset' -Message 'Fixture reset flag missing.'

$capturedFixtureSpec = [pscustomobject]@{ value = $null }
$seedResult = Invoke-RimsM9Fixtures `
  -Context $fixtureContext `
  -InvokeCommandAction {
    param($spec)
    $capturedFixtureSpec.value = $spec
    return [pscustomobject]@{
      ExitCode = 0
      StandardOutput = $fixtureOutput
      StandardError = ''
      TimedOut = $false
    }
  }
Assert-True -Value $seedResult.ok -Message 'Valid fixture seed result failed.'
Assert-Equal -Actual $seedResult.counts.products -Expected 45 -Message 'Seed result lost counts.'
Assert-False `
  -Value ($capturedFixtureSpec.value.arguments -contains '--reset') `
  -Message 'Seed invocation changed into reset.'

$resetResult = Invoke-RimsM9Fixtures `
  -Context $fixtureContext `
  -Reset `
  -InvokeCommandAction {
    param($spec)
    return [pscustomobject]@{
      ExitCode = 0
      StandardOutput = $fixtureOutput
      StandardError = ''
      TimedOut = $false
    }
  }
Assert-True -Value $resetResult.ok -Message 'Valid fixture reset result failed.'
Assert-Equal -Actual $resetResult.mode -Expected 'reset' -Message 'Reset result mode changed.'

$failedFixture = Invoke-RimsM9Fixtures `
  -Context $fixtureContext `
  -InvokeCommandAction {
    param($spec)
    return [pscustomobject]@{
      ExitCode = 1
      StandardOutput = ''
      StandardError = 'DB_PASSWORD=must-not-leak seed failed'
      TimedOut = $false
    }
  }
Assert-False -Value $failedFixture.ok -Message 'Failed fixture command reported success.'
Assert-False `
  -Value ([string]$failedFixture.detail).Contains('must-not-leak') `
  -Message 'Fixture failure leaked a sensitive value.'

Assert-True `
  -Value (Test-RimsShouldApplyM9Fixtures -Command 'up' -IncludeDependencies) `
  -Message 'up -IncludeDependencies did not require fixtures.'
Assert-False `
  -Value (Test-RimsShouldApplyM9Fixtures -Command 'up') `
  -Message 'up without dependencies unexpectedly required fixtures.'
Assert-True `
  -Value (Test-RimsShouldApplyM9Fixtures -Command 'reset') `
  -Message 'reset did not require fixtures.'
Assert-True `
  -Value (Test-RimsShouldApplyM9Fixtures -Command 'smoke') `
  -Message 'smoke did not require fixtures.'

Write-Host 'M9 fixture lifecycle tests passed.'
