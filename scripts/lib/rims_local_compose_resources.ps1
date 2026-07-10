function Get-RimsComposeArguments {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Arguments
  )

  return @(
    '-e',
    'docker',
    'compose',
    '--project-directory',
    [string]$Context.workspace,
    '--env-file',
    [string]$Context.environment,
    '-f',
    [string]$Context.compose
  ) + $Arguments
}

function Get-RimsPostgresDiscoveryArguments {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  return @(Get-RimsComposeArguments `
      -Context $Context `
      -Arguments @('ps', '-a', '-q', 'postgres'))
}

function Invoke-RimsComposeDown {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'wsl.exe is unavailable, so owned Compose services could not be stopped.'
    }
  }
  try {
    $context = [pscustomobject][ordered]@{
      workspace = ConvertTo-RimsWslPath `
        -WindowsPath $BackendWorkspaceRoot `
        -WslExecutable $wsl
      environment = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot '.env') `
        -WslExecutable $wsl
      compose = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot 'deploy\docker-compose.yml') `
        -WslExecutable $wsl
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  $command = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(Get-RimsComposeArguments `
      -Context $context `
      -Arguments @('down')) `
    -TimeoutSeconds 60
  return [pscustomobject][ordered]@{
    ok = $command.ExitCode -eq 0
    detail = if ($command.ExitCode -eq 0) {
      'Stopped controller-owned Compose services without deleting volumes.'
    } else {
      "Could not stop controller-owned Compose services: $(Get-RimsExternalCommandSummary -Result $command)"
    }
  }
}

function ConvertTo-RimsPostgresStatus {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ContainerId,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$StateStatus,
    [Parameter(Mandatory = $true)]
    [bool]$Running,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$HealthStatus
  )

  $exists = -not [string]::IsNullOrWhiteSpace($ContainerId)
  $normalizedState = ([string]$StateStatus).Trim().ToLowerInvariant()
  $normalizedHealth = ([string]$HealthStatus).Trim().ToLowerInvariant()
  $status = if (-not $exists) {
    'absent'
  } elseif (-not $Running -and $normalizedState.Length -gt 0) {
    $normalizedState
  } elseif ($normalizedHealth.Length -gt 0) {
    $normalizedHealth
  } elseif ($normalizedState.Length -gt 0) {
    $normalizedState
  } else {
    'unknown'
  }
  $healthy = $exists -and $Running -and $normalizedHealth -eq 'healthy'
  return [pscustomobject][ordered]@{
    ok = $true
    exists = $exists
    running = $exists -and $Running
    healthy = $healthy
    containerId = if ($exists) { $ContainerId.Trim() } else { $null }
    status = $status
    detail = "PostgreSQL container status: $status."
  }
}

function Get-RimsPostgresDependencyOwnership {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Status
  )

  $controllerOwned = -not [bool]$Status.exists
  return [pscustomobject][ordered]@{
    postgresExisted = [bool]$Status.exists
    postgresWasRunning = [bool]$Status.running
    composeStartedByController = $controllerOwned
    cleanupComposeOnFailure = $controllerOwned
    stopComposeOnDown = $controllerOwned
  }
}

function Get-RimsPostgresStatus {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $check = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(Get-RimsPostgresDiscoveryArguments -Context $Context) `
    -TimeoutSeconds 20
  if ($check.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $false
      running = $false
      healthy = $false
      containerId = $null
      status = 'unknown'
      detail = Get-RimsExternalCommandSummary -Result $check
    }
  }
  $containerId = $check.StandardOutput.Trim()
  if ([string]::IsNullOrWhiteSpace($containerId)) {
    return ConvertTo-RimsPostgresStatus `
      -ContainerId '' `
      -StateStatus '' `
      -Running $false `
      -HealthStatus ''
  }
  $inspect = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(
      '-e',
      'docker',
      'inspect',
      '--format',
      '{{json .State}}',
      $containerId
    ) `
    -TimeoutSeconds 20
  if ($inspect.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      running = $false
      healthy = $false
      containerId = $containerId
      status = 'unknown'
      detail = Get-RimsExternalCommandSummary -Result $inspect
    }
  }
  try {
    $containerState = $inspect.StandardOutput |
      ConvertFrom-Json -ErrorAction Stop
    $health = Get-RimsObjectPropertyValue `
      -Value $containerState `
      -Name 'Health'
    return ConvertTo-RimsPostgresStatus `
      -ContainerId $containerId `
      -StateStatus ([string](Get-RimsObjectPropertyValue `
          -Value $containerState `
          -Name 'Status' `
          -DefaultValue 'unknown')) `
      -Running ([bool](Get-RimsObjectPropertyValue `
          -Value $containerState `
          -Name 'Running' `
          -DefaultValue $false)) `
      -HealthStatus ([string](Get-RimsObjectPropertyValue `
          -Value $health `
          -Name 'Status' `
          -DefaultValue ''))
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      running = $false
      healthy = $false
      containerId = $containerId
      status = 'unknown'
      detail = 'Docker returned malformed PostgreSQL state.'
    }
  }
}

function Invoke-RimsComposeUpPostgres {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $command = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(Get-RimsComposeArguments `
      -Context $Context `
      -Arguments @('up', '-d', 'postgres')) `
    -TimeoutSeconds 120
  return [pscustomobject][ordered]@{
    ok = $command.ExitCode -eq 0
    detail = if ($command.ExitCode -eq 0) {
      'Started PostgreSQL with Docker Compose.'
    } else {
      "Docker Compose could not start PostgreSQL: $(Get-RimsExternalCommandSummary -Result $command)"
    }
  }
}

function Wait-RimsPostgresHealthy {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = $null
  do {
    $lastStatus = Get-RimsPostgresStatus -Context $Context
    if ($lastStatus.ok -and $lastStatus.healthy) {
      return $lastStatus
    }
    Start-Sleep -Milliseconds 1000
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}
