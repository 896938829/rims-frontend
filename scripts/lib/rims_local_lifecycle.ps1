function New-RimsBackendLifecycleComponent {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Detail,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation,
    [Parameter(Mandatory = $true)]
    [bool]$Managed,
    [Parameter(Mandatory = $true)]
    [bool]$Healthy,
    [Parameter(Mandatory = $true)]
    [bool]$Stale,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [AllowNull()]
    [object]$ProcessId = $null,
    [bool]$CleanupPending = $false
  )

  return [pscustomobject][ordered]@{
    name = 'backend'
    ok = $Ok
    required = $true
    detail = $Detail
    remediation = $Remediation
    managed = $Managed
    healthy = $Healthy
    stale = $Stale
    cleanupPending = $CleanupPending
    port = $Port
    windowsPid = $ProcessId
  }
}

function New-RimsRuntimePathsComponent {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  return [pscustomobject][ordered]@{
    name = 'runtimePaths'
    ok = $true
    required = $false
    detail = "State: $($Paths.state); logs: $($Paths.logs)."
    remediation = ''
    runtimeRoot = $Paths.root
    statePath = $Paths.state
    stdoutLogPath = $Paths.stdoutLog
    stderrLogPath = $Paths.stderrLog
  }
}

function New-RimsBackendPortComponent {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Detail,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation
  )

  return [pscustomobject][ordered]@{
    name = 'backendPort'
    ok = $Ok
    required = $true
    detail = $Detail
    remediation = $Remediation
    port = $Port
  }
}

function Test-RimsRuntimeRequestMatchesState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendDir,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort
  )

  $stateBackend = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendPath' `
      -DefaultValue '')
  $stateWorkspace = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendWorkspaceRoot' `
      -DefaultValue '')
  $statePort = [int](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendPort' `
      -DefaultValue 0)
  return (
    (Compare-RimsPath -Left $stateBackend -Right $BackendDir) -and
    (Compare-RimsPath -Left $stateWorkspace -Right $BackendWorkspaceRoot) -and
    $statePort -eq $BackendPort
  )
}

function Resolve-RimsLifecyclePaths {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot
  )

  $backendState = Resolve-RimsBackendDirectoryState -BackendDir $BackendDir
  $workspaceState = Resolve-RimsBackendWorkspaceRootState `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -BackendDir $(if ($backendState.success) {
        $backendState.path
      } else {
        $BackendDir
      })
  return [pscustomobject][ordered]@{
    success = $backendState.success -and $workspaceState.success
    backendPath = $backendState.path
    backendError = $backendState.error
    workspacePath = $workspaceState.path
    workspaceError = $workspaceState.error
  }
}

function Invoke-RimsLocalStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'status'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  if (-not $resolved.success) {
    $detail = "Lifecycle paths are invalid: $($resolved.backendError) $($resolved.workspaceError)".Trim()
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $detail `
      -Remediation 'Pass valid -BackendDir and -BackendWorkspaceRoot paths.' `
      -Managed $false `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $dependenciesHealthy = $true
  if ($IncludeDependencies) {
    $context = Get-RimsWslLifecycleContext `
      -BackendDir $resolved.backendPath `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -RuntimePaths $paths
    $postgresStatus = if ($context.ok) {
      Get-RimsPostgresStatus -Context $context
    } else {
      [pscustomobject]@{
        ok = $false
        healthy = $false
        detail = $context.detail
      }
    }
    $dependenciesHealthy = $postgresStatus.ok -and $postgresStatus.healthy
    $result.components += New-RimsLocalComponent `
      -Name 'postgres' `
      -Ok $dependenciesHealthy `
      -Required $true `
      -Detail $postgresStatus.detail `
      -Remediation $(if ($dependenciesHealthy) { '' } else {
          'Start PostgreSQL or run up with -IncludeDependencies.'
        })
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state) {
    $occupied = Test-RimsTcpPortListening -Port $BackendPort
    $healthy = if ($occupied) {
      Test-RimsHealthEndpoint -Url "http://localhost:$BackendPort/healthz"
    } else {
      $false
    }
    $detail = if ($occupied) {
      "Port $BackendPort is occupied by an unmanaged process; it was left untouched."
    } else {
      "No managed backend state exists; port $BackendPort is not listening."
    }
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $detail `
      -Remediation $(if ($occupied) {
          'Choose a free -BackendPort or stop the user-managed process yourself.'
        } else {
          'Run the up command to start a managed backend.'
        }) `
      -Managed $false `
      -Healthy $healthy `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $matches = Test-RimsRuntimeRequestMatchesState `
    -State $state `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort
  $owned = Test-RimsStateOwnsProcess -State $state
  $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
  if (-not $matches) {
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Managed state belongs to different backend paths or port; controller-owned resources were left untouched.' `
      -Remediation 'Repeat the command with the paths and port recorded in state.json.' `
      -Managed $owned `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid') `
      -CleanupPending $cleanupPending
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  if ($cleanupPending) {
    $dependencyOwnership = Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'dependencyOwnership'
    $dependencyDetail = [string](Get-RimsObjectPropertyValue `
        -Value $dependencyOwnership `
        -Name 'cleanupFailureDetail' `
        -DefaultValue 'Controller-owned dependency cleanup remains pending.')
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $(if ($owned) {
          'Backend and dependency cleanup remain pending; exact backend ownership was preserved.'
        } else {
          'Dependency cleanup remains pending; no managed backend process is present.'
        }) `
      -Remediation 'Run down with the same backend paths and port to retry bounded cleanup.' `
      -Managed $owned `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId $(if ($owned) {
          Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
        } else {
          $null
        }) `
      -CleanupPending $true
    $result.components += New-RimsLocalComponent `
      -Name 'dependencyCleanup' `
      -Ok $false `
      -Required $true `
      -Detail (ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $dependencyDetail `
        -StandardError '') `
      -Remediation 'Restore WSL and Docker, then run down with the same parameters.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  if (-not $owned) {
    Remove-RimsRuntimeState -Paths $paths
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Stale managed state was removed; no process matched both the recorded PID and start time.' `
      -Remediation 'Run the up command to start a fresh managed backend.' `
      -Managed $false `
      -Healthy $false `
      -Stale $true `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $healthUrl = [string](Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'healthUrl' `
      -DefaultValue "http://localhost:$BackendPort/healthz")
  $healthy = Test-RimsHealthEndpoint -Url $healthUrl
  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $healthy `
    -Detail $(if ($healthy) {
        "Managed backend is healthy at $healthUrl."
      } else {
        "Managed backend process exists but is not healthy at $healthUrl."
      }) `
    -Remediation $(if ($healthy) { '' } else {
        'Inspect logs, then run restart or down without changing backend paths or port.'
      }) `
    -Managed $true `
    -Healthy $healthy `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
  $overallHealthy = $healthy -and $dependenciesHealthy
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $overallHealthy `
    -ExitCode $(if ($overallHealthy) { 0 } else { 1 })
}

function Invoke-RimsLocalLogs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $result = New-RimsLocalResult -Command 'logs'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $stdoutTail = @(Get-RimsSanitizedLogTail -Path $paths.stdoutLog)
  $stderrTail = @(Get-RimsSanitizedLogTail -Path $paths.stderrLog)
  $hasLogs = $stdoutTail.Count -gt 0 -or $stderrTail.Count -gt 0
  $component = [pscustomobject][ordered]@{
    name = 'backendLogs'
    ok = $hasLogs
    required = $false
    detail = if ($hasLogs) {
      'Returned bounded sanitized backend log tails.'
    } else {
      'No backend log output is available yet.'
    }
    remediation = if ($hasLogs) { '' } else {
      'Run up to start the managed backend and create logs.'
    }
    stdoutLogPath = $paths.stdoutLog
    stderrLogPath = $paths.stderrLog
    stdoutTail = $stdoutTail
    stderrTail = $stderrTail
  }
  $result.components = @(
    $component,
    (New-RimsRuntimePathsComponent -Paths $paths)
  )
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $true `
    -ExitCode 0
}

function Invoke-RimsDependencyCleanup {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [scriptblock]$ComposeCleanupAction
  )

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  $composeOwned = [bool](Get-RimsObjectPropertyValue `
      -Value $dependencyOwnership `
      -Name 'composeStartedByController' `
      -DefaultValue $false)
  if (-not $composeOwned) {
    return [pscustomobject][ordered]@{
      required = $false
      attempted = $false
      ok = $true
      detail = 'PostgreSQL was not started by this controller and was left untouched.'
    }
  }

  try {
    $rawResult = if ($null -eq $ComposeCleanupAction) {
      Invoke-RimsComposeDown -BackendWorkspaceRoot $BackendWorkspaceRoot
    } else {
      & $ComposeCleanupAction $BackendWorkspaceRoot
    }
    $ok = [bool](Get-RimsObjectPropertyValue `
        -Value $rawResult `
        -Name 'ok' `
        -DefaultValue $false)
    $rawDetail = [string](Get-RimsObjectPropertyValue `
        -Value $rawResult `
        -Name 'detail' `
        -DefaultValue $(if ($ok) {
            'Controller-owned dependency cleanup completed.'
          } else {
            'Controller-owned dependency cleanup failed without detail.'
          }))
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $ok
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $rawDetail `
        -StandardError ''
    }
  } catch {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function Resolve-RimsFailedLifecycleCleanup {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FailureContext,
    [AllowNull()]
    [scriptblock]$BackendCleanupAction,
    [AllowNull()]
    [scriptblock]$ComposeCleanupAction
  )

  $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $FailureContext `
    -StandardError ''
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name healthy `
    -Value $false `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name failureContext `
    -Value $sanitizedFailure `
    -Force

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  if ($null -eq $dependencyOwnership) {
    $dependencyOwnership = [pscustomobject][ordered]@{
      postgresExisted = $true
      postgresWasRunning = $true
      composeStartedByController = $false
      cleanupPending = $false
      cleanupFailureDetail = ''
    }
    $State | Add-Member `
      -MemberType NoteProperty `
      -Name dependencyOwnership `
      -Value $dependencyOwnership `
      -Force
  }
  $composeOwned = [bool](Get-RimsObjectPropertyValue `
      -Value $dependencyOwnership `
      -Name 'composeStartedByController' `
      -DefaultValue $false)
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $composeOwned `
    -Force

  try {
    Write-RimsRuntimeState -Paths $Paths -State $State
  } catch {
    # Cleanup still proceeds; pending ownership is persisted again if needed.
  }

  $backendWasOwned = Test-RimsStateOwnsProcess -State $State
  $backendCleanupOk = $true
  $backendCleanupDetail = 'No owned backend process required cleanup.'
  $backendCleanupAttempted = $false
  if ($backendWasOwned) {
    $backendCleanupAttempted = $true
    $reportedBackendCleanup = $false
    $backendActionDetail = ''
    try {
      $rawBackendCleanup = if ($null -eq $BackendCleanupAction) {
        Stop-RimsOwnedBackendProcess -State $State
      } else {
        & $BackendCleanupAction $State
      }
      $reportedBackendCleanup = [bool](Get-RimsObjectPropertyValue `
          -Value $rawBackendCleanup `
          -Name 'ok' `
          -DefaultValue $rawBackendCleanup)
      $backendActionDetail = [string](Get-RimsObjectPropertyValue `
          -Value $rawBackendCleanup `
          -Name 'detail' `
          -DefaultValue '')
    } catch {
      $reportedBackendCleanup = $false
      $backendActionDetail = $_.Exception.Message
    }
    $backendCleanupOk = -not (Test-RimsStateOwnsProcess -State $State)
    $backendCleanupDetail = if ($backendCleanupOk) {
      'The exactly owned backend process was confirmed stopped.'
    } elseif ($reportedBackendCleanup) {
      'Backend cleanup reported success, but exact process ownership remains.'
    } elseif ([string]::IsNullOrWhiteSpace($backendActionDetail)) {
      'The exactly owned backend process did not stop within the bounded cleanup.'
    } else {
      ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $backendActionDetail `
        -StandardError ''
    }
  }

  if ($backendCleanupOk) {
    foreach ($propertyName in @(
        'windowsPid',
        'windowsProcessStartTimeUtc',
        'linuxProcessGroupId'
      )) {
      $State | Add-Member `
        -MemberType NoteProperty `
        -Name $propertyName `
        -Value $null `
        -Force
    }
  }

  $dependencyCleanup = if ($backendCleanupOk) {
    Invoke-RimsDependencyCleanup `
      -State $State `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -ComposeCleanupAction $ComposeCleanupAction
  } else {
    [pscustomobject][ordered]@{
      required = $composeOwned
      attempted = $false
      ok = -not $composeOwned
      detail = if ($composeOwned) {
        'Dependency cleanup is deferred until the owned backend is confirmed stopped.'
      } else {
        'No controller-owned dependency requires cleanup.'
      }
    }
  }
  $backendCleanup = [pscustomobject][ordered]@{
    required = $backendWasOwned
    attempted = $backendCleanupAttempted
    ok = $backendCleanupOk
    detail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput $backendCleanupDetail `
      -StandardError ''
  }

  if ($backendCleanup.ok -and $dependencyCleanup.ok) {
    if ($composeOwned) {
      $dependencyOwnership | Add-Member `
        -MemberType NoteProperty `
        -Name composeStartedByController `
        -Value $false `
        -Force
    }
    try {
      Remove-RimsRuntimeState -Paths $Paths
      return [pscustomobject][ordered]@{
        ok = $true
        backendCleanup = $backendCleanup
        dependencyCleanup = $dependencyCleanup
        cleanupPending = $false
        managed = $false
        healthy = $false
        stateRetained = $false
        detail = 'All controller-owned runtime resources were cleaned up and state was removed.'
        remediation = ''
      }
    } catch {
      $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput "Cleanup completed, but runtime state removal failed: $($_.Exception.Message)" `
        -StandardError ''
    }
  }

  $dependencyStillPending = -not $dependencyCleanup.ok -and $composeOwned
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name healthy `
    -Value $false `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name failureContext `
    -Value $sanitizedFailure `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $dependencyStillPending `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupFailureDetail `
    -Value $(if ($dependencyStillPending) {
        ConvertTo-RimsDiagnosticSummary `
          -StandardOutput $dependencyCleanup.detail `
          -StandardError ''
      } else {
        ''
      }) `
    -Force

  $statePersisted = $false
  $stateWriteDetail = ''
  try {
    Write-RimsRuntimeState -Paths $Paths -State $State
    $statePersisted = $true
  } catch {
    $stateWriteDetail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
  }
  $managed = Test-RimsStateOwnsProcess -State $State
  $detail = if ($statePersisted) {
    'Cleanup remains pending; controller ownership state was retained for a bounded down retry.'
  } else {
    "Cleanup remains pending and ownership state could not be persisted: $stateWriteDetail"
  }
  return [pscustomobject][ordered]@{
    ok = $false
    backendCleanup = $backendCleanup
    dependencyCleanup = $dependencyCleanup
    cleanupPending = $true
    managed = $managed
    healthy = $false
    stateRetained = $statePersisted
    detail = $detail
    remediation = 'Run down with the same backend paths and port to retry bounded cleanup.'
  }
}

function Invoke-RimsLocalDown {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'down'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  if (-not $resolved.success) {
    $result.errors = @('Backend paths are invalid; no process was changed.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state) {
    $occupied = Test-RimsTcpPortListening -Port $BackendPort
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $true `
      -Detail $(if ($occupied) {
          "No managed state exists. The process on port $BackendPort was left untouched."
        } else {
          'No managed backend state exists; the runtime is already down.'
        }) `
      -Remediation '' `
      -Managed $false `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $true -ExitCode 0
  }

  if (-not (Test-RimsRuntimeRequestMatchesState `
      -State $state `
      -BackendDir $resolved.backendPath `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -BackendPort $BackendPort)) {
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Managed state belongs to different backend paths or port; no process was changed.' `
      -Remediation 'Repeat down with the paths and port recorded in state.json.' `
      -Managed (Test-RimsStateOwnsProcess -State $state) `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $wasOwned = Test-RimsStateOwnsProcess -State $state
  $wasCleanupPending = Test-RimsRuntimeCleanupPending -State $state
  $cleanupOutcome = Resolve-RimsFailedLifecycleCleanup `
    -Paths $paths `
    -State $state `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -FailureContext 'The down command is completing controller-owned runtime cleanup.'
  $result.components += New-RimsLocalComponent `
    -Name 'dependencyCleanup' `
    -Ok $cleanupOutcome.dependencyCleanup.ok `
    -Required $cleanupOutcome.dependencyCleanup.required `
    -Detail $cleanupOutcome.dependencyCleanup.detail `
    -Remediation $(if ($cleanupOutcome.dependencyCleanup.ok) { '' } else {
        'Restore WSL and Docker, then retry down with the same parameters.'
      })
  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $cleanupOutcome.backendCleanup.ok `
    -Detail $(if ($cleanupOutcome.ok -and $wasOwned) {
        'Stopped the exactly owned managed backend and completed runtime cleanup.'
      } elseif ($cleanupOutcome.ok -and $wasCleanupPending) {
        'Completed pending controller-owned runtime cleanup.'
      } elseif ($cleanupOutcome.ok) {
        'Removed stale runtime state without terminating any unrelated process.'
      } else {
        "$($cleanupOutcome.backendCleanup.detail) $($cleanupOutcome.detail)"
      }) `
    -Remediation $cleanupOutcome.remediation `
    -Managed $cleanupOutcome.managed `
    -Healthy $false `
    -Stale (-not $wasOwned -and -not $wasCleanupPending) `
    -Port $BackendPort `
    -ProcessId $(if ($cleanupOutcome.managed) {
        Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
      } else {
        $null
      }) `
    -CleanupPending $cleanupOutcome.cleanupPending
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $cleanupOutcome.ok `
    -ExitCode $(if ($cleanupOutcome.ok) { 0 } else { 1 })
}

function New-RimsManagedRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FrontendPath,
    [Parameter(Mandatory = $true)]
    [string]$BackendPath,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [psobject]$StartedBackend,
    [Parameter(Mandatory = $true)]
    [bool]$PostgresExisted,
    [Parameter(Mandatory = $true)]
    [bool]$PostgresWasRunning,
    [Parameter(Mandatory = $true)]
    [bool]$ComposeStartedByController,
    [bool]$Healthy = $true,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FailureContext = ''
  )

  $runtimeCommit = Get-RimsGitCommit -Path $FrontendPath
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    frontendPath = $FrontendPath
    backendPath = $BackendPath
    backendWorkspaceRoot = $BackendWorkspaceRoot
    frontendCommit = $runtimeCommit
    runtimeCommit = $runtimeCommit
    backendCommit = Get-RimsGitCommit -Path $BackendPath
    target = $Target
    backendPort = $BackendPort
    frontendPort = $FrontendPort
    startedAt = Get-RimsLocalTimestamp
    healthUrl = $StartedBackend.healthUrl
    healthy = $Healthy
    cleanupPending = $false
    failureContext = if ([string]::IsNullOrWhiteSpace($FailureContext)) {
      ''
    } else {
      ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $FailureContext `
        -StandardError ''
    }
    windowsPid = $StartedBackend.windowsPid
    windowsProcessStartTimeUtc = $StartedBackend.windowsProcessStartTimeUtc
    linuxProcessGroupId = $StartedBackend.linuxProcessGroupId
    runtimeRoot = $RuntimePaths.root
    statePath = $RuntimePaths.state
    stdoutLogPath = $RuntimePaths.stdoutLog
    stderrLogPath = $RuntimePaths.stderrLog
    commandSummary = "wsl.exe managed go run ./cmd/server with APP_PORT=$BackendPort"
    dependencyOwnership = [pscustomobject][ordered]@{
      postgresExisted = $PostgresExisted
      postgresWasRunning = $PostgresWasRunning
      composeStartedByController = $ComposeStartedByController
      cleanupPending = $false
      cleanupFailureDetail = ''
    }
  }
}

function Complete-RimsFailedUpResult {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result,
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FailureContext,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation
  )

  $cleanupOutcome = Resolve-RimsFailedLifecycleCleanup `
    -Paths $Paths `
    -State $State `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -FailureContext $FailureContext
  $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $FailureContext `
    -StandardError ''
  $Result.components += New-RimsLocalComponent `
    -Name 'dependencyCleanup' `
    -Ok $cleanupOutcome.dependencyCleanup.ok `
    -Required $cleanupOutcome.dependencyCleanup.required `
    -Detail $cleanupOutcome.dependencyCleanup.detail `
    -Remediation $(if ($cleanupOutcome.dependencyCleanup.ok) { '' } else {
        'Restore WSL and Docker, then run down with the same parameters.'
      })
  $Result.components += New-RimsBackendLifecycleComponent `
    -Ok $false `
    -Detail "$sanitizedFailure $($cleanupOutcome.detail)" `
    -Remediation $(if ($cleanupOutcome.cleanupPending) {
        $cleanupOutcome.remediation
      } else {
        $Remediation
      }) `
    -Managed $cleanupOutcome.managed `
    -Healthy $false `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId $(if ($cleanupOutcome.managed) {
        Get-RimsObjectPropertyValue -Value $State -Name 'windowsPid'
      } else {
        $null
      }) `
    -CleanupPending $cleanupOutcome.cleanupPending
  return Complete-RimsLocalResult -Result $Result -Ok $false -ExitCode 1
}

function Invoke-RimsLocalUp {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'up'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot

  $doctorComponents = @(Invoke-RimsLocalDoctor `
      -Target $Target `
      -BackendDir $BackendDir `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -AndroidDevice $AndroidDevice `
      -ScriptDirectory $ScriptDirectory)
  $result.components += $doctorComponents
  $failedDoctor = @($doctorComponents | Where-Object {
      $_.required -and -not $_.ok
    })
  if (-not $resolved.success -or $failedDoctor.Count -gt 0) {
    $result.errors = @('Required local runtime checks failed; no process was started.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -ne $state) {
    $owned = Test-RimsStateOwnsProcess -State $state
    $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
    if ($cleanupPending) {
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'Controller-owned cleanup is pending; up will not discard or replace its ownership state.' `
        -Remediation 'Run down with the paths and port recorded in state.json before retrying up.' `
        -Managed $owned `
        -Healthy $false `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId $(if ($owned) {
            Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
          } else {
            $null
          }) `
        -CleanupPending $true
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    } elseif (-not $owned) {
      Remove-RimsRuntimeState -Paths $paths
      $state = $null
    } elseif (-not (Test-RimsRuntimeRequestMatchesState `
        -State $state `
        -BackendDir $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -BackendPort $BackendPort)) {
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'An owned backend is already managed with different paths or port.' `
        -Remediation 'Run down with the values recorded in state.json before changing lifecycle parameters.' `
        -Managed $true `
        -Healthy $false `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    } else {
      $healthUrl = [string](Get-RimsObjectPropertyValue `
          -Value $state `
          -Name 'healthUrl' `
          -DefaultValue "http://localhost:$BackendPort/healthz")
      $healthy = Test-RimsHealthEndpoint -Url $healthUrl
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $healthy `
        -Detail $(if ($healthy) {
            "The already-owned backend is healthy at $healthUrl; no process was started."
          } else {
            'The owned backend process exists but is unhealthy; up will not replace it implicitly.'
          }) `
        -Remediation $(if ($healthy) { '' } else {
            'Inspect logs and run restart or down with the same parameters.'
          }) `
        -Managed $true `
        -Healthy $healthy `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
      return Complete-RimsLocalResult `
        -Result $result `
        -Ok $healthy `
        -ExitCode $(if ($healthy) { 0 } else { 1 })
    }
  }

  if (Test-RimsTcpPortListening -Port $BackendPort) {
    $result.components += New-RimsBackendPortComponent `
      -Ok $false `
      -Port $BackendPort `
      -Detail "Port $BackendPort is occupied without matching managed state; the listener was left untouched." `
      -Remediation 'Choose a free -BackendPort or stop the user-managed process yourself.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
  $result.components += New-RimsBackendPortComponent `
    -Ok $true `
    -Port $BackendPort `
    -Detail "Port $BackendPort is available for the managed backend." `
    -Remediation ''

  $frontendPath = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  Initialize-RimsRuntimeDirectories -Paths $paths
  $context = Get-RimsWslLifecycleContext `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -RuntimePaths $paths
  if (-not $context.ok) {
    $result.errors = @("Could not prepare WSL lifecycle paths: $($context.detail)")
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $postgresBefore = Get-RimsPostgresStatus -Context $context
  if (-not $postgresBefore.ok) {
    $result.components += New-RimsLocalComponent `
      -Name 'postgres' `
      -Ok $false `
      -Required $true `
      -Detail "Could not inspect PostgreSQL: $($postgresBefore.detail)" `
      -Remediation 'Start Docker Desktop and verify the configured Compose project.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
  $postgresOwnership = Get-RimsPostgresDependencyOwnership `
    -Status $postgresBefore
  $postgresExisted = $postgresOwnership.postgresExisted
  $postgresWasRunning = $postgresOwnership.postgresWasRunning
  $composeStarted = $postgresOwnership.composeStartedByController
  $notStartedBackend = [pscustomobject][ordered]@{
    healthUrl = "http://localhost:$BackendPort/healthz"
    windowsPid = $null
    windowsProcessStartTimeUtc = $null
    linuxProcessGroupId = $null
  }
  $failedLifecycleState = New-RimsManagedRuntimeState `
    -FrontendPath $frontendPath `
    -BackendPath $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -Target $Target `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -RuntimePaths $paths `
    -StartedBackend $notStartedBackend `
    -PostgresExisted $postgresExisted `
    -PostgresWasRunning $postgresWasRunning `
    -ComposeStartedByController $composeStarted `
    -Healthy $false `
    -FailureContext 'Backend startup did not complete.'
  if (-not $postgresBefore.healthy) {
    if (-not $IncludeDependencies) {
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail "PostgreSQL is not healthy ($($postgresBefore.status))." `
        -Remediation 'Run up with -IncludeDependencies or start PostgreSQL yourself.'
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    }
    $composeUp = Invoke-RimsComposeUpPostgres -Context $context
    if (-not $composeUp.ok) {
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail $composeUp.detail `
        -Remediation 'Repair Docker Compose, then retry up with -IncludeDependencies.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $composeUp.detail `
        -BackendPort $BackendPort `
        -Remediation 'Repair Docker Compose, then retry up with -IncludeDependencies.'
    }
    $postgresReady = Wait-RimsPostgresHealthy -Context $context
    if ($null -eq $postgresReady -or -not $postgresReady.healthy) {
      $readinessFailure = if ($composeStarted) {
        'Controller-started PostgreSQL did not become healthy within 90 seconds.'
      } else {
        'Pre-existing PostgreSQL did not become healthy within 90 seconds and remains user-managed.'
      }
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail $readinessFailure `
        -Remediation 'Inspect Docker Compose logs and retry after PostgreSQL is healthy.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $readinessFailure `
        -BackendPort $BackendPort `
        -Remediation 'Inspect Docker Compose logs and retry after PostgreSQL is healthy.'
    }
  }
  $result.components += New-RimsLocalComponent `
    -Name 'postgres' `
    -Ok $true `
    -Required $true `
    -Detail $(if ($postgresBefore.healthy) {
        'PostgreSQL was already healthy and remains user-managed.'
      } elseif ($postgresExisted) {
        'Pre-existing PostgreSQL was repaired and remains user-managed.'
      } else {
        'PostgreSQL was started by this controller and is healthy.'
      }) `
    -Remediation ''

  $migration = Invoke-RimsBackendMigrations -Context $context
  $result.components += New-RimsLocalComponent `
    -Name 'migrations' `
    -Ok $migration.ok `
    -Required $true `
    -Detail $migration.detail `
    -Remediation $(if ($migration.ok) { '' } else {
        'Inspect the sanitized migration error and verify database configuration.'
      })
  if (-not $migration.ok) {
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $failedLifecycleState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext $migration.detail `
      -BackendPort $BackendPort `
      -Remediation 'Inspect the sanitized migration error and verify database configuration.'
  }

  $started = Start-RimsManagedBackend `
    -Context $context `
    -RuntimePaths $paths `
    -BackendPort $BackendPort
  if (-not $started.ok) {
    $failedState = if ($started.processStarted) {
      New-RimsManagedRuntimeState `
        -FrontendPath $frontendPath `
        -BackendPath $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -Target $Target `
        -BackendPort $BackendPort `
        -FrontendPort $FrontendPort `
        -RuntimePaths $paths `
        -StartedBackend $started `
        -PostgresExisted $postgresExisted `
        -PostgresWasRunning $postgresWasRunning `
        -ComposeStartedByController $composeStarted `
        -Healthy $false `
        -FailureContext $started.detail
    } else {
      $failedLifecycleState
    }
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $failedState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext $started.detail `
      -BackendPort $BackendPort `
      -Remediation 'Inspect the sanitized backend stderr tail, correct the failure, and retry up.'
  }

  $newState = New-RimsManagedRuntimeState `
    -FrontendPath $frontendPath `
    -BackendPath $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -Target $Target `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -RuntimePaths $paths `
    -StartedBackend $started `
    -PostgresExisted $postgresExisted `
    -PostgresWasRunning $postgresWasRunning `
    -ComposeStartedByController $composeStarted `
    -Healthy $true
  try {
    Write-RimsRuntimeState -Paths $paths -State $newState
  } catch {
    $summary = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    $result.errors = @("Could not persist managed ownership state: $summary")
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $newState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext "Could not persist managed ownership state: $summary" `
      -BackendPort $BackendPort `
      -Remediation 'Restore runtime directory write access, then retry up.'
  }

  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $true `
    -Detail $started.detail `
    -Remediation '' `
    -Managed $true `
    -Healthy $true `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId $started.windowsPid
  return Complete-RimsLocalResult -Result $result -Ok $true -ExitCode 0
}

function Invoke-RimsLocalRestart {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'restart'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state -or
      -not $resolved.success -or
      -not (Test-RimsStateOwnsProcess -State $state) -or
      -not (Test-RimsRuntimeRequestMatchesState `
        -State $state `
        -BackendDir $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -BackendPort $BackendPort)) {
    if ($null -ne $state -and
        -not (Test-RimsStateOwnsProcess -State $state) -and
        -not (Test-RimsRuntimeCleanupPending -State $state)) {
      Remove-RimsRuntimeState -Paths $paths
    }
    $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
    $result.components = @(
      (New-RimsRuntimePathsComponent -Paths $paths),
      (New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'Restart requires an exactly owned backend matching the requested paths and port.' `
        -Remediation 'Use status, then start with up or repeat restart using state.json values.' `
        -Managed $false `
        -Healthy $false `
        -Stale ($null -ne $state) `
        -Port $BackendPort `
        -CleanupPending $cleanupPending)
    )
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $down = Invoke-RimsLocalDown `
    -ScriptDirectory $ScriptDirectory `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort `
    -IncludeDependencies:$IncludeDependencies
  if (-not $down.ok) {
    $result.components = @($down.components)
    $result.errors = @($down.errors)
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode $down.exitCode
  }

  $up = Invoke-RimsLocalUp `
    -Target $Target `
    -ScriptDirectory $ScriptDirectory `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -AndroidDevice $AndroidDevice `
    -IncludeDependencies:$IncludeDependencies
  $result.components = @($up.components)
  $result.errors = @($up.errors)
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $up.ok `
    -ExitCode $up.exitCode
}

function Write-RimsLifecycleText {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  foreach ($component in @($Result.components)) {
    $status = if ($component.ok) { 'PASS' } else { 'FAIL' }
    [Console]::Out.WriteLine(
      "[$status] $($component.name) - $($component.detail)"
    )
    if (-not $component.ok -and
        -not [string]::IsNullOrWhiteSpace([string]$component.remediation)) {
      [Console]::Out.WriteLine(
        "       Remediation: $($component.remediation)"
      )
    }
  }
  foreach ($message in @($Result.errors)) {
    [Console]::Out.WriteLine("[FAIL] $($Result.command) - $message")
  }
}

function Write-RimsLogsText {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  $logs = @($Result.components | Where-Object {
      $_.name -eq 'backendLogs'
    }) | Select-Object -First 1
  if ($null -eq $logs) {
    Write-RimsLifecycleText -Result $Result
    return
  }
  [Console]::Out.WriteLine("Backend stdout ($($logs.stdoutLogPath)):")
  foreach ($line in @($logs.stdoutTail)) {
    [Console]::Out.WriteLine($line)
  }
  [Console]::Out.WriteLine("Backend stderr ($($logs.stderrLogPath)):")
  foreach ($line in @($logs.stderrTail)) {
    [Console]::Out.WriteLine($line)
  }
}
