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

function Get-RimsFrontendRequestCompatibility {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice
  )

  $currentTarget = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'target' `
      -DefaultValue 'none')
  $frontend = Get-RimsObjectPropertyValue -Value $State -Name 'frontend'
  $emulator = Get-RimsObjectPropertyValue -Value $State -Name 'emulator'
  $hasRecordedResources = $null -ne $frontend -or $null -ne $emulator
  if ($Target -eq 'none') {
    $matches = $currentTarget -eq 'none' -and -not $hasRecordedResources
    return [pscustomobject][ordered]@{
      matches = $matches
      hasRecordedResources = $hasRecordedResources
      detail = if ($matches) {
        'Requested backend-only mode matches the recorded frontend state.'
      } else {
        "Requested backend-only mode conflicts with recorded frontend target '$currentTarget'."
      }
    }
  }
  if ($currentTarget -ne $Target) {
    return [pscustomobject][ordered]@{
      matches = $false
      hasRecordedResources = $hasRecordedResources
      detail = "Managed frontend target '$currentTarget' differs from requested '$Target'."
    }
  }
  if ($Target -eq 'web') {
    $recordedPort = [int](Get-RimsObjectPropertyValue `
        -Value $State `
        -Name 'frontendPort' `
        -DefaultValue 0)
    $matches = $recordedPort -eq $FrontendPort
    return [pscustomobject][ordered]@{
      matches = $matches
      hasRecordedResources = $hasRecordedResources
      detail = if ($matches) {
        'Requested Web frontend port matches the recorded state.'
      } else {
        "Managed Web frontend port '$recordedPort' differs from requested '$FrontendPort'."
      }
    }
  }
  $requestedAvd = if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
    'Medium_Phone_API_36.1'
  } else {
    $AndroidDevice
  }
  $recordedAvd = [string](Get-RimsObjectPropertyValue `
      -Value $emulator `
      -Name 'avdName' `
      -DefaultValue '')
  $matches = -not [string]::IsNullOrWhiteSpace($recordedAvd) -and
    $recordedAvd -ceq $requestedAvd
  return [pscustomobject][ordered]@{
    matches = $matches
    hasRecordedResources = $hasRecordedResources
    detail = if ($matches) {
      'Requested Android AVD matches the recorded state.'
    } else {
      "Managed Android AVD '$recordedAvd' differs from requested '$requestedAvd'."
    }
  }
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

function Invoke-RimsLocalStatusUnlocked {
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
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
    if ($UseLocalTls) {
      $result.components += New-RimsLocalTlsComponent `
        -State $null `
        -TlsPaths (Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory) `
        -Required $true
    }
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $matches = Test-RimsRuntimeRequestMatchesState `
    -State $state `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort
  $owned = Test-RimsStateOwnsAnyBackendProcess -State $state
  $cleanupPending = Test-RimsAnyRuntimeCleanupPending -State $state
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
          'Controller-owned cleanup remains pending; exact backend ownership was preserved.'
        } else {
          'Controller-owned cleanup remains pending; no managed backend process is present.'
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
    $stateFrontendPort = [int](Get-RimsObjectPropertyValue `
        -Value $state `
        -Name 'frontendPort' `
        -DefaultValue 8091)
    $result.components += Get-RimsFrontendComponent `
      -State $state `
      -FrontendPort $stateFrontendPort
    $emulatorComponent = Get-RimsEmulatorComponent -State $state
    if ($null -ne $emulatorComponent) {
      $result.components += $emulatorComponent
    }
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
    if (Test-RimsStateOwnsAnyFrontendProcess -State $state) {
      $state.cleanupPending = $true
      Write-RimsRuntimeState -Paths $paths -State $state
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'Managed backend is stale while exactly owned frontend resources remain; state was retained.' `
        -Remediation 'Run down with the recorded paths and port to clean up exact owned resources.' `
        -Managed $false `
        -Healthy $false `
        -Stale $true `
        -Port $BackendPort `
        -CleanupPending $true
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    }
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
  $stateFrontendPort = [int](Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'frontendPort' `
      -DefaultValue 8091)
  $frontendComponent = Get-RimsFrontendComponent `
    -State $state `
    -FrontendPort $stateFrontendPort
  $result.components += $frontendComponent
  $emulatorComponent = Get-RimsEmulatorComponent -State $state
  if ($null -ne $emulatorComponent) {
    $result.components += $emulatorComponent
  }
  $tlsComponent = New-RimsLocalTlsComponent `
    -State $state `
    -TlsPaths (Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory) `
    -Required ([bool]$UseLocalTls)
  $result.components += $tlsComponent
  $overallHealthy = $healthy -and $dependenciesHealthy -and
    $frontendComponent.ok -and
    ($null -eq $emulatorComponent -or $emulatorComponent.ok) -and
    $tlsComponent.ok
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $overallHealthy `
    -ExitCode $(if ($overallHealthy) { 0 } else { 1 })
}

function Invoke-RimsLocalLogsUnlocked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [switch]$UseLocalTls
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
  $frontendPaths = Get-RimsFrontendRuntimePaths -Paths $paths
  foreach ($logSpec in @(
      [pscustomobject]@{
        name = 'frontendLogs'
        stdout = $frontendPaths.stdoutLog
        stderr = $frontendPaths.stderrLog
      },
      [pscustomobject]@{
        name = 'emulatorLogs'
        stdout = $frontendPaths.emulatorStdoutLog
        stderr = $frontendPaths.emulatorStderrLog
      }
    )) {
    $targetStdout = @(Get-RimsSanitizedLogTail -Path $logSpec.stdout)
    $targetStderr = @(Get-RimsSanitizedLogTail -Path $logSpec.stderr)
    $result.components += [pscustomobject][ordered]@{
      name = $logSpec.name
      ok = $true
      required = $false
      detail = 'Returned bounded sanitized log tails.'
      remediation = ''
      stdoutLogPath = $logSpec.stdout
      stderrLogPath = $logSpec.stderr
      stdoutTail = $targetStdout
      stderrTail = $targetStderr
    }
  }
  $state = Read-RimsRuntimeState -Paths $paths
  $tlsState = Get-RimsObjectPropertyValue -Value $state -Name 'localTls'
  if ($UseLocalTls -or $null -ne $tlsState) {
    $tlsPaths = Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory
    $tlsStdout = @(Get-RimsSanitizedLogTail -Path $tlsPaths.proxyStdoutLog)
    $tlsStderr = @(Get-RimsSanitizedLogTail -Path $tlsPaths.proxyStderrLog)
    $result.components += [pscustomobject][ordered]@{
      name = 'localTlsLogs'
      ok = $true
      required = $false
      detail = 'Returned bounded sanitized local HTTPS proxy log tails.'
      remediation = ''
      stdoutLogPath = $tlsPaths.proxyStdoutLog
      stderrLogPath = $tlsPaths.proxyStderrLog
      stdoutTail = $tlsStdout
      stderrTail = $tlsStderr
    }
    $result.components += New-RimsLocalTlsComponent `
      -State $state `
      -TlsPaths $tlsPaths `
      -Required ([bool]$UseLocalTls)
  }
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
      Invoke-RimsOwnedPostgresCleanup `
        -State $State `
        -BackendWorkspaceRoot $BackendWorkspaceRoot
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
    [scriptblock]$ComposeCleanupAction,
    [AllowNull()]
    [scriptblock]$PersistStateAction
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
    if ($null -eq $PersistStateAction) {
      Write-RimsRuntimeState -Paths $Paths -State $State
    } else {
      & $PersistStateAction $Paths $State
    }
  } catch {
    $persistenceDetail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    return [pscustomobject][ordered]@{
      ok = $false
      backendCleanup = [pscustomobject][ordered]@{
        required = Test-RimsStateOwnsAnyBackendProcess -State $State
        attempted = $false
        ok = $false
        detail = 'Backend cleanup was refused because pending ownership was not durable.'
      }
      dependencyCleanup = [pscustomobject][ordered]@{
        required = $composeOwned
        attempted = $false
        ok = $false
        detail = 'Dependency cleanup was refused because pending ownership was not durable.'
      }
      cleanupPending = $true
      managed = Test-RimsStateOwnsAnyBackendProcess -State $State
      healthy = $false
      stateRetained = Test-Path -LiteralPath $Paths.state -PathType Leaf
      detail = "Cleanup was not started because pending ownership could not be persisted: $persistenceDetail"
      remediation = 'Restore runtime state write access, then run down with the same paths and port.'
    }
  }

  $tlsPaths = Get-RimsLocalTlsPaths `
    -ScriptDirectory (Join-Path ([string]$State.frontendPath) 'scripts')
  $tlsCleanup = Stop-RimsLocalTlsRuntime `
    -State $State `
    -TlsPaths $tlsPaths
  if (-not $tlsCleanup.ok) {
    $State.cleanupPending = $true
    try {
      if ($null -eq $PersistStateAction) {
        Write-RimsRuntimeState -Paths $Paths -State $State
      } else {
        & $PersistStateAction $Paths $State
      }
    } catch {
    }
    return [pscustomobject][ordered]@{
      ok = $false
      backendCleanup = [pscustomobject]@{
        required = Test-RimsStateOwnsAnyBackendProcess -State $State
        attempted = $false
        ok = $false
        detail = 'Backend cleanup is deferred until exact TLS cleanup completes.'
      }
      dependencyCleanup = [pscustomobject]@{
        required = $composeOwned
        attempted = $false
        ok = -not $composeOwned
        detail = 'Dependency cleanup is deferred until exact TLS cleanup completes.'
      }
      cleanupPending = $true
      managed = Test-RimsStateOwnsAnyBackendProcess -State $State
      healthy = $false
      stateRetained = $true
      detail = $tlsCleanup.detail
      remediation = 'Run down with the same parameters to retry exact TLS cleanup.'
    }
  }

  $frontendCleanup = Stop-RimsFrontendResources `
    -State $State `
    -Paths $Paths
  if (-not $frontendCleanup.ok) {
    $State.cleanupPending = $true
    try {
      if ($null -eq $PersistStateAction) {
        Write-RimsRuntimeState -Paths $Paths -State $State
      } else {
        & $PersistStateAction $Paths $State
      }
    } catch {
    }
    return [pscustomobject][ordered]@{
      ok = $false
      backendCleanup = [pscustomobject]@{
        required = Test-RimsStateOwnsAnyBackendProcess -State $State
        attempted = $false
        ok = $false
        detail = 'Backend cleanup is deferred until exact frontend cleanup completes.'
      }
      dependencyCleanup = [pscustomobject]@{
        required = $composeOwned
        attempted = $false
        ok = -not $composeOwned
        detail = 'Dependency cleanup is deferred until exact frontend cleanup completes.'
      }
      cleanupPending = $true
      managed = Test-RimsStateOwnsAnyBackendProcess -State $State
      healthy = $false
      stateRetained = $true
      detail = $frontendCleanup.detail
      remediation = 'Run down with the same parameters to retry exact frontend cleanup.'
    }
  }

  $backendWasOwned = Test-RimsStateOwnsAnyBackendProcess -State $State
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
    $backendCleanupOk = -not (
      Test-RimsStateOwnsAnyBackendProcess -State $State
    )
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
        'linuxProcessGroupId',
        'linuxIdentity'
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
    if ($null -eq $PersistStateAction) {
      Write-RimsRuntimeState -Paths $Paths -State $State
    } else {
      & $PersistStateAction $Paths $State
    }
    $statePersisted = $true
  } catch {
    $stateWriteDetail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
  }
  $managed = Test-RimsStateOwnsAnyBackendProcess -State $State
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

function Invoke-RimsLocalDownUnlocked {
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
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
      -Managed (Test-RimsStateOwnsAnyBackendProcess -State $state) `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $wasOwned = Test-RimsStateOwnsAnyBackendProcess -State $state
  $wasCleanupPending = Test-RimsAnyRuntimeCleanupPending -State $state
  $hadLocalTls = $null -ne (Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'localTls')
  $tlsCleanup = Stop-RimsLocalTlsRuntime `
    -State $state `
    -TlsPaths (Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory)
  $result.components += New-RimsLocalComponent `
    -Name 'localTlsCleanup' `
    -Ok $tlsCleanup.ok `
    -Required $hadLocalTls `
    -Detail $tlsCleanup.detail `
    -Remediation $(if ($tlsCleanup.ok) { '' } else {
        'Retry down after exact TLS proxy and emulator ownership can be inspected.'
      })
  if (-not $tlsCleanup.ok) {
    $state.cleanupPending = $true
    Write-RimsRuntimeState -Paths $paths -State $state
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
  $frontendCleanup = Stop-RimsFrontendResources `
    -State $state `
    -Paths $paths
  $result.components += New-RimsLocalComponent `
    -Name 'frontendCleanup' `
    -Ok $frontendCleanup.ok `
    -Required $true `
    -Detail $frontendCleanup.detail `
    -Remediation $(if ($frontendCleanup.ok) { '' } else {
        'Retry down after the exactly owned frontend resource can be inspected.'
      })
  if (-not $frontendCleanup.ok) {
    $state.cleanupPending = $true
    Write-RimsRuntimeState -Paths $paths -State $state
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Backend was left running because frontend cleanup remains pending.' `
      -Remediation 'Retry down with the same parameters.' `
      -Managed $wasOwned `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -CleanupPending $true
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
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
    [AllowNull()]
    [object]$PostgresResourceIdentity = $null,
    [bool]$Healthy = $true,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FailureContext = '',
    [switch]$UseLocalTls
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
    lifecycleStage = if ($Healthy) { 'healthy' } else { 'preparing' }
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
    linuxIdentity = Get-RimsObjectPropertyValue `
      -Value $StartedBackend `
      -Name 'linuxIdentity'
    runtimeRoot = $RuntimePaths.root
    attachmentStoragePath = $RuntimePaths.attachmentStorage
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
      postgresResource = $PostgresResourceIdentity
    }
    frontend = $null
    emulator = $null
    useLocalTls = [bool]$UseLocalTls
    localTls = $null
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

function Update-RimsOwnedPostgresIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $status = Get-RimsPostgresStatus -Context $Context
  if (-not $status.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $status.exists
      detail = $status.detail
    }
  }
  if (-not $status.exists) {
    return [pscustomobject][ordered]@{
      ok = $true
      exists = $false
      detail = 'Controller-created postgres container is absent.'
    }
  }
  $resource = Get-RimsPostgresResourceIdentity `
    -Context $Context `
    -ContainerId $status.containerId
  if (-not $resource.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      detail = $resource.detail
    }
  }
  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name postgresResource `
    -Value $resource.identity `
    -Force
  return [pscustomobject][ordered]@{
    ok = $true
    exists = $true
    detail = $resource.detail
    identity = $resource.identity
  }
}

function Set-RimsDurableDependencyProvisionalState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  $State | Add-Member `
    -MemberType NoteProperty `
    -Name lifecycleStage `
    -Value 'dependencies' `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name healthy `
    -Value $false `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  Write-RimsRuntimeState -Paths $Paths -State $State
}

function Invoke-RimsLocalUpUnlocked {
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
  )

  $result = New-RimsLocalResult -Command 'up'
  $tlsPort = Get-RimsLocalTlsPort
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot

  $doctorAndroidDevice = if ($Target -eq 'android' -and
      [string]::IsNullOrWhiteSpace($AndroidDevice)) {
    'Medium_Phone_API_36.1'
  } else {
    $AndroidDevice
  }
  $doctorComponents = @(Invoke-RimsLocalDoctor `
      -Target $Target `
      -BackendDir $BackendDir `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -AndroidDevice $doctorAndroidDevice `
      -ScriptDirectory $ScriptDirectory `
      -UseLocalTls:$UseLocalTls)
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
    $owned = Test-RimsStateOwnsAnyBackendProcess -State $state
    $cleanupPending = Test-RimsAnyRuntimeCleanupPending -State $state
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
      if (Test-RimsStateOwnsAnyFrontendProcess -State $state) {
        $state.cleanupPending = $true
        Write-RimsRuntimeState -Paths $paths -State $state
        $result.components += New-RimsBackendLifecycleComponent `
          -Ok $false `
          -Detail 'Owned frontend resources remain after the backend exited; state was retained.' `
          -Remediation 'Run down with the recorded backend paths and port before retrying up.' `
          -Managed $false `
          -Healthy $false `
          -Stale $true `
          -Port $BackendPort `
          -CleanupPending $true
        return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
      }
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
      $recordedUseLocalTls = [bool](Get-RimsObjectPropertyValue `
          -Value $state `
          -Name 'useLocalTls' `
          -DefaultValue $false)
      if ($recordedUseLocalTls -ne [bool]$UseLocalTls) {
        $result.components += New-RimsLocalComponent `
          -Name 'localTls' `
          -Ok $false `
          -Required $true `
          -Detail 'The requested local HTTPS mode differs from the managed runtime state.' `
          -Remediation 'Run down with the recorded parameters before changing -UseLocalTls.'
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
      if ($healthy) {
        if (Test-RimsShouldApplyM9Fixtures `
            -Command 'up' `
            -IncludeDependencies:$IncludeDependencies) {
          $existingContext = Get-RimsWslLifecycleContext `
            -BackendDir $resolved.backendPath `
            -BackendWorkspaceRoot $resolved.workspacePath `
            -RuntimePaths $paths
          if (-not $existingContext.ok) {
            $result.errors = @(
              "Could not prepare WSL fixture paths: $($existingContext.detail)"
            )
            return Complete-RimsLocalResult `
              -Result $result `
              -Ok $false `
              -ExitCode 1
          }
          $existingMigration = Invoke-RimsBackendMigrations `
            -Context $existingContext
          $result.components += New-RimsLocalComponent `
            -Name 'migrations' `
            -Ok $existingMigration.ok `
            -Required $true `
            -Detail $existingMigration.detail `
            -Remediation $(if ($existingMigration.ok) { '' } else {
                'Inspect the sanitized migration error and verify database configuration.'
              })
          if (-not $existingMigration.ok) {
            return Complete-RimsLocalResult `
              -Result $result `
              -Ok $false `
              -ExitCode 1
          }
          $existingFixture = Invoke-RimsM9Fixtures -Context $existingContext
          $result.components += New-RimsM9FixtureComponent `
            -FixtureResult $existingFixture
          if (-not $existingFixture.ok) {
            return Complete-RimsLocalResult `
              -Result $result `
              -Ok $false `
              -ExitCode 1
          }
        }
        $frontendCompatibility = Get-RimsFrontendRequestCompatibility `
          -State $state `
          -Target $Target `
          -FrontendPort $FrontendPort `
          -AndroidDevice $AndroidDevice
        $currentTarget = [string](Get-RimsObjectPropertyValue `
            -Value $state `
            -Name 'target' `
            -DefaultValue 'none')
        if ($UseLocalTls -and $Target -eq 'android' -and
            $currentTarget -eq 'none') {
          $result.components += New-RimsLocalComponent `
            -Name 'localTls' `
            -Ok $false `
            -Required $true `
            -Detail 'Android HTTPS trust must be installed before Flutter starts.' `
            -Remediation 'Run restart or down, then up -Target android -UseLocalTls.'
          return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
        }
        if (-not $frontendCompatibility.matches -and
            ($Target -eq 'none' -or $currentTarget -ne 'none' -or
              $frontendCompatibility.hasRecordedResources)) {
          $result.components += New-RimsLocalComponent `
            -Name 'frontend' `
            -Ok $false `
            -Required $true `
            -Detail $frontendCompatibility.detail `
            -Remediation 'Run restart or down before changing frontend lifecycle parameters.'
          return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
        }
        if ($Target -eq 'none') {
          $result.components += Get-RimsFrontendComponent `
            -State $state `
            -FrontendPort $FrontendPort
        } elseif ($currentTarget -eq 'none') {
          $frontendStarted = Start-RimsManagedFrontend `
            -State $state `
            -Paths $paths `
            -Target $Target `
            -BackendPort $BackendPort `
            -FrontendPort $FrontendPort `
            -AndroidDevice $AndroidDevice `
            -UseLocalTls:$UseLocalTls `
            -TlsPort $tlsPort
          $result.components += New-RimsLocalComponent `
            -Name 'frontend' `
            -Ok $frontendStarted.ok `
            -Required $true `
            -Detail $frontendStarted.detail `
            -Remediation $(if ($frontendStarted.ok) { '' } else {
                'Inspect frontend logs and retry up; the pre-existing managed backend was left running.'
              })
          $healthy = $frontendStarted.ok
        } else {
          $existingFrontend = Get-RimsFrontendComponent `
            -State $state `
            -FrontendPort $FrontendPort
          $result.components += $existingFrontend
          $healthy = $existingFrontend.ok
        }
        if ($UseLocalTls) {
          $existingTls = New-RimsLocalTlsComponent `
            -State $state `
            -TlsPaths (Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory) `
            -Required $true
          $result.components += $existingTls
          $healthy = $healthy -and $existingTls.ok
        }
      }
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
    -FailureContext 'Backend startup did not complete.' `
    -UseLocalTls:$UseLocalTls
  $postgresResourceIdentity = $null
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
      if ($composeStarted) {
        [void](Update-RimsOwnedPostgresIdentity `
            -State $failedLifecycleState `
            -Context $context)
      }
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
      if ($composeStarted) {
        [void](Update-RimsOwnedPostgresIdentity `
            -State $failedLifecycleState `
            -Context $context)
      }
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
  if ($composeStarted) {
    $capturedResource = Update-RimsOwnedPostgresIdentity `
      -State $failedLifecycleState `
      -Context $context
    if (-not $capturedResource.ok -or -not $capturedResource.exists) {
      $result.components += New-RimsLocalComponent `
        -Name 'postgresOwnership' `
        -Ok $false `
        -Required $true `
        -Detail $capturedResource.detail `
        -Remediation 'Do not modify the container; restore Docker inspection and run down to retry exact cleanup.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $capturedResource.detail `
        -BackendPort $BackendPort `
        -Remediation 'Restore Docker inspection and retry exact cleanup with down.'
    }
    $postgresResourceIdentity = $capturedResource.identity
    try {
      Set-RimsDurableDependencyProvisionalState `
        -Paths $paths `
        -State $failedLifecycleState
    } catch {
      $persistenceFailure = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      $result.components += New-RimsLocalComponent `
        -Name 'runtimeState' `
        -Ok $false `
        -Required $true `
        -Detail "Could not durably record controller-created postgres ownership: $persistenceFailure" `
        -Remediation 'Restore runtime state write access before attempting cleanup.'
      return Complete-RimsLocalResult `
        -Result $result `
        -Ok $false `
        -ExitCode 1
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

  if (Test-RimsShouldApplyM9Fixtures `
      -Command 'up' `
      -IncludeDependencies:$IncludeDependencies) {
    $fixture = Invoke-RimsM9Fixtures -Context $context
    $result.components += New-RimsM9FixtureComponent `
      -FixtureResult $fixture
    if (-not $fixture.ok) {
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $fixture.detail `
        -BackendPort $BackendPort `
        -Remediation 'Inspect the sanitized fixture failure and verify the local database guard.'
    }
  }

  $started = Start-RimsManagedBackend `
    -Context $context `
    -RuntimePaths $paths `
    -BackendPort $BackendPort `
    -State $failedLifecycleState
  if (-not $started.ok) {
    if (-not $started.cleanupAllowed) {
      $stateRemains = Test-Path -LiteralPath $paths.state -PathType Leaf
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail $started.detail `
        -Remediation $(if ($stateRemains) {
            'The activation gate stayed closed. Wait for bootstrap timeout, then run down to reconcile durable state.'
          } else {
            'The activation gate stayed closed. Restore state persistence before retrying up.'
          }) `
        -Managed $false `
        -Healthy $false `
        -Stale $false `
        -Port $BackendPort `
        -CleanupPending $stateRemains
      return Complete-RimsLocalResult `
        -Result $result `
        -Ok $false `
        -ExitCode 1
    }
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $failedLifecycleState `
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
    -PostgresResourceIdentity $postgresResourceIdentity `
    -Healthy $true `
    -UseLocalTls:$UseLocalTls
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

  if ($UseLocalTls) {
    if ($Target -eq 'android') {
      try {
        $androidRuntime = Resolve-RimsAndroidRuntime `
          -State $newState `
          -Paths $paths `
          -AndroidDevice $AndroidDevice
        if (-not $androidRuntime.owned) {
          throw 'Local HTTPS trust installation refuses a pre-existing emulator.'
        }
      } catch {
        $detail = ConvertTo-RimsDiagnosticSummary `
          -StandardOutput '' `
          -StandardError $_.Exception.Message
        $result.components += New-RimsLocalComponent `
          -Name 'localTls' `
          -Ok $false `
          -Required $true `
          -Detail $detail `
          -Remediation 'Use an available controller-owned AVD or stop the pre-existing emulator yourself.'
        return Complete-RimsFailedUpResult `
          -Result $result `
          -Paths $paths `
          -State $newState `
          -BackendWorkspaceRoot $resolved.workspacePath `
          -FailureContext $detail `
          -BackendPort $BackendPort `
          -Remediation 'Correct Android emulator ownership and retry up.'
      }
    }
    $tlsPaths = Get-RimsLocalTlsPaths -ScriptDirectory $ScriptDirectory
    $tlsStarted = Invoke-RimsLocalTlsUp `
      -TlsPaths $tlsPaths `
      -BackendPort $BackendPort `
      -TlsPort $tlsPort `
      -Target $Target `
      -EmulatorState $newState.emulator
    if (-not $tlsStarted.ok) {
      $result.components += New-RimsLocalComponent `
        -Name 'localTls' `
        -Ok $false `
        -Required $true `
        -Detail $tlsStarted.detail `
        -Remediation 'Inspect WSL OpenSSL, TLS port, and owned emulator trust prerequisites.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $newState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $tlsStarted.detail `
        -BackendPort $BackendPort `
        -Remediation 'Correct the local HTTPS failure and retry up.'
    }
    $newState.localTls = $tlsStarted.state
    Write-RimsRuntimeState -Paths $paths -State $newState
    $result.components += New-RimsLocalTlsComponent `
      -State $newState `
      -TlsPaths $tlsPaths `
      -Required $true
  }

  if ($Target -ne 'none') {
    $frontendStarted = Start-RimsManagedFrontend `
      -State $newState `
      -Paths $paths `
      -Target $Target `
      -BackendPort $BackendPort `
      -FrontendPort $FrontendPort `
      -AndroidDevice $AndroidDevice `
      -UseLocalTls:$UseLocalTls `
      -TlsPort $tlsPort
    $result.components += New-RimsLocalComponent `
      -Name 'frontend' `
      -Ok $frontendStarted.ok `
      -Required $true `
      -Detail $frontendStarted.detail `
      -Remediation $(if ($frontendStarted.ok) { '' } else {
          'Inspect sanitized frontend logs and correct the launch failure.'
        })
    if (-not $frontendStarted.ok) {
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $newState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $frontendStarted.detail `
        -BackendPort $BackendPort `
        -Remediation 'Correct the frontend launch failure and retry up.'
    }
    $emulatorComponent = Get-RimsEmulatorComponent -State $newState
    if ($null -ne $emulatorComponent) {
      $result.components += $emulatorComponent
    }
  } else {
    $result.components += Get-RimsFrontendComponent `
      -State $newState `
      -FrontendPort $FrontendPort
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

function Invoke-RimsLocalResetUnlocked {
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
    [int]$BackendPort
  )

  $result = New-RimsLocalResult -Command 'reset'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  if ($Target -ne 'none') {
    $result.errors = @('Reset requires -Target none and does not launch a frontend.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  $doctorComponents = @(Invoke-RimsLocalDoctor `
      -Target 'none' `
      -BackendDir $BackendDir `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -AndroidDevice '' `
      -ScriptDirectory $ScriptDirectory)
  $result.components += $doctorComponents
  $failedDoctor = @($doctorComponents | Where-Object {
      $_.required -and -not $_.ok
    })
  if (-not $resolved.success -or $failedDoctor.Count -gt 0) {
    $result.errors = @('Required local reset checks failed; no data was changed.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -ne $state) {
    $result.errors = @(
      'Reset requires a stopped managed runtime; run down before resetting fixtures.'
    )
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $context = Get-RimsWslLifecycleContext `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -RuntimePaths $paths
  if (-not $context.ok) {
    $result.errors = @("Could not prepare WSL reset paths: $($context.detail)")
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $postgres = Get-RimsPostgresStatus -Context $context
  $postgresOk = $postgres.ok -and $postgres.healthy
  $result.components += New-RimsLocalComponent `
    -Name 'postgres' `
    -Ok $postgresOk `
    -Required $true `
    -Detail $(if ($postgresOk) {
        'Pre-existing PostgreSQL is healthy and remains user-managed.'
      } else {
        "PostgreSQL must already be healthy for reset ($($postgres.status))."
      }) `
    -Remediation $(if ($postgresOk) { '' } else {
        'Start the expected local PostgreSQL yourself, then retry reset.'
      })
  if (-not $postgresOk) {
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

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
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $fixture = Invoke-RimsM9Fixtures -Context $context -Reset
  $result.components += New-RimsM9FixtureComponent `
    -FixtureResult $fixture
  if (-not $fixture.ok) {
    return Complete-RimsLocalResult `
      -Result $result `
      -Ok $false `
      -ExitCode 1
  }

  $providerReset = Reset-RimsOwnedAttachmentProvider -RuntimePaths $paths
  $result.components += New-RimsLocalComponent `
    -Name 'attachment-provider' `
    -Ok $providerReset.ok `
    -Required $true `
    -Detail $providerReset.detail `
    -Remediation $(if ($providerReset.ok) { '' } else {
        'Inspect the runtime provider path and remove reparse-point or ownership conflicts.'
      })
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $providerReset.ok `
    -ExitCode $(if ($providerReset.ok) { 0 } else { 1 })
}

function Invoke-RimsLocalRestartUnlocked {
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
      -not (Test-RimsStateOwnsAnyBackendProcess -State $state) -or
      -not (Test-RimsRuntimeRequestMatchesState `
        -State $state `
        -BackendDir $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -BackendPort $BackendPort)) {
    if ($null -ne $state -and
        -not (Test-RimsStateOwnsAnyBackendProcess -State $state) -and
        -not (Test-RimsAnyRuntimeCleanupPending -State $state) -and
        -not (Test-RimsStateOwnsAnyFrontendProcess -State $state)) {
      Remove-RimsRuntimeState -Paths $paths
    }
    $cleanupPending = Test-RimsAnyRuntimeCleanupPending -State $state
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

  $down = Invoke-RimsLocalDownUnlocked `
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

  $up = Invoke-RimsLocalUpUnlocked `
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

function Get-RimsLifecycleLockTimeoutMilliseconds {
  $timeout = 5000
  $configured = 0
  if ([int]::TryParse(
      [string]$env:RIMS_LOCAL_LOCK_TIMEOUT_MS,
      [ref]$configured
    ) -and $configured -ge 1 -and $configured -le 60000) {
    $timeout = $configured
  }
  return $timeout
}

function New-RimsLifecycleLockComponent {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Lock
  )

  return [pscustomobject][ordered]@{
    name = 'lifecycleLock'
    ok = $Lock.ok
    required = $true
    detail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput $Lock.detail `
      -StandardError ''
    remediation = if ($Lock.ok) { '' } else {
      'Wait for the active local lifecycle command to finish, then retry.'
    }
    busy = $Lock.busy
  }
}

function New-RimsLifecycleLockFailureResult {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$Lock
  )

  $result = New-RimsLocalResult -Command $Command
  $result.components = @(
    (New-RimsRuntimePathsComponent -Paths $Paths),
    (New-RimsLifecycleLockComponent -Lock $Lock)
  )
  return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
  )

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -BackendPort $BackendPort `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'status' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalStatusUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
  }
}

function Invoke-RimsLocalHealth {
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
  )

  $result = Invoke-RimsLocalStatus @PSBoundParameters
  $result.command = 'health'
  return $result
}

function Invoke-RimsLocalLogs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [switch]$UseLocalTls
  )

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'logs' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalLogsUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
  )

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -BackendPort $BackendPort `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'down' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalDownUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
  }
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
    [switch]$IncludeDependencies,
    [switch]$UseLocalTls
  )

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -BackendPort $BackendPort `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'up' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalUpUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
  }
}

function Invoke-RimsLocalReset {
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
    [int]$BackendPort
  )

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -BackendPort $BackendPort `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'reset' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalResetUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
  }
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

  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $lock = Enter-RimsLifecycleLock `
    -Paths $paths `
    -BackendPort $BackendPort `
    -TimeoutMilliseconds (Get-RimsLifecycleLockTimeoutMilliseconds)
  if (-not $lock.ok) {
    return New-RimsLifecycleLockFailureResult `
      -Command 'restart' `
      -Paths $paths `
      -Lock $lock
  }
  try {
    return Invoke-RimsLocalRestartUnlocked @PSBoundParameters
  } finally {
    Exit-RimsLifecycleLock -Lock $lock
  }
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
      $_.name -in @('backendLogs', 'frontendLogs', 'emulatorLogs')
    })
  if ($logs.Count -eq 0) {
    Write-RimsLifecycleText -Result $Result
    return
  }
  foreach ($log in $logs) {
    $label = switch ($log.name) {
      'frontendLogs' { 'Frontend' }
      'emulatorLogs' { 'Emulator' }
      default { 'Backend' }
    }
    [Console]::Out.WriteLine("$label stdout ($($log.stdoutLogPath)):")
    foreach ($line in @($log.stdoutTail)) {
      [Console]::Out.WriteLine($line)
    }
    [Console]::Out.WriteLine("$label stderr ($($log.stderrLogPath)):")
    foreach ($line in @($log.stderrTail)) {
      [Console]::Out.WriteLine($line)
    }
  }
}
