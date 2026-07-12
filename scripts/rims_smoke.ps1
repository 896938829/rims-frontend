param(
  [switch]$SkipPubGet,
  [switch]$ListSteps,
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$ReportPath,
  [string]$FlutterRoot = 'C:\flutter'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path -LiteralPath (Join-Path $scriptDir '..')
$appRoot = Resolve-Path -LiteralPath (Join-Path $repoRoot 'rims_frontend')
$toolStateRelative = 'rims_frontend\.tool-state-smoke'
$toolState = Join-Path $repoRoot $toolStateRelative
$pubCache = if ($env:PUB_CACHE) {
  $env:PUB_CACHE
} elseif ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA 'Pub\Cache'
} else {
  Join-Path $HOME '.pub-cache'
}
$demoResidualPattern = 'DemoAuthRepository|DemoUser|登录 Demo|管理员 Demo|普通用户 Demo|admin123|user123|DM-|2024-05|Good morning, 张三|U10086|假数据|模拟数据|固定数据'
$lastNativeExitCode = 0
$stepResults = [Collections.Generic.List[object]]::new()
$smokeStartedAt = [DateTimeOffset]::Now

function Get-SmokeStepDefinitions {
  $steps = @(
    [pscustomobject]@{
      name = 'tool-state'
      command = "tool-state: $toolStateRelative"
    },
    [pscustomobject]@{
      name = 'pub-cache'
      command = "pub-cache: $pubCache"
    }
  )
  if (-not $SkipPubGet) {
    $steps += [pscustomobject]@{
      name = 'flutter-pub-get'
      command = 'flutter pub get --offline'
    }
  }
  $steps += @(
    [pscustomobject]@{
      name = 'flutter-analyze'
      command = 'flutter analyze --no-pub'
    },
    [pscustomobject]@{
      name = 'flutter-test'
      command = 'flutter test --no-pub'
    },
    [pscustomobject]@{
      name = 'demo-residual-scan'
      command = 'rg Demo residual scan'
    },
    [pscustomobject]@{
      name = 'git-diff-check'
      command = 'git diff --check'
    }
  )
  return $steps
}

if ($ListSteps) {
  $definitions = @(Get-SmokeStepDefinitions)
  if ($Output -eq 'Json') {
    [pscustomobject][ordered]@{
      schemaVersion = 1
      steps = $definitions
    } | ConvertTo-Json -Depth 5
  } else {
    $definitions | ForEach-Object { Write-Output $_.command }
  }
  exit 0
}

function Invoke-Flutter {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $dartExe = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
  $flutterSnapshot = Join-Path $FlutterRoot 'bin\cache\flutter_tools.snapshot'

  if ((Test-Path -LiteralPath $dartExe) -and
      (Test-Path -LiteralPath $flutterSnapshot)) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $captured = @(& $dartExe $flutterSnapshot @Arguments 2>&1)
      $script:lastNativeExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($Output -eq 'Text') {
      $captured | ForEach-Object { Write-Host $_ }
    }
    return
  }

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $captured = @(& flutter @Arguments 2>&1)
    $script:lastNativeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($Output -eq 'Text') {
    $captured | ForEach-Object { Write-Host $_ }
  }
}

function Invoke-FlutterChecked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  if ($Output -eq 'Text') { Write-Host "==> $Name" }
  Push-Location -LiteralPath $appRoot
  try {
    Invoke-Flutter -Arguments $Arguments
    $exitCode = $script:lastNativeExitCode
    if ($exitCode -ne 0) {
      throw "$Name failed with exit code $exitCode"
    }
  } finally {
    Pop-Location
  }
}

function Invoke-DemoResidualScan {
  if ($Output -eq 'Text') { Write-Host '==> rg Demo residual scan' }
  $libPath = Join-Path $appRoot 'lib'
  $testPath = Join-Path $appRoot 'test'
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $captured = @(& rg -n $demoResidualPattern $libPath $testPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($Output -eq 'Text' -and $captured.Count -gt 0) {
    $captured | ForEach-Object { Write-Host $_ }
  }
  if ($exitCode -eq 0) {
    throw 'Demo residual scan found matches.'
  }
  if ($exitCode -ne 1) {
    throw "Demo residual scan failed with exit code $exitCode"
  }
}

function Invoke-GitDiffCheck {
  if ($Output -eq 'Text') { Write-Host '==> git diff --check' }
  Push-Location -LiteralPath $repoRoot
  try {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $captured = @(& git diff --check 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($Output -eq 'Text' -and $captured.Count -gt 0) {
      $captured | ForEach-Object { Write-Host $_ }
    }
    if ($exitCode -ne 0) {
      throw "git diff --check failed with exit code $exitCode"
    }
  } finally {
    Pop-Location
  }
}

function Invoke-RecordedSmokeStep {
  param(
    [string]$Name,
    [string]$Command,
    [scriptblock]$Action
  )
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    & $Action
    $script:stepResults.Add([pscustomobject][ordered]@{
        name = $Name
        command = $Command
        ok = $true
        exitCode = 0
        durationMs = $watch.ElapsedMilliseconds
      })
  } catch {
    $script:stepResults.Add([pscustomobject][ordered]@{
        name = $Name
        command = $Command
        ok = $false
        exitCode = 1
        durationMs = $watch.ElapsedMilliseconds
        error = $_.Exception.Message
      })
    throw
  } finally {
    $watch.Stop()
  }
}

function Write-SmokeReport {
  param(
    [bool]$Ok,
    [int]$ExitCode,
    [string]$ErrorMessage
  )
  $report = [pscustomobject][ordered]@{
    schemaVersion = 1
    ok = $Ok
    exitCode = $ExitCode
    startedAt = $smokeStartedAt.ToString('o')
    finishedAt = [DateTimeOffset]::Now.ToString('o')
    toolVersions = [pscustomobject][ordered]@{
      flutter = (& flutter --version 2>$null | Select-Object -First 1)
      git = (& git --version 2>$null)
      rg = (& rg --version 2>$null | Select-Object -First 1)
    }
    error = $ErrorMessage
    steps = @($stepResults)
  }
  if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $directory = Split-Path -Parent $ReportPath
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temporary = "$ReportPath.tmp-$PID"
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $ReportPath -Force
  }
  if ($Output -eq 'Json') {
    [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 8 -Compress))
  }
}

function Remove-SmokeToolState {
  if (-not (Test-Path -LiteralPath $toolState)) {
    return
  }

  $resolvedRepo = Resolve-Path -LiteralPath $repoRoot
  $resolvedToolState = Resolve-Path -LiteralPath $toolState
  if (-not $resolvedToolState.Path.StartsWith(
      $resolvedRepo.Path,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Refusing to remove outside repository: $($resolvedToolState.Path)"
  }

  Remove-Item -LiteralPath $resolvedToolState.Path -Recurse -Force
}

$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
$previousPubCache = $env:PUB_CACHE

$smokeError = $null
$smokeExitCode = 0
try {
  New-Item -ItemType Directory -Force -Path $toolState | Out-Null
  $env:APPDATA = $toolState
  $env:LOCALAPPDATA = $toolState
  $env:PUB_CACHE = $pubCache

  $stepResults.Add([pscustomobject][ordered]@{
      name = 'tool-state'
      command = "tool-state: $toolStateRelative"
      ok = $true
      exitCode = 0
      durationMs = 0
    })
  $stepResults.Add([pscustomobject][ordered]@{
      name = 'pub-cache'
      command = "pub-cache: $pubCache"
      ok = $true
      exitCode = 0
      durationMs = 0
    })
  if (-not $SkipPubGet) {
    Invoke-RecordedSmokeStep -Name 'flutter-pub-get' -Command 'flutter pub get --offline' -Action {
      Invoke-FlutterChecked `
        -Name 'flutter pub get --offline' `
        -Arguments @('pub', 'get', '--offline')
    }
  }
  Invoke-RecordedSmokeStep -Name 'flutter-analyze' -Command 'flutter analyze --no-pub' -Action {
    Invoke-FlutterChecked `
      -Name 'flutter analyze --no-pub' `
      -Arguments @('analyze', '--no-pub')
  }
  Invoke-RecordedSmokeStep -Name 'flutter-test' -Command 'flutter test --no-pub' -Action {
    Invoke-FlutterChecked `
      -Name 'flutter test --no-pub' `
      -Arguments @('test', '--no-pub')
  }
  Invoke-RecordedSmokeStep -Name 'demo-residual-scan' -Command 'rg Demo residual scan' -Action {
    Invoke-DemoResidualScan
  }
  Invoke-RecordedSmokeStep -Name 'git-diff-check' -Command 'git diff --check' -Action {
    Invoke-GitDiffCheck
  }
} catch {
  $smokeError = $_.Exception.Message
  $smokeExitCode = 1
} finally {
  $env:APPDATA = $previousAppData
  $env:LOCALAPPDATA = $previousLocalAppData
  if ($previousPubCache) {
    $env:PUB_CACHE = $previousPubCache
  } else {
    Remove-Item Env:PUB_CACHE -ErrorAction SilentlyContinue
  }
  Remove-SmokeToolState
}

Write-SmokeReport `
  -Ok ($smokeExitCode -eq 0) `
  -ExitCode $smokeExitCode `
  -ErrorMessage $smokeError
if ($Output -eq 'Text') {
  if ($smokeExitCode -eq 0) {
    Write-Host 'RIMS smoke checks passed.'
  } else {
    [Console]::Error.WriteLine($smokeError)
  }
}
exit $smokeExitCode
