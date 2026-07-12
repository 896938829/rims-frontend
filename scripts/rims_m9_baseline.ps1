param(
  [string]$SampleDataPath,
  [string]$OutputPath = '.runtime\rims-local\reports\m9-baseline.json',
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$FrontendPort = 8091
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'
. $commonScript

function Get-BaselinePercentile {
  param([double[]]$Values, [double]$Percentile)
  if ($Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  $index = [Math]::Max(
    0,
    [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1)
  )
  return [double]$sorted[$index]
}

function Get-BaselineMedian {
  param([double[]]$Values)
  if ($Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  $middle = [int][Math]::Floor($sorted.Count / 2)
  if ($sorted.Count % 2 -eq 1) {
    return [double]$sorted[$middle]
  }
  return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Test-BaselineNumericValue {
  param($Value)
  return $Value -is [byte] -or
    $Value -is [sbyte] -or
    $Value -is [int16] -or
    $Value -is [uint16] -or
    $Value -is [int32] -or
    $Value -is [uint32] -or
    $Value -is [int64] -or
    $Value -is [uint64] -or
    $Value -is [single] -or
    $Value -is [double] -or
    $Value -is [decimal]
}

function ConvertTo-BaselineOperation {
  param([psobject]$Operation)
  foreach ($property in @('name', 'thresholdMs', 'samples')) {
    if ($null -eq $Operation.PSObject.Properties[$property]) {
      throw "Baseline operation omitted '$property'."
    }
  }
  $name = [string]$Operation.name
  if ([string]::IsNullOrWhiteSpace($name)) {
    throw 'Baseline operation name is empty.'
  }
  if (-not (Test-BaselineNumericValue -Value $Operation.thresholdMs)) {
    throw "Baseline operation '$name' threshold must be numeric."
  }
  $thresholdMs = [double]$Operation.thresholdMs
  if ($thresholdMs -lt 0 -or [double]::IsNaN($thresholdMs) -or
      [double]::IsInfinity($thresholdMs)) {
    throw "Baseline operation '$name' threshold is invalid."
  }
  $samples = @($Operation.samples | ForEach-Object {
      foreach ($property in @('durationMs', 'ok')) {
        if ($null -eq $_.PSObject.Properties[$property]) {
          throw "Baseline sample for '$name' omitted '$property'."
        }
      }
      if (-not (Test-BaselineNumericValue -Value $_.durationMs)) {
        throw "Baseline sample duration for '$name' must be numeric."
      }
      $durationMs = [double]$_.durationMs
      if ($durationMs -lt 0 -or [double]::IsNaN($durationMs) -or
          [double]::IsInfinity($durationMs)) {
        throw "Baseline sample duration for '$name' is invalid."
      }
      if ($_.ok -isnot [bool]) {
        throw "Baseline sample result for '$name' must be Boolean."
      }
      [pscustomobject][ordered]@{
        durationMs = $durationMs
        ok = $_.ok
        detail = if ($null -ne $_.PSObject.Properties['detail'] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.detail)) {
          ConvertTo-RimsDiagnosticSummary `
            -StandardOutput '' `
            -StandardError ([string]$_.detail)
        } else { '' }
      }
    })
  $durations = [double[]]@($samples | ForEach-Object { $_.durationMs })
  $successCount = @($samples | Where-Object { $_.ok }).Count
  $failureCount = $samples.Count - $successCount
  $p95 = Get-BaselinePercentile -Values $durations -Percentile 0.95
  return [pscustomobject][ordered]@{
    name = $name
    thresholdMs = $thresholdMs
    sampleCount = $samples.Count
    successCount = $successCount
    failureCount = $failureCount
    minMs = if ($durations.Count -gt 0) {
      [double]($durations | Measure-Object -Minimum).Minimum
    } else { $null }
    medianMs = Get-BaselineMedian -Values $durations
    p95Ms = $p95
    maxMs = if ($durations.Count -gt 0) {
      [double]($durations | Measure-Object -Maximum).Maximum
    } else { $null }
    thresholdPassed = $failureCount -eq 0 -and
      $null -ne $p95 -and
      $p95 -le $thresholdMs
    rawSamples = $samples
  }
}

function Write-BaselineReport {
  param([psobject]$Report)
  $resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
  } else { Join-Path (Get-Location).Path $OutputPath }
  $directory = Split-Path -Parent $resolvedOutput
  if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  $temporary = "$resolvedOutput.tmp-$PID"
  try {
    $Report | ConvertTo-Json -Depth 10 | Set-Content `
      -LiteralPath $temporary `
      -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $resolvedOutput -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

if (-not [string]::IsNullOrWhiteSpace($SampleDataPath)) {
  if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
    throw 'Sample-data mode requires an explicit -OutputPath.'
  }
  $sampleData = Get-Content -LiteralPath $SampleDataPath -Raw | ConvertFrom-Json
  if ($null -eq $sampleData.PSObject.Properties['operations'] -or
      @($sampleData.operations).Count -eq 0) {
    throw 'Sample-data mode requires at least one operation.'
  }
  $names = @($sampleData.operations | ForEach-Object { [string]$_.name })
  if (@($names | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
    throw 'Sample-data operation names must be unique.'
  }
  foreach ($operation in @($sampleData.operations)) {
    if ($null -eq $operation.PSObject.Properties['samples'] -or
        @($operation.samples).Count -eq 0) {
      throw "Sample-data operation '$($operation.name)' has no samples."
    }
  }
  $operations = @($sampleData.operations | ForEach-Object {
      ConvertTo-BaselineOperation -Operation $_
    })
  $report = [pscustomobject][ordered]@{
    schemaVersion = 1
    mode = 'sample-data'
    ok = @($operations | Where-Object { -not $_.thresholdPassed }).Count -eq 0
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    operations = $operations
  }
  Write-BaselineReport -Report $report
  exit $(if ($report.ok) { 0 } else { 1 })
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$localScript = Join-Path $scriptDir 'rims_local.ps1'
$runtimePaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir

$gitCommonDir = (& git -C $repoRoot rev-parse --git-common-dir).Trim()
if (-not [IO.Path]::IsPathRooted($gitCommonDir)) {
  $gitCommonDir = [IO.Path]::GetFullPath((Join-Path $repoRoot $gitCommonDir))
}
$frontendRepository = Split-Path -Parent $gitCommonDir
if ([string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
  $BackendWorkspaceRoot = Join-Path (Split-Path -Parent $frontendRepository) 'RIMS'
}
if ([string]::IsNullOrWhiteSpace($BackendDir)) {
  $frontendBranch = (& git -C $repoRoot branch --show-current).Trim()
  $backendCandidates = @(Get-ChildItem `
      -LiteralPath (Join-Path $frontendRepository '.worktrees') `
      -Directory `
      -ErrorAction SilentlyContinue | ForEach-Object {
        Join-Path $_.FullName 'rims-goProgect'
      } | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'scripts\m9_dev_seed.sh')
      })
  $matchingCandidate = @($backendCandidates | Where-Object {
      (& git -C $_ branch --show-current 2>$null).Trim() -eq $frontendBranch
    } | Select-Object -First 1)
  $BackendDir = if ($matchingCandidate.Count -gt 0) {
    $matchingCandidate[0]
  } else { Join-Path $BackendWorkspaceRoot 'rims-goProgect' }
}

function Invoke-BaselineLocalRuntime {
  param([string[]]$Arguments, [int]$TimeoutSeconds = 600)
  $execution = Invoke-RimsExternalCommand `
    -FilePath 'powershell.exe' `
    -Arguments (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localScript
      ) + $Arguments) `
    -TimeoutSeconds $TimeoutSeconds
  if ($execution.ExitCode -ne 0) {
    throw "rims_local failed: $(Get-RimsExternalCommandSummary -Result $execution)"
  }
  return $execution
}

function Measure-BaselineRequest {
  param([scriptblock]$Action)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    $value = & $Action
    $watch.Stop()
    return [pscustomobject][ordered]@{
      durationMs = [double]$watch.Elapsed.TotalMilliseconds
      ok = $true
      detail = ''
      value = $value
    }
  } catch {
    $watch.Stop()
    return [pscustomobject][ordered]@{
      durationMs = [double]$watch.Elapsed.TotalMilliseconds
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      value = $null
    }
  }
}

function Get-LatestSmokeData {
  param([string]$Name, [ValidateSet('web', 'android')][string]$Target)
  $path = Join-Path $runtimePaths.root "reports\$Name"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject][ordered]@{
      path = $path
      available = $false
      valid = $false
      error = 'Smoke report does not exist.'
      totalMs = $null
      segmentsMs = $null
      data = $null
    }
  }
  try {
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $expectedFrontendCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    $expectedBackendCommit = (& git -C $BackendDir rev-parse HEAD).Trim()
    if ([string]$data.target -ne $Target) {
      throw "Smoke target is '$($data.target)', expected '$Target'."
    }
    if ($data.ok -isnot [bool] -or -not $data.ok) {
      throw 'Smoke report success flag is not Boolean true.'
    }
    if ([string]$data.frontendCommit -ne $expectedFrontendCommit -or
        [string]$data.backendCommit -ne $expectedBackendCommit) {
      throw 'Smoke report commits do not match the current workspaces.'
    }
    $finishedAt = [DateTimeOffset]::Parse([string]$data.finishedAt)
    if ($finishedAt -lt [DateTimeOffset]::Now.AddHours(-24)) {
      throw 'Smoke report is older than 24 hours.'
    }
    $e2e = if ($Target -eq 'web') { $data.e2e.data } else { $data.e2e }
    if ($Target -eq 'web' -and [string]$data.e2e.result -ne 'true') {
      throw 'Web E2E result is not successful.'
    }
    if ($Target -eq 'android') {
      $integrationStep = @($data.steps | Where-Object {
          $_.name -eq 'android-integration-test'
        })
      if ($integrationStep.Count -ne 1 -or
          $integrationStep[0].ok -isnot [bool] -or
          -not $integrationStep[0].ok -or
          -not (Test-BaselineNumericValue -Value $integrationStep[0].exitCode) -or
          [int]$integrationStep[0].exitCode -ne 0) {
        throw 'Android integration step is not successful.'
      }
      if ($null -ne $e2e.PSObject.Properties['result'] -and
          "$(($e2e.result))".ToLowerInvariant() -ne 'true') {
        throw 'Android E2E result is not successful.'
      }
    }
    if ($null -eq $e2e -or
        $e2e.durationMs -isnot [ValueType]) {
      throw 'Smoke report omitted the E2E duration.'
    }
    $durationMs = [double]$e2e.durationMs
    if ($durationMs -le 0 -or [double]::IsNaN($durationMs) -or
        [double]::IsInfinity($durationMs)) {
      throw 'Smoke report E2E duration is invalid.'
    }
    foreach ($segment in @('adminSession', 'stockImpact', 'operatorBoundary', 'logout')) {
      if ($null -eq $e2e.segmentsMs.PSObject.Properties[$segment] -or
          $e2e.segmentsMs.$segment -isnot [ValueType]) {
        throw "Smoke report omitted E2E segment '$segment'."
      }
      $segmentMs = [double]$e2e.segmentsMs.$segment
      if ($segmentMs -lt 0 -or [double]::IsNaN($segmentMs) -or
          [double]::IsInfinity($segmentMs)) {
        throw "Smoke report E2E segment '$segment' is invalid."
      }
    }
    return [pscustomobject][ordered]@{
      path = $path
      available = $true
      valid = $true
      error = ''
      totalMs = $durationMs
      segmentsMs = $e2e.segmentsMs
      data = $data
    }
  } catch {
    return [pscustomobject][ordered]@{
      path = $path
      available = $true
      valid = $false
      error = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      totalMs = $null
      segmentsMs = $null
      data = $null
    }
  }
}

$lockPath = Join-Path $runtimePaths.root 'acceptance-smoke.lock'
New-Item -ItemType Directory -Force -Path $runtimePaths.root | Out-Null
$lock = $null
try {
  $lock = [IO.File]::Open(
    $lockPath,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
  )
} catch {
  throw "Another acceptance operation owns the runtime lock: $lockPath"
}

$runtimeOwned = $false
$cleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $false
  error = ''
}
$collectionStartedAt = [DateTimeOffset]::Now
$backendColdStartMs = $null
$webColdStartMs = $null
$healthSamples = [Collections.Generic.List[object]]::new()
$inventorySamples = [Collections.Generic.List[object]]::new()
$inventoryTraversal = $null
$peakBackendWorkingSetBytes = $null
$collectionError = ''

try {
  if (Test-Path -LiteralPath $runtimePaths.state -PathType Leaf) {
    throw 'Managed runtime state already exists; run down before collecting the M9 baseline.'
  }
  $runtimeOwned = $true
  $backendWatch = [Diagnostics.Stopwatch]::StartNew()
  [void](Invoke-BaselineLocalRuntime -Arguments @(
        '-Command', 'up', '-Target', 'none', '-IncludeDependencies',
        '-BackendDir', $BackendDir,
        '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
        '-BackendPort', "$BackendPort",
        '-FrontendPort', "$FrontendPort"
      ))
  $backendWatch.Stop()
  $backendColdStartMs = [double]$backendWatch.Elapsed.TotalMilliseconds

  $webWatch = [Diagnostics.Stopwatch]::StartNew()
  [void](Invoke-BaselineLocalRuntime -Arguments @(
        '-Command', 'up', '-Target', 'web',
        '-BackendDir', $BackendDir,
        '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
        '-BackendPort', "$BackendPort",
        '-FrontendPort', "$FrontendPort"
      ))
  $webWatch.Stop()
  $webColdStartMs = [double]$webWatch.Elapsed.TotalMilliseconds

  $healthUrl = "http://localhost:$BackendPort/healthz"
  for ($index = 0; $index -lt 20; $index++) {
    $sample = Measure-BaselineRequest -Action {
      Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10
    }
    [void]$healthSamples.Add([pscustomobject][ordered]@{
        durationMs = $sample.durationMs
        ok = $sample.ok
        detail = $sample.detail
      })
  }

  $loginBody = @{ username = 'admin'; password = 'admin123' } | ConvertTo-Json
  $login = Invoke-RestMethod `
    -Uri "http://localhost:$BackendPort/api/v1/auth/login" `
    -Method Post `
    -ContentType 'application/json' `
    -Body $loginBody `
    -TimeoutSec 15
  $token = [string]$login.data.token
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Baseline login response omitted the access token.'
  }
  $headers = @{ Authorization = "Bearer $token" }
  $inventoryUrl = "http://localhost:$BackendPort/api/v1/inventory?page=1&pageSize=20"
  for ($index = 0; $index -lt 20; $index++) {
    $sample = Measure-BaselineRequest -Action {
      Invoke-RestMethod `
        -Uri $inventoryUrl `
        -Headers $headers `
        -TimeoutSec 15
    }
    [void]$inventorySamples.Add([pscustomobject][ordered]@{
        durationMs = $sample.durationMs
        ok = $sample.ok
        detail = $sample.detail
      })
  }

  $traversalWatch = [Diagnostics.Stopwatch]::StartNew()
  $page = 1
  $pageSize = 20
  $itemsVisited = 0
  $total = $null
  $expectedPages = $null
  $traversalDeadline = [DateTime]::UtcNow.AddSeconds(60)
  do {
    if ([DateTime]::UtcNow -ge $traversalDeadline -or $page -gt 100) {
      throw 'Inventory traversal exceeded its page or time limit.'
    }
    $response = Invoke-RestMethod `
      -Uri "http://localhost:$BackendPort/api/v1/inventory?page=$page&pageSize=$pageSize" `
      -Headers $headers `
      -TimeoutSec 15
    $items = @($response.data.list)
    $itemsVisited += $items.Count
    $responseTotal = [int]$response.data.total
    if ($null -eq $total) {
      $total = $responseTotal
      $expectedPages = [Math]::Max(1, [Math]::Ceiling($total / [double]$pageSize))
      if ($expectedPages -gt 100) {
        throw "Inventory traversal requires $expectedPages pages; limit is 100."
      }
    } elseif ($responseTotal -ne $total) {
      throw 'Inventory total changed during baseline traversal.'
    }
    $page++
  } while ($page -le $expectedPages -and $items.Count -gt 0)
  $traversalWatch.Stop()
  $inventoryTraversal = [pscustomobject][ordered]@{
    durationMs = [double]$traversalWatch.Elapsed.TotalMilliseconds
    pagesVisited = $page - 1
    itemsVisited = $itemsVisited
    reportedTotal = $total
    ok = $itemsVisited -eq $total
  }
} catch {
  $collectionError = ConvertTo-RimsDiagnosticSummary `
    -StandardOutput '' `
    -StandardError $_.Exception.Message
} finally {
  $cleanup.attempted = $runtimeOwned
  if ($runtimeOwned) {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
      [void](Invoke-BaselineLocalRuntime -Arguments @(
            '-Command', 'down', '-Target', 'web',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
            '-BackendPort', "$BackendPort",
            '-FrontendPort', "$FrontendPort"
          ))
    } catch {
      [void]$cleanupErrors.Add("down: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)")
    }
    try {
      [void](Invoke-BaselineLocalRuntime -Arguments @(
            '-Command', 'reset', '-Target', 'none',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot,
            '-BackendPort', "$BackendPort"
          ))
    } catch {
      [void]$cleanupErrors.Add("reset: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)")
    }
    $cleanup.ok = $cleanupErrors.Count -eq 0
    $cleanup.error = $cleanupErrors -join '; '
  } else {
    $cleanup.ok = $true
  }
}

$baselineExitCode = 1
try {
$operationInputs = @(
  [pscustomobject]@{
    name = 'healthz'
    thresholdMs = 1000
    samples = @($healthSamples)
  },
  [pscustomobject]@{
    name = 'inventory-page-1'
    thresholdMs = 2000
    samples = @($inventorySamples)
  }
)
$operations = @($operationInputs | ForEach-Object {
    ConvertTo-BaselineOperation -Operation $_
  })
$webSmoke = Get-LatestSmokeData -Name 'latest-smoke.json' -Target web
$androidSmoke = Get-LatestSmokeData -Name 'latest-android-smoke.json' -Target android
$thresholdBreaches = @($operations | Where-Object { -not $_.thresholdPassed } |
    ForEach-Object { $_.name })
$report = [pscustomobject][ordered]@{
  schemaVersion = 1
  mode = 'managed-local'
  ok = [string]::IsNullOrWhiteSpace($collectionError) -and
    $cleanup.ok -and
    $webSmoke.valid -and
    $androidSmoke.valid -and
    $thresholdBreaches.Count -eq 0 -and
    $null -ne $inventoryTraversal -and
    $inventoryTraversal.ok
  startedAt = $collectionStartedAt.ToString('o')
  finishedAt = [DateTimeOffset]::Now.ToString('o')
  frontendCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
  backendCommit = (& git -C $BackendDir rev-parse HEAD).Trim()
  backendColdStartMs = $backendColdStartMs
  webColdStartMs = $webColdStartMs
  peakBackendWorkingSetBytes = $peakBackendWorkingSetBytes
  peakBackendWorkingSetSource = 'unavailable-wsl-process-metrics'
  operations = $operations
  inventoryTraversal = $inventoryTraversal
  e2e = [pscustomobject][ordered]@{
    web = [pscustomobject][ordered]@{
      reportPath = $webSmoke.path
      available = $webSmoke.available
      valid = $webSmoke.valid
      error = $webSmoke.error
      totalMs = $webSmoke.totalMs
      segmentsMs = $webSmoke.segmentsMs
    }
    android = [pscustomobject][ordered]@{
      reportPath = $androidSmoke.path
      available = $androidSmoke.available
      valid = $androidSmoke.valid
      error = $androidSmoke.error
      totalMs = $androidSmoke.totalMs
      segmentsMs = $androidSmoke.segmentsMs
    }
  }
  thresholdBreaches = $thresholdBreaches
  collectionError = $collectionError
  cleanup = $cleanup
}
Write-BaselineReport -Report $report
$baselineExitCode = if ($report.ok) { 0 } else { 1 }
} finally {
  if ($null -ne $lock) {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}
exit $baselineExitCode
