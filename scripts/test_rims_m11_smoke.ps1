param([switch]$SkipSourceContract)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptDir 'rims_m11_smoke.ps1'

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Test-StrictInteger {
  param($Value)
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
}

function Assert-StrictNetworkEvidence {
  param($Evidence, [string]$Message)
  Assert-True -Condition ($null -ne $Evidence) -Message "$Message Network evidence is missing."
  foreach ($portName in @(
      'backendTargetPort', 'ownedBridgePort', 'faultProxyPort'
    )) {
    Assert-True `
      -Condition ((Test-StrictInteger $Evidence.$portName) -and
        $Evidence.$portName -ge 1 -and $Evidence.$portName -le 65535) `
      -Message "$Message '$portName' is not a strict valid integer port."
  }
  foreach ($identityName in @('hostBridge', 'faultProxy')) {
    $identity = $Evidence.$identityName
    $parsedStart = [DateTimeOffset]::MinValue
    Assert-True `
      -Condition ($null -ne $identity -and $identity.owned -is [bool] -and
        $identity.owned -and (Test-StrictInteger $identity.windowsPid) -and
        $identity.windowsPid -gt 0 -and
        $identity.windowsProcessStartTimeUtc -is [string] -and
        [DateTimeOffset]::TryParse(
          $identity.windowsProcessStartTimeUtc,
          [ref]$parsedStart
        )) `
      -Message "$Message '$identityName' identity is malformed."
  }
  Assert-Equal -Actual $Evidence.hostBridge.listenPort -Expected $Evidence.ownedBridgePort -Message "$Message host bridge listen port."
  Assert-Equal -Actual $Evidence.hostBridge.upstreamPort -Expected $Evidence.backendTargetPort -Message "$Message host bridge upstream port."
  Assert-Equal -Actual $Evidence.faultProxy.listenPort -Expected $Evidence.faultProxyPort -Message "$Message fault proxy listen port."
  Assert-Equal -Actual $Evidence.faultProxy.upstreamPort -Expected $Evidence.ownedBridgePort -Message "$Message fault proxy upstream port."
  Assert-True `
    -Condition ($Evidence.routeValidation.ok -is [bool] -and
      $Evidence.routeValidation.ok -and
      $Evidence.routeValidation.proxyReachedVerifiedBackend -is [bool] -and
      $Evidence.routeValidation.proxyReachedVerifiedBackend -and
      $Evidence.routeValidation.unownedListenerReached -is [bool] -and
      -not $Evidence.routeValidation.unownedListenerReached -and
      $Evidence.routeValidation.expectedBackendIdentity -ceq
        $Evidence.routeValidation.observedBackendIdentity) `
    -Message "$Message route validation is malformed."
}

function Invoke-ExpectFailure {
  param(
    [string[]]$Arguments,
    [int]$ExpectedExitCode,
    [string]$Message
  )
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& powershell.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Message Expected exit '$ExpectedExitCode', got '$exitCode': $($output -join ' ')"
  }
  return $output
}

if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
  throw "Missing M11 smoke wrapper: $wrapper"
}
$wrapperText = Get-Content -LiteralPath $wrapper -Raw -Encoding UTF8
foreach ($childCleanupGate in @(
    'childReport.baselineRestore.ok',
    'childReport.adbStateRestore.ok',
    'childReport.faultProxyCleanup.ok'
  )) {
  Assert-True `
    -Condition ($wrapperText.Contains($childCleanupGate)) `
    -Message "M11 wrapper omitted child cleanup gate '$childCleanupGate'."
}
$integrationTestPath = Join-Path `
  $scriptDir `
  '..\rims_frontend\integration_test\m11_offline_sync_test.dart'
$integrationTestText = Get-Content -LiteralPath $integrationTestPath -Raw -Encoding UTF8
foreach ($faultAction in @(
    'airplane-mode', 'latency', 'packet-loss', 'unreachable', 'wifi-switch',
    'unknown-response', 'duplicate-delivery', 'server-conflict',
    'stale-session', 'stale-permission'
  )) {
  Assert-True `
    -Condition ($integrationTestText.Contains("_fault('$faultAction'")) `
    -Message "M11 Android journey omitted fault action '$faultAction'."
}
Assert-True `
  -Condition ($integrationTestText.Contains("M9-E2E:M11:`$runId:")) `
  -Message 'M11 records must use the M9 reset namespace.'
$m11NamespaceSample = 'M9-E2E:M11:self-test:queued'
Assert-True `
  -Condition ($m11NamespaceSample -like 'M9-E2E:*') `
  -Message 'M11 namespace must match the M9 reset wildcard.'
$configText = Get-Content `
  -LiteralPath (Join-Path $scriptDir '..\rims_frontend\integration_test\support\rims_e2e_config.dart') `
  -Raw `
  -Encoding UTF8
Assert-True `
  -Condition ($configText.Contains("bool.fromEnvironment('RIMS_E2E_M11')")) `
  -Message 'M11 fault hooks must default to disabled without an explicit define.'
Assert-True `
  -Condition ($configText.Contains("'RIMS_E2E_M11_STAGE'")) `
  -Message 'M11 process staging must require an explicit test define.'
if (-not $SkipSourceContract) {
foreach ($forbiddenJourneyBypass in @(
    'await documents.saveDraft()',
    'documents.prepareOfflineSubmission(',
    'documents.confirmOfflineSubmission(',
    'viewModel.reviewAndSync(',
    'syncCenter.discard('
  )) {
  Assert-True `
    -Condition (-not $integrationTestText.Contains($forbiddenJourneyBypass)) `
    -Message "M11 journey bypasses UI with '$forbiddenJourneyBypass'."
}
foreach ($requiredJourneySurface in @(
    "Key('document-scan-product-button')",
    "Key('scanner-permission-retry')",
    "Key('profile-draft-manager-entry')",
    "Key('document-create-button')",
    "description: 'confirm offline queue button'",
    "description: 'review operation `$operationId'",
    "description: 'confirm explicit sync `$operationId'",
    "description: 'discard conflicted operation'",
    "description: 'open replacement conflict dialog'",
    'widget.decoration?.labelText ==',
    "description: 'confirm conflict replacement'",
    'expect(replacement.replacementOf, replacementConflict.operationId);',
    '_recordOperation(replacement, operationIds, idempotencyHashes)',
    'repository.download(',
    'rims_attachments',
    "'RIMS_E2E_STAGE `$"
  )) {
  Assert-True `
    -Condition ($integrationTestText.Contains($requiredJourneySurface)) `
    -Message "M11 journey omitted real surface '$requiredJourneySurface'."
}
}

$plan = (& $wrapper `
    -ListPlan `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -FaultProxyPort 18081 `
    -Output Json) -join "`n" | ConvertFrom-Json

Assert-Equal -Actual $plan.target -Expected 'android-m11' -Message 'Target.'
Assert-Equal -Actual $plan.phase -Expected 'offline-sync' -Message 'Phase.'
Assert-Equal -Actual $plan.androidDevice -Expected 'Medium_Phone_API_36.1' -Message 'AVD.'
Assert-Equal -Actual $plan.backendPort -Expected 18080 -Message 'Backend port.'
Assert-Equal -Actual $plan.backendTargetPort -Expected 18080 -Message 'Backend target port.'
Assert-True `
  -Condition ($plan.ownedBridgePort -ne $plan.faultProxyPort) `
  -Message 'Owned bridge must be distinct from the fault proxy.'
Assert-Equal -Actual $plan.faultProxyPort -Expected 18081 -Message 'Fault proxy port.'
Assert-Equal `
  -Actual $plan.connectionChain `
  -Expected 'emulator->owned-fault-proxy->owned-host-bridge->verified-wsl-backend' `
  -Message 'Owned network chain.'
Assert-Equal `
  -Actual (@($plan.scenarios) -join '|') `
  -Expected 'airplane-mode|latency|packet-loss|unreachable-api|wifi-switch|process-recreation|stale-session|stale-permission|duplicate-delivery|server-conflict|database-corruption' `
  -Message 'Fault scenario order.'
Assert-Equal `
  -Actual $plan.deterministicInjection.productionDefault `
  -Expected 'disabled' `
  -Message 'Production fault boundary.'
Assert-Equal `
  -Actual $plan.deterministicInjection.enableDefine `
  -Expected 'RIMS_E2E_M11=true' `
  -Message 'M11 enable define.'
Assert-Equal `
  -Actual $plan.deterministicInjection.controlDefine `
  -Expected 'RIMS_E2E_M11_FAULT_CONTROL_URL' `
  -Message 'Fault control define.'
Assert-Equal `
  -Actual $plan.deterministicInjection.networkOwnership `
  -Expected 'owned-host-fault-proxy-restored-in-finally' `
  -Message 'Network ownership.'
Assert-True `
  -Condition ([bool]$plan.lifecycle.startsFromStoppedState) `
  -Message 'M11 must self-start from stopped state.'
Assert-Equal `
  -Actual $plan.lifecycle.backend `
  -Expected 'start-if-stopped-stop-only-if-owned' `
  -Message 'Backend lifecycle.'
Assert-Equal `
  -Actual $plan.lifecycle.emulator `
  -Expected 'reuse-explicit-avd-or-start-and-stop-exact-owned-process' `
  -Message 'AVD lifecycle.'
Assert-Equal `
  -Actual $plan.lifecycle.driver `
  -Expected 'owned-flutter-test-process' `
  -Message 'Driver lifecycle.'
Assert-Equal `
  -Actual (@($plan.thresholds.PSObject.Properties.Name) -join '|') `
  -Expected 'cachedFirstContentMs|draftSaveMs|draftRecoveryMs|outboxEnqueueMs|confirmedSyncMs|databaseBytes|maxDuplicateDocuments|maxDuplicateInventoryTransactions' `
  -Message 'Threshold schema.'
Assert-Equal -Actual $plan.thresholds.cachedFirstContentMs -Expected 500 -Message 'Cache threshold.'
Assert-Equal -Actual $plan.thresholds.draftSaveMs -Expected 250 -Message 'Draft threshold.'
Assert-Equal -Actual $plan.thresholds.draftRecoveryMs -Expected 1000 -Message 'Recovery threshold.'
Assert-Equal -Actual $plan.thresholds.outboxEnqueueMs -Expected 250 -Message 'Enqueue threshold.'
Assert-Equal -Actual $plan.thresholds.confirmedSyncMs -Expected 10000 -Message 'Sync threshold.'
Assert-Equal -Actual $plan.thresholds.databaseBytes -Expected 26214400 -Message 'Database threshold.'

$tempRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-m11-smoke-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
New-Item -ItemType Directory -Path $resolvedTempRoot | Out-Null
$previousChildFixture = $env:RIMS_M11_TEST_CHILD_REPORT_FIXTURE
try {
  $fixturePath = Join-Path $resolvedTempRoot 'valid-fixture.json'
  $fixture = [ordered]@{
    cacheReadLatencyMs = 120
    draftSaveLatencyMs = 80
    processRecoveryLatencyMs = 400
    outboxEnqueueLatencyMs = 90
    syncTotalMs = 2400
    intentionalFaultDelayMs = 750
    operationIds = @('op-upload', 'op-create', 'op-complete')
    idempotencyKeyHashes = @(
      ('a' * 64),
      ('b' * 64),
      ('c' * 64)
    )
    stockBefore = 100
    stockAfter = 98
    serverDocumentCount = 1
    duplicateDocumentCount = 0
    duplicateInventoryTransactionCount = 0
    attachmentHash = ('d' * 64)
    stagedAttachmentHash = ('d' * 64)
    attachmentCount = 1
    databaseBytes = 1048576
    processStages = @(
      [ordered]@{ stage = 'seed'; processId = 101; startedAt = '2026-07-14T00:00:00Z' },
      [ordered]@{ stage = 'offline-draft'; processId = 202; startedAt = '2026-07-14T00:01:00Z' },
      [ordered]@{ stage = 'recovery'; processId = 303; startedAt = '2026-07-14T00:02:00Z' }
    )
    cleanup = [ordered]@{
      accountCacheCleared = $true
      outboxCleared = $true
      stagingCleared = $true
      stagingDirectoryEmpty = $true
      baselineRestored = $true
    }
    journey = [ordered]@{
      onlineSeeded = $true
      cachedInventoryRead = $true
      cachedReportRead = $true
      cachedDetailRead = $true
      scannerCallbackCompleted = $true
      autosaveCompleted = $true
      draftRecovered = $true
      nativeDatabaseReopened = $true
      queuedVisible = $true
      explicitSyncConfirmed = $true
      unknownResponseProbed = $true
      idempotentReplaySingleEffect = $true
      attachmentDependencyCompleted = $true
      staleSessionBlocked = $true
      stalePermissionBlocked = $true
      attentionVisible = $true
      conflictVisible = $true
      conflictResolved = $true
      conflictReplacementCreated = $true
      conflictReplacementVisible = $true
      serverAttachmentVerified = $true
      serverLifecycleVerified = $true
      logoutCleanupCompleted = $true
      databaseCorruptionQuarantined = $true
    }
  }
  $fixture | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath $fixturePath `
    -Encoding UTF8

  $validNetworkEvidence = [ordered]@{
    backendTargetPort = 18080
    ownedBridgePort = [int]$plan.ownedBridgePort
    faultProxyPort = 18081
    connectionChain = 'emulator->owned-fault-proxy->owned-host-bridge->verified-wsl-backend'
    hostBridge = [ordered]@{
      owned = $true
      windowsPid = 4101
      windowsProcessStartTimeUtc = '2026-07-14T00:00:00Z'
      listenAddress = '127.0.0.1'
      listenPort = [int]$plan.ownedBridgePort
      upstreamAddress = '::1'
      upstreamPort = 18080
      backendIdentityValidated = $true
    }
    faultProxy = [ordered]@{
      owned = $true
      windowsPid = 4102
      windowsProcessStartTimeUtc = '2026-07-14T00:00:01Z'
      listenAddress = '127.0.0.1'
      listenPort = 18081
      upstreamAddress = '127.0.0.1'
      upstreamPort = [int]$plan.ownedBridgePort
      upstreamOwnership = 'validated-owned-host-bridge'
    }
    routeValidation = [ordered]@{
      ok = $true
      proxyReachedVerifiedBackend = $true
      unownedListenerReached = $false
      expectedBackendIdentity = 'A'
      observedBackendIdentity = 'A'
      backend = 'A'
      backendTargetPort = 18080
      ownedBridgePort = [int]$plan.ownedBridgePort
      faultProxyPort = 18081
    }
  }
  $childFixturePath = Join-Path $resolvedTempRoot 'valid-child-report.json'
  $childFixture = [ordered]@{
    ok = $true
    exitCode = 0
    frontendCommit = (& git -C (Resolve-Path (Join-Path $scriptDir '..')) rev-parse HEAD).Trim()
    backendCommit = ('b' * 40)
    backendDir = 'E:\fixture\backend'
    runtimeOwnedByRun = $true
    emulator = [ordered]@{ owned = $true }
    baselineRestore = [ordered]@{ ok = $true }
    adbStateRestore = [ordered]@{ ok = $true }
    faultProxyCleanup = [ordered]@{ ok = $true }
    networkEvidence = $validNetworkEvidence
    e2e = $fixture
  }
  $childFixture | ConvertTo-Json -Depth 20 | Set-Content `
    -LiteralPath $childFixturePath `
    -Encoding UTF8
  $env:RIMS_M11_TEST_CHILD_REPORT_FIXTURE = $childFixturePath

  $reportPath = Join-Path $resolvedTempRoot 'success-report.json'
  $recordPath = Join-Path $resolvedTempRoot 'success-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -BackendPort 18080 `
    -FaultProxyPort 18081 `
    -BackendDir 'E:\fixture\backend' `
    -TestMode `
    -FixturePath $fixturePath `
    -ReportPath $reportPath `
    -ArtifactRoot (Join-Path $resolvedTempRoot 'success-artifacts') `
    -CommandRecordPath $recordPath
  if ($LASTEXITCODE -ne 0) {
    throw "Valid stopped-state M11 self-test failed with '$LASTEXITCODE'."
  }
  $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  $commands = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
  Assert-Equal `
    -Actual (@($commands) -join '|') `
    -Expected 'inspect-runtime|select-port:18081|select-avd:Medium_Phone_API_36.1|start-backend:18080|start-avd:Medium_Phone_API_36.1|start-fault-proxy:18081|exercise:airplane-mode|exercise:latency|exercise:packet-loss|exercise:unreachable-api|exercise:wifi-switch|exercise:process-recreation|exercise:stale-session|exercise:stale-permission|exercise:duplicate-delivery|exercise:server-conflict|exercise:database-corruption|run-android-offline-sync|restore-fault-proxy|restore-airplane-mode|restore-wifi|stop-owned-driver|stop-owned-fault-proxy|stop-owned-avd|stop-owned-backend|validate-evidence|write-report' `
    -Message 'Stopped-state command order.'
  Assert-Equal `
    -Actual (@($report.steps.name) -join '|') `
    -Expected 'airplane-mode|latency|packet-loss|unreachable-api|wifi-switch|process-recreation|stale-session|stale-permission|duplicate-delivery|server-conflict|database-corruption|android-offline-sync' `
    -Message 'Fake fault executor step order.'
  Assert-Equal -Actual $report.ok -Expected $true -Message 'Success report flag.'
  Assert-Equal -Actual $report.ownership.backendOwned -Expected $true -Message 'Backend ownership.'
  Assert-Equal -Actual $report.ownership.emulatorOwned -Expected $true -Message 'Emulator ownership.'
  Assert-Equal -Actual $report.ownership.faultProxyOwned -Expected $true -Message 'Proxy ownership.'
  Assert-Equal -Actual $report.backendTargetPort -Expected 18080 -Message 'Report backend target.'
  Assert-Equal -Actual $report.ownedBridgePort -Expected $plan.ownedBridgePort -Message 'Report owned bridge.'
  Assert-Equal -Actual $report.faultProxyPort -Expected 18081 -Message 'Report fault proxy.'
  Assert-StrictNetworkEvidence `
    -Evidence $report.networkEvidence `
    -Message 'M11 aggregate report.'
  Assert-Equal -Actual $report.networkEvidence.hostBridge.windowsPid -Expected 4101 -Message 'Aggregate host bridge PID.'
  Assert-Equal -Actual $report.networkEvidence.faultProxy.windowsPid -Expected 4102 -Message 'Aggregate fault proxy PID.'
  Assert-Equal -Actual $report.cleanup.networkRestored -Expected $true -Message 'Network cleanup.'
  Assert-Equal -Actual $report.cleanup.ownedProcessesStopped -Expected $true -Message 'Owned process cleanup.'
  Assert-True -Condition ($report.evidence.cacheReadLatencyMs -is [ValueType]) -Message 'Cache metric must be numeric.'
  Assert-True -Condition ($report.evidence.cleanup.accountCacheCleared -is [bool]) -Message 'Cleanup evidence must be Boolean.'
  Assert-True -Condition ($report.frontendCommit -match '^[0-9a-f]{40}$') -Message 'Frontend commit missing.'
  Assert-True -Condition ($report.backendCommit -match '^[0-9a-f]{40}$') -Message 'Backend commit missing.'

  $aggregateNetworkCases = @(
    @{ Name = 'missing-host-identity'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('hostBridge')
      } },
    @{ Name = 'missing-proxy-identity'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('faultProxy')
      } },
    @{ Name = 'zero-pid'; Mutate = {
        param($value) $value.hostBridge.windowsPid = 0
      } },
    @{ Name = 'string-pid'; Mutate = {
        param($value) $value.faultProxy.windowsPid = '4102'
      } },
    @{ Name = 'bad-start-time'; Mutate = {
        param($value) $value.hostBridge.windowsProcessStartTimeUtc = 'bad-time'
      } },
    @{ Name = 'string-owned'; Mutate = {
        param($value) $value.faultProxy.owned = 'true'
      } },
    @{ Name = 'bridge-listen-mismatch'; Mutate = {
        param($value) $value.hostBridge.listenPort = $value.ownedBridgePort + 10
      } },
    @{ Name = 'bridge-upstream-mismatch'; Mutate = {
        param($value) $value.hostBridge.upstreamPort = $value.backendTargetPort + 10
      } },
    @{ Name = 'proxy-listen-mismatch'; Mutate = {
        param($value) $value.faultProxy.listenPort = $value.faultProxyPort + 10
      } },
    @{ Name = 'proxy-upstream-mismatch'; Mutate = {
        param($value) $value.faultProxy.upstreamPort = $value.ownedBridgePort + 10
      } },
    @{ Name = 'route-false'; Mutate = {
        param($value) $value.routeValidation.ok = $false
      } },
    @{ Name = 'route-missing'; Mutate = {
        param($value) $value.PSObject.Properties.Remove('routeValidation')
      } },
    @{ Name = 'route-fake-listener'; Mutate = {
        param($value)
        $value.routeValidation.expectedBackendIdentity = 'B'
        $value.routeValidation.observedBackendIdentity = 'B'
        $value.routeValidation.backend = 'B'
      } },
    @{ Name = 'route-unverified-identity'; Mutate = {
        param($value)
        $value.routeValidation.expectedBackendIdentity = 'C'
        $value.routeValidation.observedBackendIdentity = 'C'
        $value.routeValidation.backend = 'C'
      } },
    @{ Name = 'string-port'; Mutate = {
        param($value) $value.backendTargetPort = '18080'
      } },
    @{ Name = 'port-out-of-range'; Mutate = {
        param($value) $value.faultProxyPort = 65536
      } },
    @{ Name = 'port-negative'; Mutate = {
        param($value) $value.ownedBridgePort = -1
      } }
  )
  foreach ($networkCase in $aggregateNetworkCases) {
    $invalidChild = $childFixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    & $networkCase.Mutate $invalidChild.networkEvidence
    $invalidChildPath = Join-Path $resolvedTempRoot "invalid-child-$($networkCase.Name).json"
    $invalidChild | ConvertTo-Json -Depth 20 | Set-Content `
      -LiteralPath $invalidChildPath `
      -Encoding UTF8
    $invalidAggregateReportPath = Join-Path $resolvedTempRoot "invalid-child-$($networkCase.Name)-report.json"
    $invalidAggregateRecordPath = Join-Path $resolvedTempRoot "invalid-child-$($networkCase.Name)-commands.json"
    Invoke-ExpectFailure `
      -ExpectedExitCode 2 `
      -Message "Aggregate malformed network '$($networkCase.Name)'." `
      -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
        '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
        '-FixturePath', $fixturePath,
        '-TestChildReportFixturePath', $invalidChildPath,
        '-ReportPath', $invalidAggregateReportPath,
        '-ArtifactRoot', (Join-Path $resolvedTempRoot "invalid-child-$($networkCase.Name)-artifacts"),
        '-CommandRecordPath', $invalidAggregateRecordPath
      ) | Out-Null
    $invalidAggregate = Get-Content -LiteralPath $invalidAggregateReportPath -Raw |
      ConvertFrom-Json
    $invalidAggregateCommands = @(Get-Content -LiteralPath $invalidAggregateRecordPath -Raw |
        ConvertFrom-Json | ForEach-Object { $_ })
    Assert-Equal -Actual $invalidAggregate.ok -Expected $false -Message "Aggregate malformed network '$($networkCase.Name)' report."
    Assert-Equal -Actual $invalidAggregate.failedStep -Expected 'validate-evidence' -Message "Aggregate malformed network '$($networkCase.Name)' gate."
    Assert-Equal -Actual $invalidAggregate.cleanup.attempted -Expected $true -Message "Aggregate malformed network '$($networkCase.Name)' cleanup attempt."
    Assert-Equal -Actual $invalidAggregate.cleanup.ok -Expected $true -Message "Aggregate malformed network '$($networkCase.Name)' cleanup result."
    foreach ($cleanupCommand in @(
        'restore-fault-proxy', 'restore-airplane-mode', 'restore-wifi',
        'stop-owned-driver', 'stop-owned-fault-proxy'
      )) {
      Assert-True `
        -Condition ($invalidAggregateCommands -contains $cleanupCommand) `
        -Message "Aggregate malformed network '$($networkCase.Name)' omitted cleanup '$cleanupCommand'."
    }
  }

  $preExistingReportPath = Join-Path $resolvedTempRoot 'pre-existing-report.json'
  $preExistingRecordPath = Join-Path $resolvedTempRoot 'pre-existing-commands.json'
  & $wrapper `
    -AndroidDevice 'Medium_Phone_API_36.1' `
    -TestMode `
    -TestPreExistingRuntime `
    -TestPreExistingEmulator `
    -FixturePath $fixturePath `
    -ReportPath $preExistingReportPath `
    -ArtifactRoot (Join-Path $resolvedTempRoot 'pre-existing-artifacts') `
    -CommandRecordPath $preExistingRecordPath
  if ($LASTEXITCODE -ne 0) { throw 'Pre-existing runtime fixture failed.' }
  $preExisting = Get-Content -LiteralPath $preExistingReportPath -Raw | ConvertFrom-Json
  $preExistingCommands = Get-Content -LiteralPath $preExistingRecordPath -Raw | ConvertFrom-Json
  Assert-Equal -Actual $preExisting.ownership.backendOwned -Expected $false -Message 'Existing backend ownership.'
  Assert-Equal -Actual $preExisting.ownership.emulatorOwned -Expected $false -Message 'Existing AVD ownership.'
  Assert-True `
    -Condition (-not (@($preExistingCommands) -contains 'stop-owned-backend')) `
    -Message 'Pre-existing backend must be preserved.'
  Assert-True `
    -Condition (-not (@($preExistingCommands) -contains 'stop-owned-avd')) `
    -Message 'Pre-existing AVD must be preserved.'

  $failureReportPath = Join-Path $resolvedTempRoot 'first-failure-report.json'
  $failureRecordPath = Join-Path $resolvedTempRoot 'first-failure-commands.json'
  Invoke-ExpectFailure `
    -ExpectedExitCode 23 `
    -Message 'Injected packet-loss failure.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1',
      '-TestMode', '-FixturePath', $fixturePath,
      '-FailStep', 'packet-loss',
      '-TestCleanupFailStep', 'restore-fault-proxy',
      '-ReportPath', $failureReportPath,
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'failure-artifacts'),
      '-CommandRecordPath', $failureRecordPath
    ) | Out-Null
  $failure = Get-Content -LiteralPath $failureReportPath -Raw | ConvertFrom-Json
  $failureCommands = Get-Content -LiteralPath $failureRecordPath -Raw | ConvertFrom-Json
  Assert-Equal -Actual $failure.failedStep -Expected 'packet-loss' -Message 'First failure preservation.'
  Assert-Equal -Actual $failure.exitCode -Expected 23 -Message 'First exit preservation.'
  Assert-Equal -Actual $failure.cleanup.attempted -Expected $true -Message 'Cleanup attempted.'
  Assert-Equal -Actual $failure.cleanup.ok -Expected $false -Message 'Injected cleanup failure visible.'
  foreach ($cleanupCommand in @(
      'restore-fault-proxy',
      'restore-airplane-mode',
      'restore-wifi',
      'stop-owned-driver',
      'stop-owned-fault-proxy',
      'stop-owned-avd',
      'stop-owned-backend'
    )) {
    Assert-True `
      -Condition (@($failureCommands) -contains $cleanupCommand) `
      -Message "Cleanup omitted '$cleanupCommand'."
  }

  $cleanupOnlyReportPath = Join-Path $resolvedTempRoot 'cleanup-only-report.json'
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Cleanup-only failure.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1',
      '-TestMode', '-FixturePath', $fixturePath,
      '-TestCleanupFailStep', 'restore-wifi',
      '-ReportPath', $cleanupOnlyReportPath,
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'cleanup-only-artifacts')
    ) | Out-Null
  $cleanupOnly = Get-Content -LiteralPath $cleanupOnlyReportPath -Raw | ConvertFrom-Json
  Assert-Equal `
    -Actual $cleanupOnly.failedStep `
    -Expected 'cleanup' `
    -Message 'Cleanup-only failed step.'
  Assert-Equal `
    -Actual $cleanupOnly.cleanup.ok `
    -Expected $false `
    -Message 'Cleanup-only result.'

  $gateCases = @(
    @{ Name = 'negative-cache'; Property = 'cacheReadLatencyMs'; Value = -1 },
    @{ Name = 'cache'; Property = 'cacheReadLatencyMs'; Value = 501 },
    @{ Name = 'draft'; Property = 'draftSaveLatencyMs'; Value = 251 },
    @{ Name = 'recovery'; Property = 'processRecoveryLatencyMs'; Value = 1001 },
    @{ Name = 'enqueue'; Property = 'outboxEnqueueLatencyMs'; Value = 251 },
    @{ Name = 'sync'; Property = 'syncTotalMs'; Value = 10001 },
    @{ Name = 'database'; Property = 'databaseBytes'; Value = 26214401 },
    @{ Name = 'missing-server-attachment'; Property = 'attachmentCount'; Value = 0 },
    @{ Name = 'documents'; Property = 'duplicateDocumentCount'; Value = 1 },
    @{ Name = 'transactions'; Property = 'duplicateInventoryTransactionCount'; Value = 1 }
  )
  foreach ($case in $gateCases) {
    $invalid = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $invalid.($case.Property) = $case.Value
    $invalidPath = Join-Path $resolvedTempRoot "invalid-$($case.Name).json"
    $invalid | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $invalidPath -Encoding UTF8
    Invoke-ExpectFailure `
      -ExpectedExitCode 2 `
      -Message "Threshold gate '$($case.Name)'." `
      -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
        '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
        '-FixturePath', $invalidPath,
        '-ReportPath', (Join-Path $resolvedTempRoot "invalid-$($case.Name)-report.json"),
        '-ArtifactRoot', (Join-Path $resolvedTempRoot "invalid-$($case.Name)-artifacts")
      ) | Out-Null
  }

  $scalarOperationsPath = Join-Path $resolvedTempRoot 'scalar-operations.json'
  $scalarOperations = $fixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $scalarOperations.operationIds = 123
  $scalarOperations | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath $scalarOperationsPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Scalar operation IDs.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $scalarOperationsPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'scalar-operations-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'scalar-operations-artifacts')
    ) | Out-Null

  $scalarHashPath = Join-Path $resolvedTempRoot 'scalar-hash.json'
  $scalarHash = $fixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $scalarHash.idempotencyKeyHashes = 'a' * 64
  $scalarHash | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath $scalarHashPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Scalar idempotency hash.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $scalarHashPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'scalar-hash-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'scalar-hash-artifacts')
    ) | Out-Null

  $wrongServerHashPath = Join-Path $resolvedTempRoot 'wrong-server-hash.json'
  $wrongServerHash = $fixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $wrongServerHash.attachmentHash = 'e' * 64
  $wrongServerHash | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath $wrongServerHashPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Server attachment hash mismatch.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $wrongServerHashPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'wrong-server-hash-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'wrong-server-hash-artifacts')
    ) | Out-Null

  $stagingResidualPath = Join-Path $resolvedTempRoot 'staging-residual.json'
  $stagingResidual = $fixture | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $stagingResidual.cleanup.stagingDirectoryEmpty = $false
  $stagingResidual | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath $stagingResidualPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Physical staging residue.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $stagingResidualPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'staging-residual-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'staging-residual-artifacts')
    ) | Out-Null

  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Malformed frontend commit.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $fixturePath, '-TestFrontendCommit', 'bad-commit',
      '-ReportPath', (Join-Path $resolvedTempRoot 'bad-commit-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'bad-commit-artifacts')
    ) | Out-Null
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Mismatched frontend commit.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $fixturePath, '-TestFrontendCommit', ('a' * 40),
      '-ReportPath', (Join-Path $resolvedTempRoot 'mismatch-commit-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'mismatch-commit-artifacts')
    ) | Out-Null

  $wrongTypes = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $wrongTypes.cacheReadLatencyMs = '120'
  $wrongTypes.cleanup.accountCacheCleared = 'true'
  $wrongTypesPath = Join-Path $resolvedTempRoot 'wrong-types.json'
  $wrongTypes | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath $wrongTypesPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Strict evidence types.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $wrongTypesPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'wrong-types-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'wrong-types-artifacts')
    ) | Out-Null

  $missing = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $missing.PSObject.Properties.Remove('attachmentHash')
  $missingPath = Join-Path $resolvedTempRoot 'missing-evidence.json'
  $missing | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingPath -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Missing evidence gate.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $missingPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'missing-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'missing-artifacts')
    ) | Out-Null

  $missingCorruption = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $missingCorruption.journey.PSObject.Properties.Remove(
    'databaseCorruptionQuarantined'
  )
  $missingCorruptionPath = Join-Path $resolvedTempRoot 'missing-corruption.json'
  $missingCorruption | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath $missingCorruptionPath `
    -Encoding UTF8
  Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Missing corruption evidence gate.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $missingCorruptionPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'missing-corruption-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'missing-corruption-artifacts')
    ) | Out-Null

  $secret = $fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $secret | Add-Member -NotePropertyName rawIdempotencyKey -NotePropertyValue 'RIMS-RAW-SECRET-KEY'
  $secretPath = Join-Path $resolvedTempRoot 'secret-evidence.json'
  $secret | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $secretPath -Encoding UTF8
  $secretOutput = Invoke-ExpectFailure `
    -ExpectedExitCode 2 `
    -Message 'Secret redaction gate.' `
    -Arguments @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
      '-AndroidDevice', 'Medium_Phone_API_36.1', '-TestMode',
      '-FixturePath', $secretPath,
      '-ReportPath', (Join-Path $resolvedTempRoot 'secret-report.json'),
      '-ArtifactRoot', (Join-Path $resolvedTempRoot 'secret-artifacts')
    )
  Assert-True `
    -Condition (($secretOutput -join ' ') -notmatch 'RIMS-RAW-SECRET-KEY') `
    -Message 'Raw idempotency key leaked to wrapper output.'
} finally {
  $env:RIMS_M11_TEST_CHILD_REPORT_FIXTURE = $previousChildFixture
  $candidate = [IO.Path]::GetFullPath($resolvedTempRoot)
  $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($candidate.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
      $candidate -ne $tempBase) {
    Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    throw "Refusing to clean unowned self-test path: $candidate"
  }
}

Write-Host 'M11 smoke wrapper self-test passed.'
