function Get-RimsRuntimePaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  $runtimeRoot = $env:RIMS_RUNTIME_DIR
  if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
    $runtimeRoot = Join-Path $repositoryRoot '.runtime\rims-local'
  }
  $rootResolution = Resolve-RimsNormalizedPath -Path $runtimeRoot
  if (-not $rootResolution.success) {
    throw "Runtime root is invalid: $($rootResolution.error)"
  }

  $logDirectory = Join-Path $rootResolution.path 'logs'
  return [pscustomobject][ordered]@{
    root = $rootResolution.path
    state = Join-Path $rootResolution.path 'state.json'
    logs = $logDirectory
    stdoutLog = Join-Path $logDirectory 'backend.stdout.log'
    stderrLog = Join-Path $logDirectory 'backend.stderr.log'
    linuxProcessGroup = Join-Path $rootResolution.path 'backend.pgid'
  }
}

function Initialize-RimsRuntimeDirectories {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  [void][IO.Directory]::CreateDirectory([string]$Paths.root)
  [void][IO.Directory]::CreateDirectory([string]$Paths.logs)
}

function Write-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  Initialize-RimsRuntimeDirectories -Paths $Paths
  $temporaryPath = ([string]$Paths.state) + '.tmp'
  $backupPath = ([string]$Paths.state) + '.previous'
  $json = $State | ConvertTo-Json -Depth 10
  try {
    [IO.File]::WriteAllText(
      $temporaryPath,
      $json,
      (New-Object Text.UTF8Encoding($false))
    )
    if (Test-Path -LiteralPath $Paths.state -PathType Leaf) {
      [IO.File]::Replace(
        $temporaryPath,
        [string]$Paths.state,
        $backupPath,
        $true
      )
      [IO.File]::Delete($backupPath)
    } else {
      [IO.File]::Move($temporaryPath, [string]$Paths.state)
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      [IO.File]::Delete($temporaryPath)
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      [IO.File]::Delete($backupPath)
    }
  }
}

function Move-RimsInvalidRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.state -PathType Leaf)) {
    return $null
  }
  for ($offset = 0; $offset -lt 60; $offset++) {
    $timestamp = [DateTime]::UtcNow.AddSeconds($offset).ToString(
      'yyyyMMddTHHmmssZ',
      [Globalization.CultureInfo]::InvariantCulture
    )
    $destination = Join-Path $Paths.root "state.invalid.$timestamp.json"
    if (-not (Test-Path -LiteralPath $destination)) {
      [IO.File]::Move([string]$Paths.state, $destination)
      return $destination
    }
  }
  throw 'Could not allocate a quarantine path for invalid runtime state.'
}

function Read-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.state -PathType Leaf)) {
    return $null
  }
  try {
    $state = [IO.File]::ReadAllText([string]$Paths.state) |
      ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or
        (Get-RimsObjectPropertyValue `
          -Value $state `
          -Name 'schemaVersion') -ne 1) {
      throw 'Unsupported or missing runtime state schemaVersion.'
    }
    return $state
  } catch {
    [void](Move-RimsInvalidRuntimeState -Paths $Paths)
    return $null
  }
}

function Remove-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  foreach ($path in @(
      [string]$Paths.state,
      ([string]$Paths.state) + '.tmp',
      ([string]$Paths.state) + '.previous',
      [string]$Paths.linuxProcessGroup
    )) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [IO.File]::Delete($path)
    }
  }
}

function Test-RimsRuntimeCleanupPending {
  param(
    [AllowNull()]
    [object]$State
  )

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  return (
    [bool](Get-RimsObjectPropertyValue `
        -Value $State `
        -Name 'cleanupPending' `
        -DefaultValue $false) -or
    [bool](Get-RimsObjectPropertyValue `
        -Value $dependencyOwnership `
        -Name 'cleanupPending' `
        -DefaultValue $false)
  )
}
