function Test-RimsShouldApplyM9Fixtures {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('up', 'reset', 'smoke')]
    [string]$Command,
    [switch]$IncludeDependencies
  )

  if ($Command -eq 'up') {
    return [bool]$IncludeDependencies
  }
  return $true
}

function Get-RimsM9FixtureLaunchScript {
  return @'
set -euo pipefail
env_file=$1
backend_dir=$2
workspace_root=$3
mode=$4
seed_script="$backend_dir/scripts/m9_dev_seed.sh"
if [ ! -f "$seed_script" ]; then
  printf 'M9 fixture seed script was not found.\n' >&2
  exit 1
fi
export RIMS_ALLOW_DEV_SEED=1
export RIMS_ENV_FILE="$env_file"
export RIMS_WORKSPACE_ROOT="$workspace_root"
if [ "$mode" = '--reset' ]; then
  exec bash "$seed_script" --reset
fi
exec bash "$seed_script"
'@
}

function New-RimsM9FixtureLaunchSpec {
  param(
    [Parameter(Mandatory = $true)][psobject]$Context,
    [switch]$Reset
  )

  $mode = if ($Reset) { '--reset' } else { 'seed' }
  $script = Get-RimsM9FixtureLaunchScript
  return [pscustomobject][ordered]@{
    filePath = $Context.wsl
    arguments = @(
      '-e',
      'bash',
      '-c',
      $script,
      'rims-m9-fixtures',
      $Context.environment,
      $Context.backend,
      $Context.workspace,
      $mode
    )
    script = $script
    mode = if ($Reset) { 'reset' } else { 'seed' }
  }
}

function Get-RimsM9FixtureCountsFromOutput {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Output
  )

  $payload = $null
  foreach ($line in ($Output -split '\r?\n')) {
    if ($line -match '^RIMS_M9_FIXTURE_COUNTS\s+(\{.+\})\s*$') {
      $payload = $Matches[1]
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$payload)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'Fixture output did not contain a counts marker.'
    }
  }

  try {
    $parsed = ConvertFrom-Json -InputObject $payload -ErrorAction Stop
    $required = @(
      'database',
      'products',
      'operatorUsers',
      'warehouses',
      'operatorBindings',
      'inventories',
      'nonStandardInventories',
      'documents',
      'transactions'
    )
    foreach ($name in $required) {
      if ($null -eq $parsed.PSObject.Properties[$name]) {
        throw "Fixture count '$name' is missing."
      }
    }
    return [pscustomobject][ordered]@{
      ok = $true
      detail = ''
      database = [string]$parsed.database
      products = [int]$parsed.products
      operatorUsers = [int]$parsed.operatorUsers
      warehouses = [int]$parsed.warehouses
      operatorBindings = [int]$parsed.operatorBindings
      inventories = [int]$parsed.inventories
      nonStandardInventories = [int]$parsed.nonStandardInventories
      documents = [int]$parsed.documents
      transactions = [int]$parsed.transactions
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'Fixture counts marker was malformed.'
    }
  }
}

function Invoke-RimsM9Fixtures {
  param(
    [Parameter(Mandatory = $true)][psobject]$Context,
    [switch]$Reset,
    [AllowNull()][scriptblock]$InvokeCommandAction
  )

  $spec = New-RimsM9FixtureLaunchSpec -Context $Context -Reset:$Reset
  $execution = if ($null -ne $InvokeCommandAction) {
    & $InvokeCommandAction $spec
  } else {
    Invoke-RimsExternalCommand `
      -FilePath $spec.filePath `
      -Arguments $spec.arguments `
      -TimeoutSeconds 240
  }
  $mode = $spec.mode
  if ($execution.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      mode = $mode
      detail = "M9 fixture $mode failed: $(Get-RimsExternalCommandSummary -Result $execution)"
      counts = $null
    }
  }

  $counts = Get-RimsM9FixtureCountsFromOutput `
    -Output ([string]$execution.StandardOutput)
  if (-not $counts.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      mode = $mode
      detail = $counts.detail
      counts = $null
    }
  }
  return [pscustomobject][ordered]@{
    ok = $true
    mode = $mode
    detail = "M9 fixture $mode completed with deterministic counts."
    counts = $counts
  }
}

function New-RimsM9FixtureComponent {
  param(
    [Parameter(Mandatory = $true)][psobject]$FixtureResult
  )

  $databaseName = if ($FixtureResult.ok) {
    [string]$FixtureResult.counts.database
  } else {
    ''
  }
  $component = New-RimsLocalComponent `
    -Name 'fixtures' `
    -Ok $FixtureResult.ok `
    -Required $true `
    -Detail $(if ($FixtureResult.ok) {
        "$($FixtureResult.detail) Database: $databaseName; prefix: M9-."
      } else {
        $FixtureResult.detail
      }) `
    -Remediation $(if ($FixtureResult.ok) { '' } else {
        'Inspect the sanitized fixture failure and verify the local database guard.'
      })
  if ($FixtureResult.ok) {
    foreach ($name in @(
        'products',
        'operatorUsers',
        'warehouses',
        'operatorBindings',
        'inventories',
        'nonStandardInventories',
        'documents',
        'transactions'
      )) {
      $component | Add-Member `
        -MemberType NoteProperty `
        -Name $name `
        -Value $FixtureResult.counts.$name
    }
    $component | Add-Member `
      -MemberType NoteProperty `
      -Name database `
      -Value $databaseName
    $component | Add-Member `
      -MemberType NoteProperty `
      -Name prefix `
      -Value 'M9-'
  }
  return $component
}
