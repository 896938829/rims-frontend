function New-TestLaunchState {
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    lifecycleStage = 'preparing'
    healthy = $false
    cleanupPending = $false
    windowsPid = $null
    windowsProcessStartTimeUtc = $null
    linuxProcessGroupId = $null
    linuxIdentity = $null
  }
}

function Copy-TestObject {
  param([Parameter(Mandatory = $true)][psobject]$Value)
  return $Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json
}

$spawnCounter = [pscustomobject]@{ count = 0 }
$beforeSpawnState = New-TestLaunchState
$beforeSpawn = Invoke-RimsBackendLaunchStateMachine `
  -State $beforeSpawnState `
  -PersistStateAction {
    param([psobject]$State)
    throw 'Injected first state persistence failure DB_PASSWORD=before-spawn-secret'
  } `
  -SpawnAction {
    $spawnCounter.count++
    return [pscustomobject]@{}
  } `
  -LinuxIdentityAction { return [pscustomobject]@{} } `
  -ActivateAction { return $true } `
  -HealthAction { return $true }
Assert-False `
  -Value $beforeSpawn.ok `
  -Message 'Launch continued after provisional state persistence failed.'
Assert-Equal `
  -Actual $spawnCounter.count `
  -Expected 0 `
  -Message 'Backend spawned before provisional state was durable.'
Assert-False `
  -Value $beforeSpawn.activationOpen `
  -Message 'Activation gate opened after provisional persistence failure.'
if ($beforeSpawn.detail.Contains('before-spawn-secret')) {
  throw 'Provisional persistence failure leaked a secret.'
}

$durableSnapshots = New-Object 'Collections.Generic.List[object]'
$activationCounter = [pscustomobject]@{ count = 0 }
$afterSpawnState = New-TestLaunchState
$afterSpawn = Invoke-RimsBackendLaunchStateMachine `
  -State $afterSpawnState `
  -PersistStateAction {
    param([psobject]$State)
    [void]$durableSnapshots.Add((Copy-TestObject -Value $State))
  } `
  -SpawnAction {
    return [pscustomobject]@{
      ok = $true
      windowsPid = 5101
      windowsProcessStartTimeUtc = '2026-01-01T00:00:00.0000000Z'
    }
  } `
  -LinuxIdentityAction {
    throw 'Injected interruption after spawn.'
  } `
  -ActivateAction {
    $activationCounter.count++
    return $true
  } `
  -HealthAction { return $true }
Assert-False -Value $afterSpawn.ok -Message 'After-spawn interruption passed.'
Assert-False `
  -Value $afterSpawn.ownershipPersisted `
  -Message 'After-spawn interruption claimed durable process ownership.'
Assert-Equal `
  -Actual $activationCounter.count `
  -Expected 0 `
  -Message 'Activation gate opened before tuple state was durable.'
Assert-Equal `
  -Actual $durableSnapshots.Count `
  -Expected 1 `
  -Message 'After-spawn interruption wrote an unexpected state transition.'
Assert-Equal `
  -Actual $durableSnapshots[0].lifecycleStage `
  -Expected 'launching' `
  -Message 'First durable launch state was not launching.'
Assert-Equal `
  -Actual $durableSnapshots[0].windowsPid `
  -Expected $null `
  -Message 'Launching state recorded an unverified process tuple.'

$durableSnapshots.Clear()
$activationCounter.count = 0
$afterTupleState = New-TestLaunchState
$afterTuple = Invoke-RimsBackendLaunchStateMachine `
  -State $afterTupleState `
  -PersistStateAction {
    param([psobject]$State)
    if ($State.lifecycleStage -eq 'starting') {
      throw 'Injected tuple state persistence failure.'
    }
    [void]$durableSnapshots.Add((Copy-TestObject -Value $State))
  } `
  -SpawnAction {
    return [pscustomobject]@{
      ok = $true
      windowsPid = 5102
      windowsProcessStartTimeUtc = '2026-01-01T00:00:01.0000000Z'
    }
  } `
  -LinuxIdentityAction {
    return New-TestLinuxProcessIdentity `
      -LeaderPid 5202 `
      -ProcessGroupId 5202 `
      -CommandMarker 'rims-gate-marker'
  } `
  -ActivateAction {
    $activationCounter.count++
    return $true
  } `
  -HealthAction { return $true }
Assert-False -Value $afterTuple.ok -Message 'Tuple persistence failure passed.'
Assert-False `
  -Value $afterTuple.ownershipPersisted `
  -Message 'Failed tuple persistence was treated as durable ownership.'
Assert-Equal `
  -Actual $activationCounter.count `
  -Expected 0 `
  -Message 'Activation gate opened after tuple persistence failed.'
Assert-Equal `
  -Actual $durableSnapshots.Count `
  -Expected 1 `
  -Message 'Tuple persistence failure replaced the prior durable state.'

$durableSnapshots.Clear()
$activationCounter.count = 0
$beforeHealthyState = New-TestLaunchState
$beforeHealthy = Invoke-RimsBackendLaunchStateMachine `
  -State $beforeHealthyState `
  -PersistStateAction {
    param([psobject]$State)
    [void]$durableSnapshots.Add((Copy-TestObject -Value $State))
  } `
  -SpawnAction {
    return [pscustomobject]@{
      ok = $true
      windowsPid = 5103
      windowsProcessStartTimeUtc = '2026-01-01T00:00:02.0000000Z'
    }
  } `
  -LinuxIdentityAction {
    return New-TestLinuxProcessIdentity `
      -LeaderPid 5203 `
      -ProcessGroupId 5203 `
      -CommandMarker 'rims-health-marker'
  } `
  -ActivateAction {
    $activationCounter.count++
    return $true
  } `
  -HealthAction { return $false }
Assert-False -Value $beforeHealthy.ok -Message 'Unhealthy activated backend passed.'
Assert-True `
  -Value $beforeHealthy.ownershipPersisted `
  -Message 'Activated unhealthy backend lost durable ownership.'
Assert-True `
  -Value $beforeHealthy.cleanupAllowed `
  -Message 'Activated unhealthy backend could not enter owned cleanup.'
Assert-True `
  -Value $beforeHealthy.activationOpen `
  -Message 'After-gate interruption did not record activation.'
Assert-Equal `
  -Actual $activationCounter.count `
  -Expected 1 `
  -Message 'Activation gate did not open exactly once.'
Assert-Equal `
  -Actual $durableSnapshots.Count `
  -Expected 2 `
  -Message 'Launch did not persist launching and starting transitions.'
Assert-Equal `
  -Actual $durableSnapshots[1].linuxIdentity.commandMarker `
  -Expected 'rims-health-marker' `
  -Message 'Starting state omitted exact Linux process identity.'

$cleanupRuntimeRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-cleanup-persistence-' + [guid]::NewGuid().ToString('N'))
$originalCleanupRuntime = [Environment]::GetEnvironmentVariable(
  'RIMS_RUNTIME_DIR',
  'Process'
)
$cleanupTrackedProcesses = `
  New-Object 'Collections.Generic.List[Diagnostics.Process]'
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $cleanupRuntimeRoot,
    'Process'
  )
  $cleanupPaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  $cleanupChild = Start-TestSleepProcess `
    -TrackedProcesses $cleanupTrackedProcesses
  $cleanupState = New-TestRuntimeState `
    -Process $cleanupChild `
    -RuntimePaths $cleanupPaths `
    -BackendPort (Get-TestEphemeralPort) `
    -ComposeStartedByController $true
  $cleanupCalls = [pscustomobject]@{ backend = 0; dependency = 0 }
  $failedPersistenceCleanup = Resolve-RimsFailedLifecycleCleanup `
    -Paths $cleanupPaths `
    -State $cleanupState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -FailureContext 'Injected failed-start cleanup' `
    -PersistStateAction {
      param([psobject]$Paths, [psobject]$State)
      throw 'Injected cleanup persistence failure DB_PASSWORD=cleanup-secret'
    } `
    -BackendCleanupAction {
      param([psobject]$State)
      $cleanupCalls.backend++
      return $true
    } `
    -ComposeCleanupAction {
      param([string]$BackendWorkspaceRoot)
      $cleanupCalls.dependency++
      return [pscustomobject]@{ ok = $true; detail = 'Unexpected cleanup.' }
    }
  Assert-False `
    -Value $failedPersistenceCleanup.ok `
    -Message 'Cleanup passed after pending state persistence failed.'
  Assert-Equal `
    -Actual $cleanupCalls.backend `
    -Expected 0 `
    -Message 'Backend cleanup ran without durable pending ownership.'
  Assert-Equal `
    -Actual $cleanupCalls.dependency `
    -Expected 0 `
    -Message 'Dependency cleanup ran without durable pending ownership.'
  Assert-True `
    -Value (Test-TestProcessAlive -ProcessId $cleanupChild.Id) `
    -Message 'Persistence failure terminated an unrecorded backend process.'
  if ($failedPersistenceCleanup.detail.Contains('cleanup-secret')) {
    throw 'Cleanup persistence failure leaked a secret.'
  }
} finally {
  foreach ($cleanupProcess in $cleanupTrackedProcesses) {
    if (Test-TestProcessAlive -ProcessId $cleanupProcess.Id) {
      Stop-Process `
        -Id $cleanupProcess.Id `
        -Force `
        -ErrorAction SilentlyContinue
    }
    $cleanupProcess.Dispose()
  }
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $originalCleanupRuntime,
    'Process'
  )
  Remove-Item `
    -LiteralPath $cleanupRuntimeRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
}
