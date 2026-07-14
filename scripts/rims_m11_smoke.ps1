param(
  [switch]$ListPlan,
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$AndroidDevice = $env:RIMS_ANDROID_DEVICE,
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$FaultProxyPort = 0,
  [string]$ReportPath,
  [string]$ArtifactRoot,
  [switch]$TestMode,
  [string]$FixturePath,
  [string]$CommandRecordPath,
  [string]$TestFrontendCommit,
  [string]$TestBackendCommit,
  [string]$TestChildReportFixturePath =
    $env:RIMS_M11_TEST_CHILD_REPORT_FIXTURE,
  [switch]$TestPreExistingRuntime,
  [switch]$TestPreExistingEmulator,
  [ValidateSet(
    'airplane-mode', 'latency', 'packet-loss', 'unreachable-api',
    'wifi-switch', 'process-recreation', 'stale-session',
    'stale-permission', 'duplicate-delivery', 'server-conflict',
    'database-corruption', 'android-offline-sync', 'validate-evidence'
  )]
  [string]$FailStep,
  [ValidateSet(
    'restore-airplane-mode', 'restore-wifi', 'restore-fault-proxy',
    'stop-owned-driver', 'stop-owned-fault-proxy', 'stop-owned-avd',
    'stop-owned-backend'
  )]
  [string]$TestCleanupFailStep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'lib\rims_m11_evidence.ps1')

$scenarioNames = @(
  'airplane-mode',
  'latency',
  'packet-loss',
  'unreachable-api',
  'wifi-switch',
  'process-recreation',
  'stale-session',
  'stale-permission',
  'duplicate-delivery',
  'server-conflict',
  'database-corruption'
)
$thresholds = [pscustomobject][ordered]@{
  cachedFirstContentMs = 500
  draftSaveMs = 250
  draftRecoveryMs = 1000
  outboxEnqueueMs = 250
  confirmedSyncMs = 10000
  databaseBytes = 25MB
  maxDuplicateDocuments = 0
  maxDuplicateInventoryTransactions = 0
}

if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
  throw 'Configure -AndroidDevice or RIMS_ANDROID_DEVICE for M11 smoke.'
}
if ($FaultProxyPort -eq 0) { $FaultProxyPort = $BackendPort + 1 }
if ($FaultProxyPort -eq $BackendPort -or
    $FaultProxyPort -lt 1 -or
    $FaultProxyPort -gt 65535) {
  throw 'FaultProxyPort must be a valid port distinct from BackendPort.'
}
if ($TestMode -and [string]::IsNullOrWhiteSpace($FixturePath)) {
  throw 'TestMode requires FixturePath.'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$androidWrapper = Join-Path $scriptDir 'rims_android_smoke.ps1'
. (Join-Path $scriptDir 'lib\rims_network_evidence.ps1')
$androidPlan = (& $androidWrapper `
    -ListPlan `
    -Phase 'offline-sync' `
    -AndroidDevice $AndroidDevice `
    -BackendPort $BackendPort `
    -FaultProxyPort $FaultProxyPort `
    -Output Json) -join "`n" | ConvertFrom-Json

$plan = [pscustomobject][ordered]@{
  schemaVersion = 1
  target = 'android-m11'
  phase = 'offline-sync'
  androidDevice = $AndroidDevice
  backendPort = $BackendPort
  backendTargetPort = $androidPlan.backendTargetPort
  ownedBridgePort = $androidPlan.ownedBridgePort
  faultProxyPort = $FaultProxyPort
  connectionChain = $androidPlan.connectionChain
  portOwnership = $androidPlan.portOwnership
  scenarios = $scenarioNames
  deterministicInjection = [pscustomobject][ordered]@{
    productionDefault = 'disabled'
    enableDefine = 'RIMS_E2E_M11=true'
    controlDefine = 'RIMS_E2E_M11_FAULT_CONTROL_URL'
    networkOwnership = 'owned-host-fault-proxy-restored-in-finally'
  }
  lifecycle = [pscustomobject][ordered]@{
    startsFromStoppedState = $true
    backend = 'start-if-stopped-stop-only-if-owned'
    emulator = 'reuse-explicit-avd-or-start-and-stop-exact-owned-process'
    driver = 'owned-flutter-test-process'
  }
  thresholds = $thresholds
}
if ($ListPlan) {
  if ($Output -eq 'Json') {
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
  } else {
    Write-Output (($scenarioNames + 'android-offline-sync') -join ' -> ')
  }
  exit 0
}

$runtimeRoot = Join-Path $repoRoot '.runtime'
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $runtimeRoot 'reports\latest-m11-smoke.json'
}
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $token = "$([DateTimeOffset]::Now.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N'))"
  $ArtifactRoot = Join-Path $runtimeRoot "m11-smoke-artifacts\$token"
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
  New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$androidReportPath = Join-Path $ArtifactRoot 'android-report.json'
$flutterOutputPath = Join-Path $ArtifactRoot 'flutter-output.log'
$commands = [Collections.Generic.List[string]]::new()
$steps = [Collections.Generic.List[object]]::new()
$cleanupErrors = [Collections.Generic.List[string]]::new()
$firstExitCode = 0
$failedStep = $null
$evidence = $null
$childReport = $null
$frontendCommit = $null
$backendCommit = $null
$reportedFrontendCommit = $null
$reportedBackendCommit = $null
$networkEvidence = $null
$networkEvidenceErrors = @()
$ownership = [pscustomobject][ordered]@{
  backendOwned = -not $TestPreExistingRuntime
  emulatorOwned = -not $TestPreExistingEmulator
  driverOwned = $true
  faultProxyOwned = $true
}
$cleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $false
  networkRestored = $false
  ownedProcessesStopped = $false
  errors = @()
}

function Add-M11Command([string]$Command) {
  [void]$script:commands.Add($Command)
}

function Set-M11Failure([string]$Name, [int]$ExitCode, [string]$Detail) {
  if ($script:firstExitCode -eq 0) {
    $script:firstExitCode = $ExitCode
    $script:failedStep = $Name
  }
  return [pscustomobject][ordered]@{
    name = $Name
    ok = $false
    exitCode = $ExitCode
    detail = $Detail
  }
}

function Invoke-M11Step([string]$Name, [scriptblock]$Action) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    if ($TestMode -and $Name -eq $FailStep) {
      $step = Set-M11Failure $Name 23 'Injected M11 smoke failure.'
    } else {
      & $Action
      $step = [pscustomobject][ordered]@{
        name = $Name
        ok = $true
        exitCode = 0
        detail = ''
      }
    }
  } catch {
    $exitCode = if ($_.Exception.Data.Contains('ExitCode')) {
      [int]$_.Exception.Data['ExitCode']
    } else { 1 }
    $step = Set-M11Failure $Name $exitCode $_.Exception.Message
  } finally {
    $watch.Stop()
  }
  $step | Add-Member -NotePropertyName durationMs -NotePropertyValue $watch.ElapsedMilliseconds
  [void]$script:steps.Add($step)
}

function Test-M11Number($Value) {
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64] -or
    $Value -is [single] -or $Value -is [double] -or
    $Value -is [decimal]
}

function Test-M11FiniteNonNegativeNumber($Value) {
  if (-not (Test-M11Number $Value)) { return $false }
  $number = [double]$Value
  return -not [double]::IsNaN($number) -and
    -not [double]::IsInfinity($number) -and $number -ge 0
}

function Test-M11JsonArray($Value) {
  return $Value -is [Array] -or
    ($Value -is [Collections.IList] -and $Value -isnot [string])
}

function Test-M11Commit($Value) {
  return $Value -is [string] -and $Value -cmatch '^[0-9a-fA-F]{40}$'
}

function Get-M11EvidenceErrors($Candidate) {
  $errors = [Collections.Generic.List[string]]::new()
  if ($null -eq $Candidate) {
    [void]$errors.Add('M11 evidence is missing.')
    return @($errors)
  }
  $json = $Candidate | ConvertTo-Json -Depth 20 -Compress
  if ($json -match '(?i)rawIdempotencyKey|accessToken|refreshToken|password|secret') {
    [void]$errors.Add('M11 evidence contains a forbidden secret or raw key field.')
  }
  $numericFields = @(
    'cacheReadLatencyMs', 'draftSaveLatencyMs',
    'processRecoveryLatencyMs', 'outboxEnqueueLatencyMs', 'syncTotalMs',
    'intentionalFaultDelayMs'
  )
  foreach ($field in $numericFields) {
    $property = $Candidate.PSObject.Properties[$field]
    if ($null -eq $property -or
        -not (Test-M11FiniteNonNegativeNumber $property.Value)) {
      [void]$errors.Add("Evidence '$field' must be a finite non-negative number.")
    }
  }
  foreach ($error in @(Get-RimsM11DiscreteEvidenceErrors -Candidate $Candidate)) {
    [void]$errors.Add($error)
  }
  foreach ($field in @('draftAutosaveDebounceMs', 'draftAutosaveEndToEndMs')) {
    $property = $Candidate.PSObject.Properties[$field]
    if ($null -eq $property -or
        -not (Test-RimsM11StrictInteger $property.Value) -or
        $property.Value -lt 0) {
      [void]$errors.Add("Evidence '$field' must be a non-negative JSON integer.")
    }
  }
  if ($null -ne $Candidate.PSObject.Properties['draftAutosaveDebounceMs'] -and
      $null -ne $Candidate.PSObject.Properties['draftAutosaveEndToEndMs'] -and
      (Test-RimsM11StrictInteger $Candidate.draftAutosaveDebounceMs) -and
      (Test-RimsM11StrictInteger $Candidate.draftAutosaveEndToEndMs) -and
      ($Candidate.draftAutosaveDebounceMs -ne 300 -or
       $Candidate.draftAutosaveEndToEndMs -lt
       $Candidate.draftAutosaveDebounceMs)) {
    [void]$errors.Add('Autosave timing must include the full 300 ms debounce window.')
  }
  $recoveryBoundary = $Candidate.PSObject.Properties['processRecoveryBoundary']
  if ($null -eq $recoveryBoundary -or
      $recoveryBoundary.Value -isnot [string] -or
      $recoveryBoundary.Value -cne
      'integration-entry-before-native-drift-open') {
    [void]$errors.Add('Process recovery boundary must begin before native Drift reopen.')
  }
  $unknownHash = $Candidate.PSObject.Properties['unknownIdempotencyKeyHash']
  if ($null -eq $unknownHash -or $unknownHash.Value -isnot [string] -or
      $unknownHash.Value -notmatch '^[0-9a-fA-F]{64}$') {
    [void]$errors.Add('Unknown-response idempotency evidence must be a SHA-256 hash.')
  }
  $requestFingerprint = $Candidate.PSObject.Properties['unknownRequestFingerprintHash']
  if ($null -eq $requestFingerprint -or
      $requestFingerprint.Value -isnot [string] -or
      $requestFingerprint.Value -cnotmatch '^[0-9a-f]{64}$') {
    [void]$errors.Add('Unknown-response request evidence must be a lowercase SHA-256 fingerprint.')
  }
  $sameTarget = $Candidate.PSObject.Properties['unknownSameTargetReplayObserved']
  if ($null -eq $sameTarget -or $sameTarget.Value -isnot [bool] -or
      -not $sameTarget.Value) {
    [void]$errors.Add('Unknown-response replay must prove the same target payload.')
  }
  foreach ($field in @('operationIds', 'idempotencyKeyHashes')) {
    $property = $Candidate.PSObject.Properties[$field]
    if ($null -eq $property -or
        -not (Test-M11JsonArray $property.Value) -or
        @($property.Value).Count -eq 0) {
      [void]$errors.Add("Evidence '$field' must be a non-empty array.")
    }
  }
  if ($null -ne $Candidate.PSObject.Properties['operationIds'] -and
      (Test-M11JsonArray $Candidate.operationIds)) {
    $ids = @($Candidate.operationIds)
    if (@($ids | Where-Object {
          $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
        }).Count -gt 0 -or
        @($ids | Select-Object -Unique).Count -ne $ids.Count) {
      [void]$errors.Add('Operation IDs must be non-empty unique strings.')
    }
  }
  if ($null -ne $Candidate.PSObject.Properties['idempotencyKeyHashes'] -and
      (Test-M11JsonArray $Candidate.idempotencyKeyHashes)) {
    foreach ($hash in @($Candidate.idempotencyKeyHashes)) {
      if ($hash -isnot [string] -or $hash -notmatch '^[0-9a-fA-F]{64}$') {
        [void]$errors.Add('Idempotency keys must be represented only by SHA-256 hashes.')
      }
    }
  }
  if ($null -ne $Candidate.PSObject.Properties['operationIds'] -and
      $null -ne $Candidate.PSObject.Properties['idempotencyKeyHashes'] -and
      (Test-M11JsonArray $Candidate.operationIds) -and
      (Test-M11JsonArray $Candidate.idempotencyKeyHashes) -and
      @($Candidate.operationIds).Count -ne @($Candidate.idempotencyKeyHashes).Count) {
    [void]$errors.Add('Operation IDs and idempotency hashes must have equal lengths.')
  }
  if ($null -ne $unknownHash -and $unknownHash.Value -is [string] -and
      $null -ne $Candidate.PSObject.Properties['idempotencyKeyHashes'] -and
      (Test-M11JsonArray $Candidate.idempotencyKeyHashes) -and
      @($Candidate.idempotencyKeyHashes) -notcontains $unknownHash.Value) {
    [void]$errors.Add('Unknown-response hash is not tied to a reported operation.')
  }
  $attachmentHash = $Candidate.PSObject.Properties['attachmentHash']
  $stagedAttachmentHash = $Candidate.PSObject.Properties['stagedAttachmentHash']
  if ($null -eq $attachmentHash -or $attachmentHash.Value -isnot [string] -or
      $attachmentHash.Value -notmatch '^[0-9a-fA-F]{64}$') {
    [void]$errors.Add('Attachment hash must be present as SHA-256 evidence.')
  }
  if ($null -eq $stagedAttachmentHash -or
      $stagedAttachmentHash.Value -isnot [string] -or
      $stagedAttachmentHash.Value -notmatch '^[0-9a-fA-F]{64}$') {
    [void]$errors.Add('Staged attachment hash must be present as SHA-256 evidence.')
  } elseif ($null -ne $attachmentHash -and
      $attachmentHash.Value -is [string] -and
      $attachmentHash.Value -ine $stagedAttachmentHash.Value) {
    [void]$errors.Add('Server attachment hash does not match staged bytes.')
  }
  $processStages = $Candidate.PSObject.Properties['processStages']
  if ($null -eq $processStages -or
      -not (Test-M11JsonArray $processStages.Value) -or
      @($processStages.Value).Count -ne 3) {
    [void]$errors.Add('Process recreation must contain exactly three persisted stages.')
  } else {
    $expectedStages = @('seed', 'offline-draft', 'recovery')
    $processIds = [Collections.Generic.List[int64]]::new()
    for ($index = 0; $index -lt 3; $index += 1) {
      $stage = @($processStages.Value)[$index]
      $name = $stage.PSObject.Properties['stage']
      $processId = $stage.PSObject.Properties['processId']
      $startedAt = $stage.PSObject.Properties['startedAt']
      $parsedTime = [DateTimeOffset]::MinValue
      if ($null -eq $name -or $name.Value -isnot [string] -or
          $name.Value -cne $expectedStages[$index] -or
          $null -eq $processId -or
          -not (Test-RimsM11StrictInteger $processId.Value) -or
          $processId.Value -le 0 -or
          $null -eq $startedAt -or $startedAt.Value -isnot [string] -or
          -not [DateTimeOffset]::TryParse($startedAt.Value, [ref]$parsedTime)) {
        [void]$errors.Add("Process stage '$($expectedStages[$index])' is malformed.")
      } else {
        [void]$processIds.Add([int64]$processId.Value)
      }
    }
    if (@($processIds | Select-Object -Unique).Count -ne 3) {
      [void]$errors.Add('Each persisted stage must run in a distinct app process.')
    }
  }
  $booleanGroups = @(
    @{ Name = 'cleanup'; Fields = @(
        'accountCacheCleared', 'outboxCleared', 'stagingCleared',
        'stagingDirectoryEmpty', 'baselineRestored'
      ) },
    @{ Name = 'journey'; Fields = @(
        'onlineSeeded', 'cachedInventoryRead', 'cachedReportRead',
        'cachedDetailRead', 'scannerCallbackCompleted', 'autosaveCompleted',
        'draftRecovered', 'nativeDatabaseReopened', 'queuedVisible',
        'explicitSyncConfirmed',
        'unknownResponseProbed', 'idempotentReplaySingleEffect',
        'attachmentDependencyCompleted', 'staleSessionBlocked',
        'stalePermissionBlocked', 'attentionVisible', 'conflictVisible',
        'conflictResolved', 'conflictReplacementCreated',
        'conflictReplacementVisible', 'serverAttachmentVerified',
        'serverLifecycleVerified',
        'logoutCleanupCompleted', 'databaseCorruptionQuarantined'
      ) }
  )
  foreach ($group in $booleanGroups) {
    $groupProperty = $Candidate.PSObject.Properties[$group.Name]
    if ($null -eq $groupProperty) {
      [void]$errors.Add("Evidence '$($group.Name)' is missing.")
      continue
    }
    foreach ($field in $group.Fields) {
      $property = $groupProperty.Value.PSObject.Properties[$field]
      if ($null -eq $property -or $property.Value -isnot [bool]) {
        [void]$errors.Add("Evidence '$($group.Name).$field' must be Boolean.")
      } elseif (-not $property.Value) {
        [void]$errors.Add("Evidence '$($group.Name).$field' must be true.")
      }
    }
  }
  $gates = @(
    @{ Field = 'cacheReadLatencyMs'; Max = $thresholds.cachedFirstContentMs; Message = 'Cached first content exceeded 500 ms.' },
    @{ Field = 'draftSaveLatencyMs'; Max = $thresholds.draftSaveMs; Message = 'Draft save exceeded 250 ms.' },
    @{ Field = 'processRecoveryLatencyMs'; Max = $thresholds.draftRecoveryMs; Message = 'Draft recovery exceeded 1000 ms.' },
    @{ Field = 'outboxEnqueueLatencyMs'; Max = $thresholds.outboxEnqueueMs; Message = 'Outbox enqueue exceeded 250 ms.' },
    @{ Field = 'syncTotalMs'; Max = $thresholds.confirmedSyncMs; Message = 'Confirmed sync exceeded 10000 ms excluding fault delay.' },
    @{ Field = 'databaseBytes'; Max = $thresholds.databaseBytes; Message = 'Offline database exceeded 25 MiB.' },
    @{ Field = 'duplicateDocumentCount'; Max = 0; Message = 'Duplicate server documents were observed.' },
    @{ Field = 'duplicateInventoryTransactionCount'; Max = 0; Message = 'Duplicate inventory transactions were observed.' }
  )
  foreach ($gate in $gates) {
    $property = $Candidate.PSObject.Properties[$gate.Field]
    if ($null -ne $property -and
        (Test-M11Number $property.Value) -and
        $property.Value -gt $gate.Max) {
      [void]$errors.Add($gate.Message)
    }
  }
  if ($null -ne $Candidate.PSObject.Properties['serverDocumentCount'] -and
      (Test-M11Number $Candidate.serverDocumentCount) -and
      $Candidate.serverDocumentCount -ne 1) {
    [void]$errors.Add('The idempotent journey must produce exactly one server document.')
  }
  if ($null -ne $Candidate.PSObject.Properties['attachmentCount'] -and
      (Test-M11FiniteNonNegativeNumber $Candidate.attachmentCount) -and
      $Candidate.attachmentCount -lt 1) {
    [void]$errors.Add('Attachment lifecycle evidence is empty.')
  }
  if ($null -ne $Candidate.PSObject.Properties['databaseBytes'] -and
      (Test-M11FiniteNonNegativeNumber $Candidate.databaseBytes) -and
      $Candidate.databaseBytes -le 0) {
    [void]$errors.Add('Offline database size must be positive.')
  }
  if ($null -ne $Candidate.PSObject.Properties['unknownStatusProbeCount'] -and
      (Test-RimsM11StrictInteger $Candidate.unknownStatusProbeCount) -and
      $Candidate.unknownStatusProbeCount -lt 1) {
    [void]$errors.Add('No real unknown-response status probe was observed.')
  }
  if ($null -ne $Candidate.PSObject.Properties['unknownReplayRequestCount'] -and
      (Test-RimsM11StrictInteger $Candidate.unknownReplayRequestCount) -and
      $Candidate.unknownReplayRequestCount -lt 2) {
    [void]$errors.Add('Same-key request replay was not observed.')
  }
  if ($null -ne $Candidate.PSObject.Properties['expectedStockDecrease'] -and
      $null -ne $Candidate.PSObject.Properties['observedStockDecrease'] -and
      (Test-RimsM11StrictInteger $Candidate.expectedStockDecrease) -and
      (Test-RimsM11StrictInteger $Candidate.observedStockDecrease) -and
      ($Candidate.expectedStockDecrease -le 0 -or
       $Candidate.expectedStockDecrease -ne $Candidate.observedStockDecrease)) {
    [void]$errors.Add('Observed stock delta does not match the expected fixture effect.')
  }
  return @($errors)
}

function Get-M11CommitErrors {
  $errors = [Collections.Generic.List[string]]::new()
  foreach ($entry in @(
      @{ Name = 'frontend'; Observed = $script:frontendCommit; Reported = $script:reportedFrontendCommit },
      @{ Name = 'backend'; Observed = $script:backendCommit; Reported = $script:reportedBackendCommit }
    )) {
    if (-not (Test-M11Commit $entry.Observed)) {
      [void]$errors.Add("Observed $($entry.Name) commit must be 40 hex characters.")
    }
    if (-not (Test-M11Commit $entry.Reported)) {
      [void]$errors.Add("Reported $($entry.Name) commit must be 40 hex characters.")
    } elseif ($entry.Observed -cne $entry.Reported) {
      [void]$errors.Add("Reported $($entry.Name) commit does not match runner HEAD.")
    }
  }
  return @($errors)
}

function Get-M11NetworkValue {
  param([string]$Name, $Fallback = $null)
  if ($null -eq $script:networkEvidence) { return $Fallback }
  $property = $script:networkEvidence.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Fallback }
  return $property.Value
}

function Get-M11NetworkValueFromChild {
  if ($null -eq $script:childReport) { return $null }
  $property = $script:childReport.PSObject.Properties['networkEvidence']
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Add-M11CleanupCommand([string]$Name) {
  Add-M11Command $Name
  if ($TestMode -and $Name -eq $TestCleanupFailStep) {
    [void]$script:cleanupErrors.Add("Injected cleanup failure: $Name")
  }
}

Add-M11Command 'inspect-runtime'
Add-M11Command "select-port:$FaultProxyPort"
Add-M11Command "select-avd:$AndroidDevice"
if (-not $TestPreExistingRuntime) { Add-M11Command "start-backend:$BackendPort" }
if (-not $TestPreExistingEmulator) { Add-M11Command "start-avd:$AndroidDevice" }
Add-M11Command "start-fault-proxy:$FaultProxyPort"

try {
  if ($TestMode) {
    $evidence = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
    $frontendCommit = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
    $backendCommit = 'b' * 40
    $reportedFrontendCommit = if ([string]::IsNullOrWhiteSpace($TestFrontendCommit)) {
      $frontendCommit
    } else { $TestFrontendCommit }
    $reportedBackendCommit = if ([string]::IsNullOrWhiteSpace($TestBackendCommit)) {
      $backendCommit
    } else { $TestBackendCommit }
    if (-not [string]::IsNullOrWhiteSpace($TestChildReportFixturePath)) {
      $script:childReport = Get-Content `
        -LiteralPath $TestChildReportFixturePath `
        -Raw | ConvertFrom-Json -ErrorAction Stop
      $script:networkEvidence = Get-M11NetworkValueFromChild
    }
  }
  foreach ($scenario in $scenarioNames) {
    if ($firstExitCode -ne 0) { break }
    Invoke-M11Step $scenario {
      if ($TestMode) { Add-M11Command "exercise:$scenario" }
    }
  }
  if ($firstExitCode -eq 0) {
    Invoke-M11Step 'android-offline-sync' {
      Add-M11Command 'run-android-offline-sync'
      if ($TestMode) { return }
      $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $androidWrapper,
        '-AndroidDevice', $AndroidDevice,
        '-BackendPort', "$BackendPort",
        '-FaultProxyPort', "$FaultProxyPort",
        '-Phase', 'offline-sync',
        '-ReportPath', $androidReportPath,
        '-ArtifactRoot', (Join-Path $ArtifactRoot 'android')
      )
      if (-not [string]::IsNullOrWhiteSpace($BackendDir)) {
        $arguments += @('-BackendDir', $BackendDir)
      }
      if (-not [string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
        $arguments += @('-BackendWorkspaceRoot', $BackendWorkspaceRoot)
      }
      $previousPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $captured = @(& powershell.exe @arguments 2>&1)
        $childExitCode = $LASTEXITCODE
      } finally {
        $ErrorActionPreference = $previousPreference
      }
      $captured | Set-Content -LiteralPath $flutterOutputPath -Encoding UTF8
      if (-not (Test-Path -LiteralPath $androidReportPath -PathType Leaf)) {
        $exception = [InvalidOperationException]::new('Android M11 smoke omitted its report.')
        $exception.Data['ExitCode'] = if ($childExitCode -eq 0) { 1 } else { $childExitCode }
        throw $exception
      }
      $script:childReport = Get-Content -LiteralPath $androidReportPath -Raw | ConvertFrom-Json
      $script:reportedFrontendCommit = $script:childReport.frontendCommit
      $script:reportedBackendCommit = $script:childReport.backendCommit
      $script:frontendCommit = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
      $childBackendDir = [string]$script:childReport.backendDir
      $script:backendCommit = (& git -C $childBackendDir rev-parse HEAD 2>$null).Trim()
      $script:evidence = $script:childReport.e2e
      $script:networkEvidence = Get-M11NetworkValueFromChild
      $script:ownership.backendOwned = [bool]$script:childReport.runtimeOwnedByRun
      $script:ownership.emulatorOwned = [bool]$script:childReport.emulator.owned
      $faultProxyProperty = $script:childReport.PSObject.Properties['faultProxy']
      if ($null -ne $faultProxyProperty -and $null -ne $faultProxyProperty.Value) {
        $script:ownership.faultProxyOwned = [bool]$faultProxyProperty.Value.owned
      }
      if ($childExitCode -ne 0) {
        $exception = [InvalidOperationException]::new('Android offline-sync smoke failed.')
        $exception.Data['ExitCode'] = $childExitCode
        throw $exception
      }
    }
  }
} finally {
  $cleanup.attempted = $true
  Add-M11CleanupCommand 'restore-fault-proxy'
  Add-M11CleanupCommand 'restore-airplane-mode'
  Add-M11CleanupCommand 'restore-wifi'
  Add-M11CleanupCommand 'stop-owned-driver'
  Add-M11CleanupCommand 'stop-owned-fault-proxy'
  if ($ownership.emulatorOwned) { Add-M11CleanupCommand 'stop-owned-avd' }
  if ($ownership.backendOwned) { Add-M11CleanupCommand 'stop-owned-backend' }
  $cleanup.networkRestored = $cleanupErrors.Count -eq 0
  $cleanup.ownedProcessesStopped = $cleanupErrors.Count -eq 0
  if ($null -ne $childReport) {
    $cleanup.networkRestored = [bool]$childReport.baselineRestore.ok -and
      [bool]$childReport.adbStateRestore.ok -and
      [bool]$childReport.faultProxyCleanup.ok
    $cleanup.ownedProcessesStopped = [bool]$childReport.baselineRestore.ok -and
      [bool]$childReport.faultProxyCleanup.ok
  }
  $cleanup.ok = $cleanupErrors.Count -eq 0 -and
    $cleanup.networkRestored -and $cleanup.ownedProcessesStopped
  $cleanup.errors = @($cleanupErrors)
}

if (-not $cleanup.ok -and $firstExitCode -eq 0) {
  $firstExitCode = 2
  $failedStep = 'cleanup'
}
Add-M11Command 'validate-evidence'
try {
  [void](Assert-NetworkEvidence -Candidate $script:networkEvidence)
  $script:networkEvidenceErrors = @()
} catch {
  if ($_.Exception.Data.Contains('Errors')) {
    $script:networkEvidenceErrors = @($_.Exception.Data['Errors'])
  } else {
    $script:networkEvidenceErrors = @($_.Exception.Message)
  }
}
$evidenceErrors = @(
  @(Get-M11EvidenceErrors $evidence) +
    @(Get-M11CommitErrors) +
    @($script:networkEvidenceErrors)
)
if ($TestMode -and $FailStep -eq 'validate-evidence' -and $firstExitCode -eq 0) {
  $firstExitCode = 23
  $failedStep = 'validate-evidence'
} elseif ($evidenceErrors.Count -gt 0 -and $firstExitCode -eq 0) {
  $firstExitCode = 2
  $failedStep = 'validate-evidence'
}
Add-M11Command 'write-report'

$forbidden = $evidenceErrors -contains 'M11 evidence contains a forbidden secret or raw key field.'
$networkBackendTargetPort = Get-M11NetworkValue `
  -Name 'backendTargetPort' `
  -Fallback $plan.backendTargetPort
$networkOwnedBridgePort = Get-M11NetworkValue `
  -Name 'ownedBridgePort' `
  -Fallback $plan.ownedBridgePort
$networkFaultProxyPort = Get-M11NetworkValue `
  -Name 'faultProxyPort' `
  -Fallback $plan.faultProxyPort
$networkConnectionChain = Get-M11NetworkValue `
  -Name 'connectionChain' `
  -Fallback $plan.connectionChain
$report = [pscustomobject][ordered]@{
  schemaVersion = 1
  target = 'android-m11'
  ok = $firstExitCode -eq 0 -and $cleanup.ok -and $evidenceErrors.Count -eq 0
  exitCode = $firstExitCode
  failedStep = $failedStep
  frontendCommit = $frontendCommit
  backendCommit = $backendCommit
  androidDevice = $AndroidDevice
  backendPort = $BackendPort
  backendTargetPort = $networkBackendTargetPort
  ownedBridgePort = $networkOwnedBridgePort
  faultProxyPort = $networkFaultProxyPort
  connectionChain = $networkConnectionChain
  portOwnership = $plan.portOwnership
  hostBridge = Get-M11NetworkValue -Name 'hostBridge'
  faultProxy = Get-M11NetworkValue -Name 'faultProxy'
  routeValidation = Get-M11NetworkValue -Name 'routeValidation'
  networkEvidence = $script:networkEvidence
  networkEvidenceErrors = @($script:networkEvidenceErrors)
  ownership = $ownership
  cleanup = $cleanup
  thresholds = $thresholds
  evidence = if ($forbidden) { $null } else { $evidence }
  evidenceErrors = $evidenceErrors
  childReport = if ($TestMode) { $null } else { $androidReportPath }
  steps = @($steps)
  artifacts = [pscustomobject][ordered]@{
    androidReport = $androidReportPath
    flutterOutput = $flutterOutputPath
  }
}
$temporaryReport = "$ReportPath.tmp-$PID"
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryReport -Encoding UTF8
Move-Item -LiteralPath $temporaryReport -Destination $ReportPath -Force
if (-not [string]::IsNullOrWhiteSpace($CommandRecordPath)) {
  $recordDirectory = Split-Path -Parent $CommandRecordPath
  if (-not [string]::IsNullOrWhiteSpace($recordDirectory)) {
    New-Item -ItemType Directory -Force -Path $recordDirectory | Out-Null
  }
  @($commands) | ConvertTo-Json | Set-Content -LiteralPath $CommandRecordPath -Encoding UTF8
}
if ($Output -eq 'Json') {
  Get-Content -LiteralPath $ReportPath -Raw | Write-Output
} elseif ($firstExitCode -ne 0) {
  [Console]::Error.WriteLine(
    "M11 smoke failed at '$failedStep'. Evidence errors: $($evidenceErrors -join '; ')"
  )
} else {
  Write-Host "M11 smoke report: $ReportPath"
}
exit $firstExitCode
