$lockRuntimeRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-local-lock-' + [guid]::NewGuid().ToString('N'))
$originalLockRuntime = [Environment]::GetEnvironmentVariable(
  'RIMS_RUNTIME_DIR',
  'Process'
)
$originalLockTimeout = [Environment]::GetEnvironmentVariable(
  'RIMS_LOCAL_LOCK_TIMEOUT_MS',
  'Process'
)
$lockPort = Get-TestEphemeralPort
$firstLock = $null
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $lockRuntimeRoot,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'RIMS_LOCAL_LOCK_TIMEOUT_MS',
    '300',
    'Process'
  )
  $lockPaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  $firstTemporaryState = Get-RimsStateTemporaryPath -Paths $lockPaths
  $secondTemporaryState = Get-RimsStateTemporaryPath -Paths $lockPaths
  Assert-NotEqual `
    -Actual $firstTemporaryState `
    -Expected $secondTemporaryState `
    -Message 'Atomic state writes reused a shared temporary path.'
  if (-not $firstTemporaryState.StartsWith(
      ([string]$lockPaths.state) + '.tmp.',
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Atomic state temp path was not scoped to state.json.'
  }
  $lockNames = @(Get-RimsLifecycleLockNames `
      -Paths $lockPaths `
      -BackendPort $lockPort)
  Assert-Equal `
    -Actual $lockNames.Count `
    -Expected 2 `
    -Message 'Lifecycle lock set did not include runtime and backend port.'
  Assert-Equal `
    -Actual ($lockNames -join '|') `
    -Expected (@($lockNames | Sort-Object) -join '|') `
    -Message 'Lifecycle locks are not acquired in deterministic name order.'

  $frontendPortLock = Enter-RimsFrontendPortLock `
    -FrontendPort $lockPort `
    -TimeoutMilliseconds 1000
  Assert-True `
    -Value $frontendPortLock.ok `
    -Message 'First frontend-port client could not acquire its lock.'
  try {
    $frontendPortProbe = Start-Job -ScriptBlock {
      param($ModulePath, $Port)
      . $ModulePath
      $lock = Enter-RimsFrontendPortLock -FrontendPort $Port -TimeoutMilliseconds 300
      try {
        return [pscustomobject]@{ ok = $lock.ok; busy = $lock.busy }
      } finally {
        Exit-RimsFrontendPortLock -Lock $lock
      }
    } -ArgumentList $commonScript, $lockPort
    [void](Wait-Job -Job $frontendPortProbe -Timeout 5)
    $secondFrontendPortLock = Receive-Job -Job $frontendPortProbe
    Remove-Job -Job $frontendPortProbe -Force
    Assert-False `
      -Value $secondFrontendPortLock.ok `
      -Message 'A second controller acquired the same frontend-port lock.'
  } finally {
    Exit-RimsFrontendPortLock -Lock $frontendPortLock
  }

  $firstLock = Enter-RimsLifecycleLock `
    -Paths $lockPaths `
    -BackendPort $lockPort `
    -TimeoutMilliseconds 1000
  Assert-True `
    -Value $firstLock.ok `
    -Message 'First lifecycle client could not acquire its lock set.'

  $lockProbeScript = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('rims-lock-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    $probeSource = @'
param(
  [string]$CommonScript,
  [string]$ScriptDirectory,
  [int]$BackendPort
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $CommonScript
$paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
$lock = Enter-RimsLifecycleLock `
  -Paths $paths `
  -BackendPort $BackendPort `
  -TimeoutMilliseconds 300
try {
  [pscustomobject]@{
    ok = $lock.ok
    busy = $lock.busy
    detail = $lock.detail
  } | ConvertTo-Json -Compress
} finally {
  Exit-RimsLifecycleLock -Lock $lock
}
'@
    [IO.File]::WriteAllText($lockProbeScript, $probeSource)
    $probe = Invoke-RimsExternalCommand `
      -FilePath (Get-Process -Id $PID).Path `
      -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $lockProbeScript,
        '-CommonScript',
        $commonScript,
        '-ScriptDirectory',
        $scriptDir,
        '-BackendPort',
        [string]$lockPort
      ) `
      -TimeoutSeconds 5
    Assert-Equal `
      -Actual $probe.ExitCode `
      -Expected 0 `
      -Message 'Competing lifecycle lock probe did not exit cleanly.'
    $probeResult = $probe.StandardOutput | ConvertFrom-Json
    Assert-False `
      -Value $probeResult.ok `
      -Message 'A competing process acquired an already-owned lifecycle lock.'
    Assert-True `
      -Value $probeResult.busy `
      -Message 'Competing lifecycle lock timeout was not reported as busy.'
  } finally {
    Remove-Item `
      -LiteralPath $lockProbeScript `
      -Force `
      -ErrorAction SilentlyContinue
  }

  $staleState = New-TestRuntimeState `
    -Process $null `
    -RuntimePaths $lockPaths `
    -BackendPort $lockPort
  Write-RimsRuntimeState -Paths $lockPaths -State $staleState
  $busyStatus = Invoke-LocalCli -Arguments @(
    '-Command',
    'status',
    '-Output',
    'Json',
    '-BackendDir',
    'C:\test-backend-source',
    '-BackendWorkspaceRoot',
    'C:\test-backend-runtime',
    '-BackendPort',
    [string]$lockPort
  )
  Assert-NotEqual `
    -Actual $busyStatus.ExitCode `
    -Expected 0 `
    -Message 'Competing status command unexpectedly succeeded.'
  $busyStatusResult = ConvertFrom-SingleJson `
    -Text $busyStatus.StandardOutput `
    -Context 'Busy lifecycle status'
  $busyLockComponent = @($busyStatusResult.components | Where-Object {
      $_.name -eq 'lifecycleLock'
    })[0]
  Assert-True `
    -Value $busyLockComponent.busy `
    -Message 'Competing lifecycle client did not return a structured busy result.'
  Assert-True `
    -Value (Test-Path -LiteralPath $lockPaths.state) `
    -Message 'Competing lifecycle client deleted shared runtime state.'

  Exit-RimsLifecycleLock -Lock $firstLock
  $firstLock = $null
  $secondLock = Enter-RimsLifecycleLock `
    -Paths $lockPaths `
    -BackendPort $lockPort `
    -TimeoutMilliseconds 1000
  try {
    Assert-True `
      -Value $secondLock.ok `
      -Message 'Lifecycle lock was not released for the next client.'
  } finally {
    Exit-RimsLifecycleLock -Lock $secondLock
  }
} finally {
  if ($null -ne $firstLock) {
    Exit-RimsLifecycleLock -Lock $firstLock
  }
  [Environment]::SetEnvironmentVariable(
    'RIMS_RUNTIME_DIR',
    $originalLockRuntime,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'RIMS_LOCAL_LOCK_TIMEOUT_MS',
    $originalLockTimeout,
    'Process'
  )
  Remove-Item `
    -LiteralPath $lockRuntimeRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
}
