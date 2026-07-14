param(
  [switch]$ListSteps,
  [switch]$KeepRunning,
  [switch]$IncludeDependencies,
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$DriverPort = 4444,
  [string]$ChromeDriverPath = $env:RIMS_CHROMEDRIVER_PATH,
  [string]$ReportPath,
  [switch]$TestMode,
  [string]$FailStep,
  [int]$FailExitCode = 23,
  [switch]$TestActionFailure,
  [switch]$TestDriverStartedHere,
  [switch]$TestRestoreFailure,
  [string]$CleanupRecordPath,
  [string]$DriverCleanupRecordPath,
  [object]$P0Count = $null,
  [object]$P1Count = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepNames = @(
  'doctor-web',
  'up-backend',
  'reset-fixtures',
  'frontend-smoke',
  'backend-go-test',
  'backend-build',
  'backend-m8-smoke',
  'web-integration-test',
  'runtime-status',
  'write-report'
)

if ($ListSteps) {
  $stepNames | ForEach-Object { Write-Output $_ }
  exit 0
}
if ($TestMode -and [string]::IsNullOrWhiteSpace($FailStep)) {
  throw 'TestMode requires an explicit FailStep and cannot produce a green report.'
}
function ConvertTo-DefectCount {
  param([string]$Name, [AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ($text -notmatch '^\d+$') {
    throw "$Name must be a non-negative integer."
  }
  try {
    return [int]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    throw "$Name must be a non-negative 32-bit integer."
  }
}
$P0Count = ConvertTo-DefectCount -Name 'P0Count' -Value $P0Count
$P1Count = ConvertTo-DefectCount -Name 'P1Count' -Value $P1Count

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
$appRoot = Join-Path $repoRoot 'rims_frontend'
$runtimeRoot = Join-Path $repoRoot '.runtime\rims-local'
$logRoot = Join-Path $runtimeRoot 'logs'
$reportRoot = Join-Path $runtimeRoot 'reports'
$orchestratorLog = Join-Path $logRoot 'web-smoke-orchestrator.log'
$localScript = Join-Path $scriptDir 'rims_local.ps1'
$frontendSmokeScript = Join-Path $scriptDir 'rims_smoke.ps1'
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'
. $commonScript

$gitCommonDir = (& git -C $repoRoot rev-parse --git-common-dir).Trim()
if (-not [IO.Path]::IsPathRooted($gitCommonDir)) {
  $gitCommonDir = [IO.Path]::GetFullPath((Join-Path $repoRoot $gitCommonDir))
}
$frontendRepository = Split-Path -Parent $gitCommonDir
if ([string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
  $BackendWorkspaceRoot = Join-Path `
    (Split-Path -Parent $frontendRepository) `
    'RIMS'
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
  if ($matchingCandidate.Count -gt 0) {
    $BackendDir = $matchingCandidate[0]
  } else {
    $BackendDir = Join-Path $BackendWorkspaceRoot 'rims-goProgect'
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $reportRoot 'latest-smoke.json'
}

$steps = [Collections.Generic.List[object]]::new()
$failedStep = $null
$firstExitCode = 0
$driverProcess = $null
$driverStartedHere = [bool]$TestDriverStartedHere
$resolvedChromeDriverPath = $null
$chromeVersion = $null
$chromeDriverVersion = $null
$toolVersions = $null
$e2eReportData = $null
$frontendSmokeData = $null
$observedFixtureCounts = $null
$baselineRestore = [pscustomobject][ordered]@{
  attempted = $false
  ok = $false
  error = ''
}
$driverCleanup = [pscustomobject][ordered]@{
  attempted = $false
  ok = $true
  error = ''
}
$expectedFixtureCounts = [pscustomobject][ordered]@{
  products = 45
  operatorUsers = 1
  warehouses = 1
  operatorBindings = 2
  inventories = 90
  nonStandardInventories = 25
  documents = 15
  transactions = 15
}
$scenarioFixtureExpectations = [pscustomobject][ordered]@{
  inventoriesPerWarehouse = 45
  defaultWarehouseLowStock = 5
  secondWarehouseLowStock = 0
  defaultWarehouseFixtureQuantity = 2
  secondWarehouseFixtureQuantity = 12
}
$startedAt = [DateTimeOffset]::Now

function Add-WebStepResult {
  param(
    [string]$Name,
    [bool]$Ok,
    [int]$ExitCode,
    [long]$DurationMs,
    [string]$Detail = ''
  )
  $script:steps.Add([pscustomobject][ordered]@{
      name = $Name
      ok = $Ok
      exitCode = $ExitCode
      durationMs = $DurationMs
      detail = $Detail
    })
}

function Throw-WebChildFailure {
  param([string]$Message, [int]$ExitCode)
  $exception = [InvalidOperationException]::new($Message)
  $exception.Data['ExitCode'] = $ExitCode
  throw $exception
}

function Invoke-WebStep {
  param(
    [string]$Name,
    [scriptblock]$Action
  )
  $watch = [Diagnostics.Stopwatch]::StartNew()
  Add-Content `
    -LiteralPath $orchestratorLog `
    -Value "$([DateTimeOffset]::Now.ToString('o')) START $Name" `
    -Encoding UTF8
  $exitCode = 0
  $detail = ''
  try {
    if ($TestMode -and $Name -eq $FailStep) {
      if ($TestActionFailure) {
        Throw-WebChildFailure `
          -Message 'Injected action failure.' `
          -ExitCode $FailExitCode
      }
      $exitCode = $FailExitCode
      $detail = 'Injected child failure.'
    } elseif (-not $TestMode) {
      & $Action
      $exitCode = $LASTEXITCODE
      if ($null -eq $exitCode) { $exitCode = 0 }
    }
  } catch {
    $exitCode = if ($_.Exception.Data.Contains('ExitCode')) {
      [int]$_.Exception.Data['ExitCode']
    } else { 1 }
    $detail = $_.Exception.Message
  } finally {
    $watch.Stop()
  }

  $ok = $exitCode -eq 0
  Add-WebStepResult `
    -Name $Name `
    -Ok $ok `
    -ExitCode $exitCode `
    -DurationMs $watch.ElapsedMilliseconds `
    -Detail $detail
  if (-not $ok -and $script:firstExitCode -eq 0) {
    $script:firstExitCode = $exitCode
    $script:failedStep = $Name
  }
  Add-Content `
    -LiteralPath $orchestratorLog `
    -Value "$([DateTimeOffset]::Now.ToString('o')) END $Name exit=$exitCode" `
    -Encoding UTF8
  return $ok
}

function Invoke-LocalRuntime {
  param([string[]]$Arguments)
  $commandIndex = [Array]::IndexOf($Arguments, '-Command')
  $commandName = if ($commandIndex -ge 0 -and $commandIndex + 1 -lt $Arguments.Count) {
    $Arguments[$commandIndex + 1]
  } else { 'command' }
  $processArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $localScript
  ) + $Arguments
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = ($processArguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value "$_"
    }) -join ' '
  $startInfo.UseShellExecute = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  $process.Dispose()
  if ($exitCode -ne 0) {
    Throw-WebChildFailure `
      -Message "rims_local $commandName failed with exit code $exitCode." `
      -ExitCode $exitCode
  }
}

function Wait-BackendPortFree {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  $freeSince = $null
  do {
    $client = [Net.Sockets.TcpClient]::new()
    try {
      $pending = $client.BeginConnect('127.0.0.1', $BackendPort, $null, $null)
      $connected = $pending.AsyncWaitHandle.WaitOne(200) -and $client.Connected
    } catch {
      $connected = $false
    } finally {
      $client.Dispose()
    }
    if (-not $connected) {
      if ($null -eq $freeSince) {
        $freeSince = [DateTime]::UtcNow
      } elseif (([DateTime]::UtcNow - $freeSince).TotalMilliseconds -ge 1500) {
        return
      }
    } else {
      $freeSince = $null
    }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Backend port $BackendPort remained occupied after managed down."
}

function Wait-DriverPortFree {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $client = [Net.Sockets.TcpClient]::new()
    try {
      $pending = $client.BeginConnect('127.0.0.1', $DriverPort, $null, $null)
      $connected = $pending.AsyncWaitHandle.WaitOne(200) -and $client.Connected
    } catch {
      $connected = $false
    } finally {
      $client.Dispose()
    }
    if (-not $connected) { return }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "ChromeDriver port $DriverPort remained occupied after cleanup."
}

function Invoke-WslBackendCommand {
  param(
    [string]$Command,
    [string[]]$CommandArguments = @(),
    [string]$LogPath = ''
  )
  $execution = Invoke-RimsExternalCommand `
    -FilePath 'wsl.exe' `
    -Arguments (@(
        '--cd', $BackendDir, '-e', 'bash', '-lc', $Command, 'rims-web-e2e'
      ) + $CommandArguments) `
    -TimeoutSeconds 600
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    @($execution.StandardOutput, $execution.StandardError) | Set-Content `
      -LiteralPath $LogPath `
      -Encoding UTF8
  }
  if ($execution.ExitCode -ne 0) {
    Throw-WebChildFailure `
      -Message "Backend command failed with exit code $($execution.ExitCode): $Command" `
      -ExitCode $execution.ExitCode
  }
  return $execution
}

function Get-InstalledChromeVersion {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      $script:chromeVersion = (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion
      return $script:chromeVersion
    }
  }
  throw 'Google Chrome is not installed.'
}

function Resolve-ChromeDriver {
  if (-not [string]::IsNullOrWhiteSpace($ChromeDriverPath)) {
    if (-not (Test-Path -LiteralPath $ChromeDriverPath)) {
      throw "Configured ChromeDriver does not exist: $ChromeDriverPath"
    }
    return (Resolve-Path -LiteralPath $ChromeDriverPath).Path
  }

  $chromeVersion = Get-InstalledChromeVersion
  $versionParts = $chromeVersion.Split('.')
  $buildPrefix = ($versionParts[0..2] -join '.')
  $toolsRoot = Join-Path $runtimeRoot 'tools'
  New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
  $cachedDirectories = @(Get-ChildItem `
      -LiteralPath $toolsRoot `
      -Directory `
      -Filter "chromedriver-$buildPrefix.*" `
      -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch '\.tmp-'
      } | Sort-Object Name -Descending)
  foreach ($directory in $cachedDirectories) {
    $manifestPath = Join-Path $directory.FullName 'manifest.json'
    $driver = Get-ChildItem `
      -LiteralPath $directory.FullName `
      -Filter 'chromedriver.exe' `
      -Recurse `
      -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $driver -or -not (Test-Path -LiteralPath $manifestPath)) {
      continue
    }
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
      $actualHash = (Get-FileHash -LiteralPath $driver.FullName -Algorithm SHA256).Hash
      if ($manifest.chromeBuild -eq $buildPrefix -and
          $manifest.driverSha256 -eq $actualHash) {
        $script:chromeDriverVersion = [string]$manifest.driverVersion
        return $driver.FullName
      }
    } catch {
      # Ignore untrusted or incomplete cache entries and acquire a fresh copy.
    }
  }

  $versionsUrl = 'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json'
  $metadata = Invoke-RestMethod `
    -Uri $versionsUrl `
    -TimeoutSec 30 `
    -UseBasicParsing
  $match = @($metadata.versions | Where-Object {
      $_.version.StartsWith("$buildPrefix.") -and
      @($_.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).Count -gt 0
    } | Sort-Object { [version]$_.version } -Descending)[0]
  if ($null -eq $match) {
    throw "No win64 ChromeDriver is available for Chrome $chromeVersion."
  }
  $download = @($match.downloads.chromedriver | Where-Object {
      $_.platform -eq 'win64'
    })[0]
  $downloadUri = [Uri]$download.url
  if ($downloadUri.Scheme -ne 'https' -or
      $downloadUri.Host -ne 'storage.googleapis.com') {
    throw "ChromeDriver metadata returned an untrusted download URL: $($download.url)"
  }
  $destination = Join-Path $toolsRoot "chromedriver-$($match.version)"
  $temporary = Join-Path $toolsRoot "chromedriver-$($match.version).tmp-$PID"
  $archive = "$temporary.zip"
  try {
    Invoke-WebRequest `
      -Uri $downloadUri `
      -OutFile $archive `
      -TimeoutSec 60 `
      -UseBasicParsing
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
    $resolved = Get-ChildItem `
      -LiteralPath $temporary `
      -Filter 'chromedriver.exe' `
      -Recurse | Select-Object -First 1
    if ($null -eq $resolved) {
      throw 'Downloaded ChromeDriver archive did not contain chromedriver.exe.'
    }
    $driverHash = (Get-FileHash -LiteralPath $resolved.FullName -Algorithm SHA256).Hash
    [pscustomobject][ordered]@{
      chromeBuild = $buildPrefix
      chromeVersion = $chromeVersion
      driverVersion = $match.version
      sourceUrl = $downloadUri.AbsoluteUri
      transport = 'official-metadata-https'
      archiveSha256 = $archiveHash
      driverSha256 = $driverHash
    } | ConvertTo-Json -Depth 4 | Set-Content `
      -LiteralPath (Join-Path $temporary 'manifest.json') `
      -Encoding UTF8
    if (Test-Path -LiteralPath $destination) {
      Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Move-Item -LiteralPath $temporary -Destination $destination
  } finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:chromeDriverVersion = [string]$match.version
  return (Get-ChildItem `
      -LiteralPath $destination `
      -Filter 'chromedriver.exe' `
      -Recurse | Select-Object -First 1).FullName
}

function Start-ManagedChromeDriver {
  try {
    $status = Invoke-RestMethod `
      -Uri "http://127.0.0.1:$DriverPort/status" `
      -TimeoutSec 1
    if ($status.value.ready) {
      [void](Get-InstalledChromeVersion)
      $script:chromeDriverVersion = [string]$status.value.build.version
      return
    }
  } catch {
    # Start a controller-owned driver below.
  }

  if ([string]::IsNullOrWhiteSpace($script:chromeVersion)) {
    [void](Get-InstalledChromeVersion)
  }
  $driver = Resolve-ChromeDriver
  $script:resolvedChromeDriverPath = $driver
  if ([string]::IsNullOrWhiteSpace($script:chromeDriverVersion)) {
    $versionResult = Invoke-RimsExternalCommand `
      -FilePath $driver `
      -Arguments @('--version') `
      -TimeoutSeconds 10
    $script:chromeDriverVersion = ([string]$versionResult.StandardOutput).Trim()
  }
  $script:driverProcess = Start-Process `
    -FilePath $driver `
    -ArgumentList "--port=$DriverPort" `
    -WindowStyle Hidden `
    -PassThru
  $script:driverStartedHere = $true
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 200
    try {
      $status = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$DriverPort/status" `
        -TimeoutSec 1
      if ($status.value.ready) { return }
    } catch {
      # Retry until the bounded deadline.
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "ChromeDriver did not become ready on port $DriverPort."
}

function Get-WebToolVersions {
  if ($null -ne $script:toolVersions) {
    return $script:toolVersions
  }
  $versions = [pscustomobject][ordered]@{
    powershell = $PSVersionTable.PSVersion.ToString()
    wsl = $null
    go = $null
    chrome = $script:chromeVersion
    chromeDriver = $script:chromeDriverVersion
  }
  if (-not $TestMode) {
    $wslVersion = Invoke-RimsExternalCommand `
      -FilePath 'wsl.exe' `
      -Arguments @('--cd', $BackendDir, 'bash', '-lc',
        "printf 'WSL kernel '; uname -r") `
      -TimeoutSeconds 10
    $versions.wsl = ([string]$wslVersion.StandardOutput).Trim()
    $goVersion = Invoke-RimsExternalCommand `
      -FilePath 'wsl.exe' `
      -Arguments @('--cd', $BackendDir, 'bash', '-lc',
        '~/local/go/bin/go version') `
      -TimeoutSeconds 10
    $versions.go = ([string]$goVersion.StandardOutput).Trim()
  }
  $script:toolVersions = $versions
  return $script:toolVersions
}

function Write-WebReport {
  param([bool]$Ok, [string]$OutputPath)
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT begin"
  $reportDirectory = Split-Path -Parent $OutputPath
  if ($reportDirectory) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
  }
  $frontendCommit = (& git -C $repoRoot rev-parse HEAD 2>$null)
  $backendCommit = if ($BackendDir -and (Test-Path -LiteralPath $BackendDir)) {
    (& git -C $BackendDir rev-parse HEAD 2>$null)
  } else { '' }
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT commits"
  $failureDetails = [Collections.ArrayList]::new()
  if ($null -ne $script:e2eReportData) {
    foreach ($detail in @($script:e2eReportData.failureDetails)) {
      [void]$failureDetails.Add($detail)
    }
  }
  $screenshots = [Collections.ArrayList]::new()
  @(Get-ChildItem `
      -LiteralPath (Join-Path $appRoot 'build\screenshots') `
      -Filter '*.png' `
      -File `
      -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTimeUtc -ge $startedAt.UtcDateTime
      } | ForEach-Object { $_.FullName }) | ForEach-Object {
    [void]$screenshots.Add($_)
  }
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT screenshots"
  $logTails = [pscustomobject][ordered]@{}
  foreach ($logName in @(
      'backend.stdout.log',
      'backend.stderr.log',
      'frontend-smoke.log',
      'web-integration-test.log',
      'web-smoke-orchestrator.log'
    )) {
    $path = Join-Path $logRoot $logName
    $tail = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $path) {
      Get-Content `
        -LiteralPath $path `
        -Tail 20 `
        -ErrorAction SilentlyContinue | ForEach-Object {
          [void]$tail.Add([string]$_)
        }
    }
    $logTails | Add-Member -MemberType NoteProperty -Name $logName -Value $tail
  }
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT tails"
  $report = [pscustomobject][ordered]@{
    schemaVersion = 1
    target = 'web'
    ok = $Ok
    executionOk = $Ok
    acceptanceOk = if ($null -eq $P0Count -or $null -eq $P1Count) {
      $null
    } else { $Ok -and [int]$P0Count -eq 0 -and [int]$P1Count -eq 0 }
    acceptanceStatus = if ($null -eq $P0Count -or $null -eq $P1Count) {
      'not-evaluated'
    } elseif ($Ok -and [int]$P0Count -eq 0 -and [int]$P1Count -eq 0) {
      'passed'
    } else { 'failed' }
    exitCode = $script:firstExitCode
    failedStep = $script:failedStep
    startedAt = $startedAt.ToString('o')
    finishedAt = [DateTimeOffset]::Now.ToString('o')
    frontendCommit = "$frontendCommit".Trim()
    backendCommit = "$backendCommit".Trim()
    p0Count = $P0Count
    p1Count = $P1Count
    defectCountsSource = if ($null -eq $P0Count -or $null -eq $P1Count) {
      'not-provided'
    } else { 'explicit-parameters' }
    toolVersions = Get-WebToolVersions
    expectedFixtureCounts = $expectedFixtureCounts
    fixtureCounts = $script:observedFixtureCounts
    scenarioFixtureExpectations = $scenarioFixtureExpectations
    baselineRestore = $baselineRestore
    driverCleanup = $driverCleanup
    frontendSmoke = $script:frontendSmokeData
    e2e = $script:e2eReportData
    integrationFailureDetails = $failureDetails
    screenshots = $screenshots
    logTails = $logTails
    steps = @($script:steps)
  }
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT object"
  $report | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath $OutputPath `
    -Encoding UTF8
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) REPORT written"
}

function Invoke-BaselineRestore {
  $script:baselineRestore.attempted = $true
  if ($TestMode) {
    if ($CleanupRecordPath) {
      $value = if ($KeepRunning) { 'keep' } else { 'down' }
      Set-Content -LiteralPath $CleanupRecordPath -Value $value -Encoding ASCII
    }
    if ($TestRestoreFailure) {
      $script:baselineRestore.ok = $false
      $script:baselineRestore.error = 'Injected baseline restore failure.'
      if ($script:firstExitCode -eq 0) {
        $script:firstExitCode = 24
        $script:failedStep = 'baseline-restore'
      }
    } else {
      $script:baselineRestore.ok = $true
    }
    return
  }

  try {
    Invoke-LocalRuntime -Arguments @(
      '-Command', 'down', '-Target', 'none',
      '-BackendDir', $BackendDir,
      '-BackendWorkspaceRoot', $BackendWorkspaceRoot
    )
    Wait-BackendPortFree
    Invoke-LocalRuntime -Arguments @(
      '-Command', 'reset', '-Target', 'none',
      '-BackendDir', $BackendDir,
      '-BackendWorkspaceRoot', $BackendWorkspaceRoot
    )
    if ($KeepRunning) {
      $arguments = @(
        '-Command', 'up', '-Target', 'none',
        '-BackendDir', $BackendDir,
        '-BackendWorkspaceRoot', $BackendWorkspaceRoot
      )
      if ($IncludeDependencies) { $arguments += '-IncludeDependencies' }
      Invoke-LocalRuntime -Arguments $arguments
    }
    $script:baselineRestore.ok = $true
  } catch {
    $script:baselineRestore.ok = $false
    $script:baselineRestore.error = $_.Exception.Message
    if ($script:firstExitCode -eq 0) {
      $script:firstExitCode = if ($_.Exception.Data.Contains('ExitCode')) {
        [int]$_.Exception.Data['ExitCode']
      } else { 1 }
      $script:failedStep = 'baseline-restore'
    }
  }
}

New-Item -ItemType Directory -Force -Path $logRoot, $reportRoot | Out-Null
$lockPath = Join-Path $runtimeRoot 'acceptance-smoke.lock'
try {
  $smokeLock = [IO.File]::Open(
    $lockPath,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
  )
  $lockBytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID`n")
  $smokeLock.SetLength(0)
  $smokeLock.Write($lockBytes, 0, $lockBytes.Length)
  $smokeLock.Flush()
} catch {
  throw "Another managed Web smoke owns the runtime lock: $lockPath"
}
Set-Content `
  -LiteralPath $orchestratorLog `
  -Value "$([DateTimeOffset]::Now.ToString('o')) Web smoke started" `
  -Encoding UTF8

try {
  foreach ($name in $stepNames) {
    if ($name -eq 'write-report') { break }
    if ($firstExitCode -ne 0) { break }

    $action = switch ($name) {
      'doctor-web' {
        {
          Invoke-LocalRuntime -Arguments @(
            '-Command', 'doctor', '-Target', 'web', '-Output', 'Json',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot
          )
        }
      }
      'up-backend' {
        {
          $arguments = @(
            '-Command', 'up', '-Target', 'none',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot
          )
          if ($IncludeDependencies) { $arguments += '-IncludeDependencies' }
          Invoke-LocalRuntime -Arguments $arguments
        }
      }
      'reset-fixtures' {
        {
          $wslWorkspace = ConvertTo-RimsWslPath `
            -WindowsPath $BackendWorkspaceRoot
          $fixtureExecution = Invoke-WslBackendCommand `
            -Command 'RIMS_ALLOW_DEV_SEED=1 RIMS_WORKSPACE_ROOT="$1" bash scripts/m9_dev_seed.sh --reset' `
            -CommandArguments @($wslWorkspace) `
            -LogPath (Join-Path $logRoot 'fixture-reset.log')
          $counts = Get-RimsM9FixtureCountsFromOutput `
            -Output ([string]$fixtureExecution.StandardOutput)
          if (-not $counts.ok) {
            Throw-WebChildFailure -Message $counts.detail -ExitCode 1
          }
          foreach ($countName in @($expectedFixtureCounts.PSObject.Properties.Name)) {
            if ([int]$counts.$countName -ne [int]$expectedFixtureCounts.$countName) {
              Throw-WebChildFailure `
                -Message "Fixture count '$countName' expected $($expectedFixtureCounts.$countName), observed $($counts.$countName)." `
                -ExitCode 1
            }
          }
          $script:observedFixtureCounts = $counts
        }
      }
      'frontend-smoke' {
        {
          $smokeReport = Join-Path $reportRoot 'frontend-smoke.json'
          $smokeLog = Join-Path $logRoot 'frontend-smoke.log'
          & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $frontendSmokeScript `
            -Output Json `
            -ReportPath $smokeReport *>&1 | Tee-Object -FilePath $smokeLog
          if ($LASTEXITCODE -ne 0) {
            Throw-WebChildFailure `
              -Message "Frontend smoke failed with exit code $LASTEXITCODE." `
              -ExitCode $LASTEXITCODE
          }
          $script:frontendSmokeData = Get-Content `
            -LiteralPath $smokeReport `
            -Raw | ConvertFrom-Json
        }
      }
      'backend-go-test' { { Invoke-WslBackendCommand '~/local/go/bin/go test ./...' } }
      'backend-build' {
        {
          Invoke-WslBackendCommand @'
output=$(mktemp /tmp/rims-server-smoke.XXXXXX)
trap 'rm -f "$output"' EXIT
~/local/go/bin/go build -o "$output" ./cmd/server
'@
        }
      }
      'backend-m8-smoke' {
        { Invoke-WslBackendCommand "bash <(sed 's/\r$//' scripts/m8_backend_smoke.sh)" }
      }
      'web-integration-test' {
        {
          Start-ManagedChromeDriver
          $e2eLog = Join-Path $logRoot 'web-integration-test.log'
          Push-Location -LiteralPath $appRoot
          try {
            $env:FLUTTER_TEST_OUTPUTS_DIR = (Resolve-Path 'build').Path
            & flutter drive `
              --no-pub `
              --driver=test_driver/integration_test.dart `
              --target=integration_test/app_e2e_test.dart `
              -d web-server `
              --driver-port=$DriverPort `
              --dart-define="APP_ENV=development" `
              --dart-define="ALLOW_LOCAL_HTTP=true" `
              --dart-define="API_BASE_URL=http://localhost:$BackendPort/api/v1" `
              --timeout=240 *>&1 | Tee-Object -FilePath $e2eLog
            $flutterExitCode = $LASTEXITCODE
            $resultLine = Get-Content -LiteralPath $e2eLog | Where-Object {
              $_ -match '^result \{'
            } | Select-Object -Last 1
            if ($resultLine -and $resultLine -match '^result (?<json>\{.*\})$') {
              $script:e2eReportData = $Matches.json | ConvertFrom-Json
            }
            if ($flutterExitCode -ne 0) {
              Throw-WebChildFailure `
                -Message "Web integration test failed with exit code $flutterExitCode." `
                -ExitCode $flutterExitCode
            }
            if ($null -eq $script:e2eReportData) {
              Throw-WebChildFailure `
                -Message 'Web integration test omitted machine-readable result data.' `
                -ExitCode 1
            }
            if ("$($script:e2eReportData.result)" -ne 'true') {
              Throw-WebChildFailure `
                -Message 'Web integration test reported a failed result.' `
                -ExitCode 1
            }
          } finally {
            Pop-Location
          }
        }
      }
      'runtime-status' {
        {
          Invoke-LocalRuntime -Arguments @(
            '-Command', 'status', '-Target', 'none', '-Output', 'Json',
            '-BackendDir', $BackendDir,
            '-BackendWorkspaceRoot', $BackendWorkspaceRoot
          )
        }
      }
    }
    [void](Invoke-WebStep -Name $name -Action $action)
  }
} finally {
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) START baseline-restore"
  Invoke-BaselineRestore
  Add-Content -LiteralPath $orchestratorLog -Value "$([DateTimeOffset]::Now.ToString('o')) END baseline-restore"
  if ($TestMode -and $DriverCleanupRecordPath -and $driverStartedHere) {
    Set-Content -LiteralPath $DriverCleanupRecordPath -Value 'stop' -Encoding ASCII
  }
  if ($driverStartedHere) {
    $script:driverCleanup.attempted = $true
    if ($TestMode) {
      $script:driverCleanup.ok = $true
    } else {
      try {
        if ($driverProcess -and -not $driverProcess.HasExited) {
          $driverProcess.Kill()
          if (-not $driverProcess.WaitForExit(5000)) {
            throw "ChromeDriver process $($driverProcess.Id) did not exit."
          }
        }
        Wait-DriverPortFree
        $script:driverCleanup.ok = $true
      } catch {
        $script:driverCleanup.ok = $false
        $script:driverCleanup.error = $_.Exception.Message
        if ($script:firstExitCode -eq 0) {
          $script:firstExitCode = 1
          $script:failedStep = 'driver-cleanup'
        }
      }
    }
  }
}

$reportOk = $firstExitCode -eq 0
$reportWatch = [Diagnostics.Stopwatch]::StartNew()
$temporaryReportPath = "$ReportPath.tmp-$PID"
try {
  $writeStep = [pscustomobject][ordered]@{
    name = 'write-report'
    ok = $true
    exitCode = 0
    durationMs = 0
    detail = ''
  }
  $steps.Add($writeStep)
  Write-WebReport -Ok $reportOk -OutputPath $temporaryReportPath
  $reportWatch.Stop()
  $writeStep.durationMs = [Math]::Max(1, $reportWatch.ElapsedMilliseconds)
  Write-WebReport -Ok $reportOk -OutputPath $temporaryReportPath
  Move-Item -LiteralPath $temporaryReportPath -Destination $ReportPath -Force
} catch {
  Remove-Item -LiteralPath $temporaryReportPath -Force -ErrorAction SilentlyContinue
  if ($firstExitCode -eq 0) {
    $firstExitCode = 1
    $failedStep = 'write-report'
  }
  throw
} finally {
  if ($reportWatch.IsRunning) { $reportWatch.Stop() }
  if ($null -ne $smokeLock) {
    $smokeLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}

exit $firstExitCode
