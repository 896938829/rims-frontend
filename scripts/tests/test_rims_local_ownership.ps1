if (-not (Test-Path -LiteralPath $localScript)) {
  throw "Missing local runtime script: $localScript"
}
if (-not (Test-Path -LiteralPath $commonScript)) {
  throw "Missing local runtime common script: $commonScript"
}
. $commonScript

$originalRuntimeDirectory = [Environment]::GetEnvironmentVariable(
  'RIMS_RUNTIME_DIR',
  'Process'
)
$testRuntimeDirectory = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-local-runtime-' + [guid]::NewGuid().ToString('N'))
$trackedLifecycleProcesses = `
  New-Object 'Collections.Generic.List[Diagnostics.Process]'
$trackedListeners = New-Object 'Collections.Generic.List[object]'
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $testRuntimeDirectory,
    'Process'
  )
  $runtimePaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  Assert-Equal `
    -Actual $runtimePaths.root `
    -Expected ([IO.Path]::GetFullPath($testRuntimeDirectory)) `
    -Message 'RIMS_RUNTIME_DIR was not treated as the complete runtime root.'
  Assert-Equal `
    -Actual $runtimePaths.state `
    -Expected (Join-Path $testRuntimeDirectory 'state.json') `
    -Message 'Runtime state path does not use the override root.'
  Assert-Equal `
    -Actual $runtimePaths.stdoutLog `
    -Expected (Join-Path $testRuntimeDirectory 'logs\backend.stdout.log') `
    -Message 'Runtime stdout log path is incorrect.'
  Assert-Equal `
    -Actual $runtimePaths.stderrLog `
    -Expected (Join-Path $testRuntimeDirectory 'logs\backend.stderr.log') `
    -Message 'Runtime stderr log path is incorrect.'
  Assert-Equal `
    -Actual $runtimePaths.attachmentStorage `
    -Expected (Join-Path $testRuntimeDirectory 'providers\files') `
    -Message 'Attachment storage is not owned by the runtime root.'
  Initialize-RimsRuntimeDirectories -Paths $runtimePaths
  $providerMarker = Join-Path $runtimePaths.attachmentStorage 'remove-me.txt'
  $providerSibling = Join-Path $runtimePaths.root 'providers\keep-me.txt'
  [IO.File]::WriteAllText($providerMarker, 'owned attachment')
  [IO.File]::WriteAllText($providerSibling, 'provider sibling')
  $providerReset = Reset-RimsOwnedAttachmentProvider `
    -RuntimePaths $runtimePaths
  Assert-True `
    -Value $providerReset.ok `
    -Message 'Exact attachment provider reset failed.'
  Assert-False `
    -Value (Test-Path -LiteralPath $providerMarker) `
    -Message 'Attachment provider reset retained owned content.'
  Assert-True `
    -Value (Test-Path -LiteralPath $providerSibling -PathType Leaf) `
    -Message 'Attachment provider reset removed a sibling file.'

  $outsideProvider = [pscustomobject]@{
    root = $runtimePaths.root
    attachmentStorage = Join-Path $runtimePaths.root 'outside-files'
  }
  $outsideReset = Reset-RimsOwnedAttachmentProvider `
    -RuntimePaths $outsideProvider
  Assert-False `
    -Value $outsideReset.ok `
    -Message 'Attachment provider reset accepted a non-exact target.'

  $composeContext = [pscustomobject]@{
    workspace = '/mnt/e/My Work/RIMS'
    environment = '/mnt/e/My Work/RIMS/.env'
    compose = '/mnt/e/My Work/RIMS/deploy/docker-compose.yml'
  }
  $composeArguments = @(Get-RimsComposeArguments `
      -Context $composeContext `
      -Arguments @('ps', '-q', 'postgres'))
  Assert-Equal `
    -Actual ($composeArguments -join '|') `
    -Expected '-e|docker|compose|--project-directory|/mnt/e/My Work/RIMS|--env-file|/mnt/e/My Work/RIMS/.env|-f|/mnt/e/My Work/RIMS/deploy/docker-compose.yml|ps|-q|postgres' `
    -Message 'Compose commands did not preserve the runtime-root project identity.'
  $postgresDiscoveryArguments = @(Get-RimsPostgresDiscoveryArguments `
      -Context $composeContext)
  Assert-Equal `
    -Actual ($postgresDiscoveryArguments[-4..-1] -join '|') `
    -Expected 'ps|-a|-q|postgres' `
    -Message 'PostgreSQL discovery omitted stopped Compose containers.'
  $postgresCases = @(
    [pscustomobject]@{
      name = 'absent'
      containerId = ''
      stateStatus = ''
      running = $false
      healthStatus = ''
      expectedStatus = 'absent'
      expectedExists = $false
      expectedOwned = $true
    },
    [pscustomobject]@{
      name = 'existing-stopped'
      containerId = 'pg-stopped'
      stateStatus = 'exited'
      running = $false
      healthStatus = ''
      expectedStatus = 'exited'
      expectedExists = $true
      expectedOwned = $false
    },
    [pscustomobject]@{
      name = 'existing-starting'
      containerId = 'pg-starting'
      stateStatus = 'running'
      running = $true
      healthStatus = 'starting'
      expectedStatus = 'starting'
      expectedExists = $true
      expectedOwned = $false
    },
    [pscustomobject]@{
      name = 'existing-unhealthy'
      containerId = 'pg-unhealthy'
      stateStatus = 'running'
      running = $true
      healthStatus = 'unhealthy'
      expectedStatus = 'unhealthy'
      expectedExists = $true
      expectedOwned = $false
    },
    [pscustomobject]@{
      name = 'existing-healthy'
      containerId = 'pg-healthy'
      stateStatus = 'running'
      running = $true
      healthStatus = 'healthy'
      expectedStatus = 'healthy'
      expectedExists = $true
      expectedOwned = $false
    }
  )
  foreach ($postgresCase in $postgresCases) {
    $postgresStatus = ConvertTo-RimsPostgresStatus `
      -ContainerId $postgresCase.containerId `
      -StateStatus $postgresCase.stateStatus `
      -Running $postgresCase.running `
      -HealthStatus $postgresCase.healthStatus
    Assert-Equal `
      -Actual $postgresStatus.exists `
      -Expected $postgresCase.expectedExists `
      -Message "PostgreSQL existence was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $postgresStatus.running `
      -Expected $postgresCase.running `
      -Message "PostgreSQL running state was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $postgresStatus.healthy `
      -Expected ($postgresCase.healthStatus -eq 'healthy') `
      -Message "PostgreSQL health was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $postgresStatus.containerId `
      -Expected $(if ($postgresCase.expectedExists) {
          $postgresCase.containerId
        } else {
          $null
        }) `
      -Message "PostgreSQL container id was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $postgresStatus.status `
      -Expected $postgresCase.expectedStatus `
      -Message "PostgreSQL status was wrong for $($postgresCase.name)."

    $ownership = Get-RimsPostgresDependencyOwnership -Status $postgresStatus
    Assert-Equal `
      -Actual $ownership.composeStartedByController `
      -Expected $postgresCase.expectedOwned `
      -Message "Compose ownership was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $ownership.cleanupComposeOnFailure `
      -Expected $postgresCase.expectedOwned `
      -Message "Failed-start cleanup decision was wrong for $($postgresCase.name)."
    Assert-Equal `
      -Actual $ownership.stopComposeOnDown `
      -Expected $postgresCase.expectedOwned `
      -Message "Down decision was wrong for $($postgresCase.name)."
  }
  Initialize-RimsRuntimeDirectories -Paths $runtimePaths
  $liveLogWriter = $null
  try {
    $liveLogWriter = New-Object IO.FileStream(
      $runtimePaths.stderrLog,
      [IO.FileMode]::Create,
      [IO.FileAccess]::Write,
      [IO.FileShare]::Read
    )
    $liveLogBytes = [Text.Encoding]::UTF8.GetBytes(
      'live log PASSWORD=do-not-leak DB_PASSWORD=db-log-secret ' +
      'POSTGRES_PASSWORD=postgres-log-secret ACCESS_TOKEN=access-log-secret ' +
      'JWT_SECRET=jwt-log-secret API_KEY=api-log-secret' + "`n"
    )
    $liveLogWriter.Write($liveLogBytes, 0, $liveLogBytes.Length)
    $liveLogWriter.Flush()
    $liveLogTail = @(Get-RimsSanitizedLogTail `
        -Path $runtimePaths.stderrLog `
        -MaximumLines 5)
    Assert-Equal `
      -Actual $liveLogTail.Count `
      -Expected 1 `
      -Message 'Live backend log tail returned the wrong number of lines.'
    $liveLogText = $liveLogTail -join "`n"
    if (-not $liveLogText.Contains('live log')) {
      throw 'Live backend log tail was unavailable or leaked a secret.'
    }
    foreach ($liveSecret in @(
        'do-not-leak',
        'db-log-secret',
        'postgres-log-secret',
        'access-log-secret',
        'jwt-log-secret',
        'api-log-secret'
      )) {
      if ($liveLogText.Contains($liveSecret)) {
        throw "Live backend log tail leaked '$liveSecret'."
      }
    }
  } finally {
    if ($null -ne $liveLogWriter) {
      $liveLogWriter.Dispose()
    }
  }
  $jsonLogs = Invoke-LocalCli -Arguments @(
    '-Command',
    'logs',
    '-Output',
    'Json'
  )
  Assert-Equal `
    -Actual $jsonLogs.ExitCode `
    -Expected 0 `
    -Message 'JSON logs command failed.'
  Assert-Equal `
    -Actual $jsonLogs.StandardError `
    -Expected '' `
    -Message 'JSON logs command wrote diagnostics to stderr.'
  $jsonLogsResult = ConvertFrom-SingleJson `
    -Text $jsonLogs.StandardOutput `
    -Context 'JSON logs'
  $jsonLogComponent = @($jsonLogsResult.components | Where-Object {
      $_.name -eq 'backendLogs'
    })[0]
  Assert-JsonArrayProperty `
    -Value $jsonLogComponent `
    -PropertyName 'stdoutTail'
  Assert-JsonArrayProperty `
    -Value $jsonLogComponent `
    -PropertyName 'stderrTail'
  $jsonLogText = $jsonLogComponent.stderrTail -join "`n"
  foreach ($jsonLogSecret in @(
      'do-not-leak',
      'db-log-secret',
      'postgres-log-secret',
      'access-log-secret',
      'jwt-log-secret',
      'api-log-secret'
    )) {
    if ($jsonLogText.Contains($jsonLogSecret)) {
      throw "JSON logs leaked '$jsonLogSecret' from backend stderr."
    }
  }

  $ownedPort = Get-TestEphemeralPort
  $ownedChild = Start-TestSleepProcess `
    -TrackedProcesses $trackedLifecycleProcesses
  $ownedState = New-TestRuntimeState `
    -Process $ownedChild `
    -RuntimePaths $runtimePaths `
    -BackendPort $ownedPort
  Write-RimsRuntimeState -Paths $runtimePaths -State $ownedState
  Assert-True `
    -Value (Test-Path -LiteralPath $runtimePaths.state -PathType Leaf) `
    -Message 'Atomic state writer did not create state.json.'
  Assert-False `
    -Value (Test-Path -LiteralPath ($runtimePaths.state + '.tmp')) `
    -Message 'Atomic state writer left state.json.tmp behind.'
  $readState = Read-RimsRuntimeState -Paths $runtimePaths
  Assert-Equal `
    -Actual $readState.schemaVersion `
    -Expected 1 `
    -Message 'Runtime state schema version changed.'
  Assert-True `
    -Value (Test-RimsStateOwnsProcess -State $readState) `
    -Message 'Matching PID and process start time were not treated as owned.'

  $mismatchedState = New-TestRuntimeState `
    -Process $ownedChild `
    -RuntimePaths $runtimePaths `
    -BackendPort $ownedPort `
    -ProcessStartTimeUtc ([DateTime]::UtcNow.AddDays(-1).ToString('o'))
  Assert-False `
    -Value (Test-RimsStateOwnsProcess -State $mismatchedState) `
    -Message 'A stale PID with a mismatched start time was treated as owned.'

  Write-RimsRuntimeState -Paths $runtimePaths -State $mismatchedState
  $staleStatus = Invoke-LocalCli -Arguments @(
    '-Command',
    'status',
    '-Output',
    'Json',
    '-BackendDir',
    'C:\test-backend-source',
    '-BackendWorkspaceRoot',
    'C:\test-backend-runtime',
    '-BackendPort',
    [string]$ownedPort
  )
  Assert-NotEqual `
    -Actual $staleStatus.ExitCode `
    -Expected 0 `
    -Message 'Status reported stale state as healthy.'
  $staleStatusResult = ConvertFrom-SingleJson `
    -Text $staleStatus.StandardOutput `
    -Context 'Stale runtime status'
  $staleBackendComponents = @($staleStatusResult.components | Where-Object {
      $_.name -eq 'backend'
    })
  Assert-Equal `
    -Actual $staleBackendComponents.Count `
    -Expected 1 `
    -Message 'Status omitted its structured backend component.'
  $staleBackend = $staleBackendComponents[0]
  Assert-Equal `
    -Actual $staleBackend.stale `
    -Expected $true `
    -Message 'Status did not report stale runtime state.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Status did not clean stale runtime state.'
  Assert-True `
    -Value (Test-TestProcessAlive -ProcessId $ownedChild.Id) `
    -Message 'Stale state reconciliation terminated an unrelated process.'

  [IO.Directory]::CreateDirectory($runtimePaths.root) | Out-Null
  [IO.File]::WriteAllText($runtimePaths.state, '{not-json')
  $malformedRead = Read-RimsRuntimeState -Paths $runtimePaths
  Assert-Equal `
    -Actual $null `
    -Expected $malformedRead `
    -Message 'Malformed runtime state did not return a clean state.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Malformed state remained at state.json.'
  $quarantinedState = @(Get-ChildItem `
      -LiteralPath $runtimePaths.root `
      -Filter 'state.invalid.*Z.json' `
      -File)
  Assert-Equal `
    -Actual $quarantinedState.Count `
    -Expected 1 `
    -Message 'Malformed state was not quarantined with a UTC timestamp.'

  $managedPort = Get-TestEphemeralPort
  $managedChild = Start-TestSleepProcess `
    -TrackedProcesses $trackedLifecycleProcesses
  $managedState = New-TestRuntimeState `
    -Process $managedChild `
    -RuntimePaths $runtimePaths `
    -BackendPort $managedPort
  Write-RimsRuntimeState -Paths $runtimePaths -State $managedState
  $managedDown = Invoke-LocalCli -Arguments @(
    '-Command',
    'down',
    '-Target',
    'none',
    '-Output',
    'Json',
    '-BackendDir',
    'C:\test-backend-source',
    '-BackendWorkspaceRoot',
    'C:\test-backend-runtime',
    '-BackendPort',
    [string]$managedPort
  )
  Assert-Equal `
    -Actual $managedDown.ExitCode `
    -Expected 0 `
    -Message 'Down failed to terminate an exactly owned process.'
  Assert-True `
    -Value (Wait-TestProcessExit -ProcessId $managedChild.Id) `
    -Message 'Down left an exactly owned process alive.'
  Assert-True `
    -Value (Test-TestProcessAlive -ProcessId $ownedChild.Id) `
    -Message 'Down terminated a process not identified by state ownership.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Down left managed state behind.'

  $failedStartStages = @(
    [pscustomobject]@{ name = 'compose-up'; backendStarted = $false },
    [pscustomobject]@{ name = 'postgres-readiness'; backendStarted = $false },
    [pscustomobject]@{ name = 'migration'; backendStarted = $false },
    [pscustomobject]@{ name = 'backend-start'; backendStarted = $true },
    [pscustomobject]@{ name = 'state-persistence'; backendStarted = $true }
  )
  foreach ($failedStartStage in $failedStartStages) {
    $stagePort = Get-TestEphemeralPort
    $stageChild = if ($failedStartStage.backendStarted) {
      Start-TestSleepProcess -TrackedProcesses $trackedLifecycleProcesses
    } else {
      $null
    }
    $stageState = New-TestRuntimeState `
      -Process $stageChild `
      -RuntimePaths $runtimePaths `
      -BackendPort $stagePort `
      -ComposeStartedByController $true
    $stageCleanup = Resolve-RimsFailedLifecycleCleanup `
      -Paths $runtimePaths `
      -State $stageState `
      -BackendWorkspaceRoot 'C:\test-backend-runtime' `
      -FailureContext "$($failedStartStage.name) failed DB_PASSWORD=stage-secret" `
      -BackendCleanupAction {
        param([psobject]$State)
        return Stop-RimsOwnedBackendProcess -State $State
      } `
      -ComposeCleanupAction {
        param([string]$BackendWorkspaceRoot)
        $inFlightState = Read-RimsRuntimeState -Paths $runtimePaths
        if ($null -eq $inFlightState -or
            -not $inFlightState.cleanupPending -or
            -not $inFlightState.dependencyOwnership.cleanupPending) {
          throw 'Compose cleanup began before pending ownership was persisted.'
        }
        return [pscustomobject]@{
          ok = $true
          detail = 'Controller-owned Compose cleanup completed.'
        }
      }
    Assert-True `
      -Value $stageCleanup.ok `
      -Message "Failed-start cleanup did not complete for $($failedStartStage.name)."
    Assert-True `
      -Value $stageCleanup.backendCleanup.ok `
      -Message "Backend cleanup outcome failed for $($failedStartStage.name)."
    Assert-True `
      -Value $stageCleanup.dependencyCleanup.ok `
      -Message "Dependency cleanup outcome failed for $($failedStartStage.name)."
    Assert-False `
      -Value (Test-Path -LiteralPath $runtimePaths.state) `
      -Message "Successful cleanup retained state for $($failedStartStage.name)."
    if ($null -ne $stageChild) {
      Assert-True `
        -Value (Wait-TestProcessExit -ProcessId $stageChild.Id) `
        -Message "Successful cleanup left a child for $($failedStartStage.name)."
    }
  }

  $deferredComposePort = Get-TestEphemeralPort
  $deferredComposeChild = Start-TestSleepProcess `
    -TrackedProcesses $trackedLifecycleProcesses
  $deferredComposeState = New-TestRuntimeState `
    -Process $deferredComposeChild `
    -RuntimePaths $runtimePaths `
    -BackendPort $deferredComposePort `
    -ComposeStartedByController $true
  $composeCallCounter = [pscustomobject]@{ count = 0 }
  $deferredCleanup = Resolve-RimsFailedLifecycleCleanup `
    -Paths $runtimePaths `
    -State $deferredComposeState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -FailureContext 'Backend cleanup failed DB_PASSWORD=deferred-secret' `
    -BackendCleanupAction {
      param([psobject]$State)
      return $false
    } `
    -ComposeCleanupAction {
      param([string]$BackendWorkspaceRoot)
      $composeCallCounter.count++
      return [pscustomobject]@{ ok = $true; detail = 'Must not run.' }
    }
  Assert-False `
    -Value $deferredCleanup.ok `
    -Message 'Backend cleanup failure unexpectedly completed lifecycle cleanup.'
  Assert-Equal `
    -Actual $composeCallCounter.count `
    -Expected 0 `
    -Message 'Compose cleanup ran before backend ownership was released.'
  $deferredState = Read-RimsRuntimeState -Paths $runtimePaths
  Assert-True `
    -Value (Test-RimsStateOwnsProcess -State $deferredState) `
    -Message 'Backend cleanup failure lost the backend ownership tuple.'
  Assert-True `
    -Value $deferredState.dependencyOwnership.composeStartedByController `
    -Message 'Backend cleanup failure lost dependency ownership.'
  $finishDeferred = Resolve-RimsFailedLifecycleCleanup `
    -Paths $runtimePaths `
    -State $deferredState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -FailureContext 'Retry deferred cleanup' `
    -BackendCleanupAction {
      param([psobject]$State)
      return Stop-RimsOwnedBackendProcess -State $State
    } `
    -ComposeCleanupAction {
      param([string]$BackendWorkspaceRoot)
      return [pscustomobject]@{ ok = $true; detail = 'Compose cleanup completed.' }
    }
  Assert-True `
    -Value $finishDeferred.ok `
    -Message 'Deferred backend and dependency cleanup could not complete.'

  $pendingPort = Get-TestEphemeralPort
  $pendingState = New-TestRuntimeState `
    -Process $null `
    -RuntimePaths $runtimePaths `
    -BackendPort $pendingPort `
    -ComposeStartedByController $true
  $pendingCleanup = Resolve-RimsFailedLifecycleCleanup `
    -Paths $runtimePaths `
    -State $pendingState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -FailureContext 'Migration failed DB_PASSWORD=pending-context-secret' `
    -ComposeCleanupAction {
      param([string]$BackendWorkspaceRoot)
      return [pscustomobject]@{
        ok = $false
        detail = 'Compose down failed POSTGRES_PASSWORD=compose-cleanup-secret'
      }
    }
  Assert-False `
    -Value $pendingCleanup.ok `
    -Message 'Failed Compose cleanup unexpectedly completed lifecycle cleanup.'
  Assert-True `
    -Value $pendingCleanup.cleanupPending `
    -Message 'Failed Compose cleanup omitted cleanupPending.'
  Assert-False `
    -Value $pendingCleanup.managed `
    -Message 'Dependency-only cleanup state reported a managed backend.'
  $retainedPendingState = Read-RimsRuntimeState -Paths $runtimePaths
  Assert-True `
    -Value $retainedPendingState.cleanupPending `
    -Message 'Dependency-only pending state omitted top-level cleanupPending.'
  Assert-True `
    -Value $retainedPendingState.dependencyOwnership.cleanupPending `
    -Message 'Dependency-only pending state omitted dependency cleanupPending.'
  Assert-True `
    -Value $retainedPendingState.dependencyOwnership.composeStartedByController `
    -Message 'Dependency-only pending state lost Compose ownership.'
  Assert-Equal `
    -Actual $retainedPendingState.windowsPid `
    -Expected $null `
    -Message 'Dependency-only pending state retained a backend PID.'
  $serializedPendingState = $retainedPendingState | ConvertTo-Json -Depth 10
  foreach ($pendingSecret in @('pending-context-secret', 'compose-cleanup-secret')) {
    if ($serializedPendingState.Contains($pendingSecret)) {
      throw "Cleanup-pending state leaked '$pendingSecret'."
    }
  }

  $pendingStatus = Invoke-LocalCli -Arguments @(
    '-Command',
    'status',
    '-Output',
    'Json',
    '-BackendDir',
    'C:\test-backend-source',
    '-BackendWorkspaceRoot',
    'C:\test-backend-runtime',
    '-BackendPort',
    [string]$pendingPort
  )
  Assert-NotEqual `
    -Actual $pendingStatus.ExitCode `
    -Expected 0 `
    -Message 'Status reported cleanup-pending state as healthy.'
  $pendingStatusResult = ConvertFrom-SingleJson `
    -Text $pendingStatus.StandardOutput `
    -Context 'Cleanup-pending status'
  $pendingBackendComponent = @($pendingStatusResult.components | Where-Object {
      $_.name -eq 'backend'
    })[0]
  Assert-True `
    -Value $pendingBackendComponent.cleanupPending `
    -Message 'Status omitted cleanupPending from its backend component.'
  Assert-False `
    -Value $pendingBackendComponent.managed `
    -Message 'Status reported dependency-only cleanup as a managed backend.'
  Assert-True `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Status deleted dependency-only cleanup-pending state.'

  $postgresCleanupFunction = Get-Item `
    -LiteralPath 'Function:\Invoke-RimsOwnedPostgresCleanup'
  $originalPostgresCleanup = $postgresCleanupFunction.ScriptBlock
  try {
    Set-Item `
      -LiteralPath 'Function:\Invoke-RimsOwnedPostgresCleanup' `
      -Value {
        param(
          [psobject]$State,
          [string]$BackendWorkspaceRoot
        )
        return [pscustomobject]@{
          ok = $false
          detail = 'Injected Compose retry failure API_KEY=retry-secret'
        }
      }
    $failedPendingDown = Invoke-RimsLocalDown `
      -ScriptDirectory $scriptDir `
      -BackendDir 'C:\test-backend-source' `
      -BackendWorkspaceRoot 'C:\test-backend-runtime' `
      -BackendPort $pendingPort
    Assert-False `
      -Value $failedPendingDown.ok `
      -Message 'Down reported success when pending Compose cleanup failed.'
    Assert-True `
      -Value (Test-Path -LiteralPath $runtimePaths.state) `
      -Message 'Down removed state after failed pending Compose cleanup.'

    Set-Item `
      -LiteralPath 'Function:\Invoke-RimsOwnedPostgresCleanup' `
      -Value {
        param(
          [psobject]$State,
          [string]$BackendWorkspaceRoot
        )
        return [pscustomobject]@{
          ok = $true
          detail = 'Injected Compose retry completed.'
        }
      }
    $successfulPendingDown = Invoke-RimsLocalDown `
      -ScriptDirectory $scriptDir `
      -BackendDir 'C:\test-backend-source' `
      -BackendWorkspaceRoot 'C:\test-backend-runtime' `
      -BackendPort $pendingPort
    Assert-True `
      -Value $successfulPendingDown.ok `
      -Message 'Down could not complete pending dependency cleanup.'
    Assert-False `
      -Value (Test-Path -LiteralPath $runtimePaths.state) `
      -Message 'Down retained state after successful pending cleanup.'
  } finally {
    Set-Item `
      -LiteralPath 'Function:\Invoke-RimsOwnedPostgresCleanup' `
      -Value $originalPostgresCleanup
  }

  $listener = New-Object Net.Sockets.TcpListener(
    [Net.IPAddress]::Loopback,
    0
  )
  $listener.Start()
  [void]$trackedListeners.Add($listener)
  $occupiedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $occupiedUp = Invoke-LocalCli -Arguments @(
    '-Command',
    'up',
    '-Target',
    'none',
    '-Output',
    'Json',
    '-BackendDir',
    'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect',
    '-BackendWorkspaceRoot',
    'E:\My Work\RIMS',
    '-BackendPort',
    [string]$occupiedPort
  )
  Assert-NotEqual `
    -Actual $occupiedUp.ExitCode `
    -Expected 0 `
    -Message 'Up accepted an unmanaged occupied backend port.'
  $occupiedUpResult = ConvertFrom-SingleJson `
    -Text $occupiedUp.StandardOutput `
    -Context 'Unmanaged occupied-port up'
  $occupiedPortComponents = @($occupiedUpResult.components | Where-Object {
      $_.name -eq 'backendPort'
    })
  Assert-Equal `
    -Actual $occupiedPortComponents.Count `
    -Expected 1 `
    -Message 'Up omitted its structured backend-port component.'
  $occupiedPortComponent = $occupiedPortComponents[0]
  Assert-False `
    -Value $occupiedPortComponent.ok `
    -Message 'Occupied backend port component reported success.'
  Assert-True `
    -Value $listener.Server.IsBound `
    -Message 'Up terminated the unmanaged listener.'
  Assert-False `
    -Value (Test-Path -LiteralPath $runtimePaths.state) `
    -Message 'Up recorded ownership for an unmanaged listener.'

  $unmanagedDown = Invoke-LocalCli -Arguments @(
    '-Command',
    'down',
    '-Target',
    'none',
    '-Output',
    'Json',
    '-BackendPort',
    [string]$occupiedPort
  )
  Assert-Equal `
    -Actual $unmanagedDown.ExitCode `
    -Expected 0 `
    -Message 'Down was not idempotent without managed state.'
  Assert-True `
    -Value $listener.Server.IsBound `
    -Message 'A port number alone granted permission to stop a listener.'
} finally {
  foreach ($listener in $trackedListeners) {
    try { $listener.Stop() } catch {}
  }
  foreach ($process in $trackedLifecycleProcesses) {
    if (Test-TestProcessAlive -ProcessId $process.Id) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $process.Dispose()
  }
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $originalRuntimeDirectory,
    'Process'
  )
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  $resolvedTestRuntime = [IO.Path]::GetFullPath($testRuntimeDirectory)
  if ($resolvedTestRuntime.StartsWith(
      $tempRoot,
      [StringComparison]::OrdinalIgnoreCase
    ) -and
      (Split-Path -Leaf $resolvedTestRuntime).StartsWith('rims-local-runtime-')) {
    Remove-Item `
      -LiteralPath $resolvedTestRuntime `
      -Recurse `
      -Force `
      -ErrorAction SilentlyContinue
  }
}
