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

function Get-RimsComposeResourceContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'wsl.exe is unavailable.'
    }
  }
  try {
    $workspaceWindows = [IO.Path]::GetFullPath($BackendWorkspaceRoot)
    $environmentWindows = [IO.Path]::GetFullPath(
      (Join-Path $workspaceWindows '.env')
    )
    $composeWindows = [IO.Path]::GetFullPath(
      (Join-Path $workspaceWindows 'deploy\docker-compose.yml')
    )
    return [pscustomobject][ordered]@{
      ok = $true
      detail = ''
      wsl = $wsl
      workspaceWindows = $workspaceWindows
      environmentWindows = $environmentWindows
      composeWindows = $composeWindows
      workspace = ConvertTo-RimsWslPath `
        -WindowsPath $workspaceWindows `
        -WslExecutable $wsl
      environment = ConvertTo-RimsWslPath `
        -WindowsPath $environmentWindows `
        -WslExecutable $wsl
      compose = ConvertTo-RimsWslPath `
        -WindowsPath $composeWindows `
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
}

function Get-RimsPostgresResourceIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [Parameter(Mandatory = $true)]
    [string]$ContainerId
  )

  $labelsResult = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(
      '-e',
      'docker',
      'inspect',
      '--format',
      '{{json .Config.Labels}}',
      $ContainerId
    ) `
    -TimeoutSeconds 20
  if ($labelsResult.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = "Could not inspect postgres ownership labels: $(Get-RimsExternalCommandSummary -Result $labelsResult)"
    }
  }
  try {
    $labels = $labelsResult.StandardOutput | ConvertFrom-Json -ErrorAction Stop
    $projectName = [string](Get-RimsObjectPropertyValue `
        -Value $labels `
        -Name 'com.docker.compose.project' `
        -DefaultValue '')
    $serviceHash = [string](Get-RimsObjectPropertyValue `
        -Value $labels `
        -Name 'com.docker.compose.config-hash' `
        -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($projectName) -or
        [string]::IsNullOrWhiteSpace($serviceHash)) {
      throw 'Required Docker Compose ownership labels are missing.'
    }
    return [pscustomobject][ordered]@{
      ok = $true
      detail = 'Resolved exact postgres Compose resource identity.'
      identity = [pscustomobject][ordered]@{
        containerId = $ContainerId.Trim()
        composeProjectName = $projectName
        composeConfigPath = [IO.Path]::GetFullPath(
          [string]$Context.composeWindows
        )
        composeConfigHash = Get-RimsFileSha256 `
          -Path ([string]$Context.composeWindows)
        serviceConfigHash = $serviceHash
      }
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function Get-RimsCurrentPostgresResourceIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [object]$StoredIdentity
  )

  $context = Get-RimsComposeResourceContext `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  if (-not $context.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $false
      identity = $null
      detail = $context.detail
    }
  }
  $status = Get-RimsPostgresStatus -Context $context
  if (-not $status.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $status.exists
      identity = $null
      detail = $status.detail
    }
  }
  if ($null -ne $StoredIdentity) {
    $storedContainerId = [string](Get-RimsObjectPropertyValue `
        -Value $StoredIdentity `
        -Name 'containerId' `
        -DefaultValue '')
    $storedInspection = Invoke-RimsExternalCommand `
      -FilePath $context.wsl `
      -Arguments @(
        '-e',
        'docker',
        'inspect',
        '--format',
        '{{.Id}}',
        $storedContainerId
      ) `
      -TimeoutSeconds 20
    if ($storedInspection.ExitCode -ne 0) {
      return [pscustomobject][ordered]@{
        ok = $true
        exists = $false
        identity = $null
        detail = 'The exact stored postgres container is absent.'
      }
    }
    if (-not $status.exists) {
      return [pscustomobject][ordered]@{
        ok = $false
        exists = $true
        identity = $null
        detail = 'The stored postgres container still exists but the current Compose project does not resolve it.'
      }
    }
  }
  if (-not $status.exists) {
    return [pscustomobject][ordered]@{
      ok = $true
      exists = $false
      identity = $null
      detail = 'Postgres container is absent.'
    }
  }
  $identity = Get-RimsPostgresResourceIdentity `
    -Context $context `
    -ContainerId $status.containerId
  return [pscustomobject][ordered]@{
    ok = $identity.ok
    exists = $true
    identity = if ($identity.ok) { $identity.identity } else { $null }
    detail = $identity.detail
  }
}

function Invoke-RimsRemoveExactContainer {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContainerId
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'wsl.exe is unavailable, so the exact postgres container could not be stopped.'
    }
  }
  $stop = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @('-e', 'docker', 'stop', '--time', '10', $ContainerId) `
    -TimeoutSeconds 20
  if ($stop.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = "Could not stop the exact postgres container: $(Get-RimsExternalCommandSummary -Result $stop)"
    }
  }
  $remove = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @('-e', 'docker', 'rm', $ContainerId) `
    -TimeoutSeconds 20
  return [pscustomobject][ordered]@{
    ok = $remove.ExitCode -eq 0
    detail = if ($remove.ExitCode -eq 0) {
      'Stopped and removed only the exact controller-created postgres container.'
    } else {
      "Could not remove the exact postgres container: $(Get-RimsExternalCommandSummary -Result $remove)"
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

function Test-RimsPostgresResourceIdentity {
  param(
    [AllowNull()]
    [object]$Stored,
    [AllowNull()]
    [object]$Current
  )

  if ($null -eq $Stored -or $null -eq $Current) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'Stored or current postgres resource identity is missing.'
    }
  }
  $properties = @(
    [pscustomobject]@{ name = 'containerId'; path = $false },
    [pscustomobject]@{ name = 'composeProjectName'; path = $false },
    [pscustomobject]@{ name = 'composeConfigPath'; path = $true },
    [pscustomobject]@{ name = 'composeConfigHash'; path = $false },
    [pscustomobject]@{ name = 'serviceConfigHash'; path = $false }
  )
  foreach ($property in $properties) {
    $storedValue = [string](Get-RimsObjectPropertyValue `
        -Value $Stored `
        -Name $property.name `
        -DefaultValue '')
    $currentValue = [string](Get-RimsObjectPropertyValue `
        -Value $Current `
        -Name $property.name `
        -DefaultValue '')
    $matches = if ($property.path) {
      Compare-RimsPath -Left $storedValue -Right $currentValue
    } else {
      -not [string]::IsNullOrWhiteSpace($storedValue) -and
        $storedValue.Equals(
          $currentValue,
          [StringComparison]::OrdinalIgnoreCase
        )
    }
    if (-not $matches) {
      return [pscustomobject][ordered]@{
        ok = $false
        detail = "Postgres resource identity mismatch: $($property.name)."
      }
    }
  }
  return [pscustomobject][ordered]@{
    ok = $true
    detail = 'Postgres resource identity exactly matches controller state.'
  }
}

function Invoke-RimsOwnedPostgresCleanup {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [scriptblock]$CurrentIdentityAction,
    [AllowNull()]
    [scriptblock]$RemoveContainerAction
  )

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  $storedIdentity = Get-RimsObjectPropertyValue `
    -Value $dependencyOwnership `
    -Name 'postgresResource'
  try {
    $current = if ($null -eq $CurrentIdentityAction) {
      Get-RimsCurrentPostgresResourceIdentity `
        -BackendWorkspaceRoot $BackendWorkspaceRoot `
        -StoredIdentity $storedIdentity
    } else {
      & $CurrentIdentityAction $BackendWorkspaceRoot $storedIdentity
    }
  } catch {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $false
      ok = $false
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $current `
      -Name 'ok' `
      -DefaultValue $false)) {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $false
      ok = $false
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput ([string](Get-RimsObjectPropertyValue `
            -Value $current `
            -Name 'detail' `
            -DefaultValue 'Could not inspect current postgres identity.')) `
        -StandardError ''
    }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $current `
      -Name 'exists' `
      -DefaultValue $false)) {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $false
      ok = $true
      cleanupPending = $false
      detail = 'Controller-created postgres container is already absent.'
    }
  }
  if ($null -eq $storedIdentity) {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $false
      ok = $false
      cleanupPending = $true
      detail = 'Controller-owned postgres identity is missing; cleanup was refused.'
    }
  }

  $identityMatch = Test-RimsPostgresResourceIdentity `
    -Stored $storedIdentity `
    -Current (Get-RimsObjectPropertyValue `
      -Value $current `
      -Name 'identity')
  if (-not $identityMatch.ok) {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $false
      ok = $false
      cleanupPending = $true
      detail = $identityMatch.detail
    }
  }

  $containerId = [string](Get-RimsObjectPropertyValue `
      -Value $storedIdentity `
      -Name 'containerId' `
      -DefaultValue '')
  try {
    $removed = if ($null -eq $RemoveContainerAction) {
      Invoke-RimsRemoveExactContainer -ContainerId $containerId
    } else {
      & $RemoveContainerAction $containerId
    }
    $ok = [bool](Get-RimsObjectPropertyValue `
        -Value $removed `
        -Name 'ok' `
        -DefaultValue $false)
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $ok
      cleanupPending = -not $ok
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput ([string](Get-RimsObjectPropertyValue `
            -Value $removed `
            -Name 'detail' `
            -DefaultValue 'Exact postgres container cleanup returned no detail.')) `
        -StandardError ''
    }
  } catch {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $false
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}
