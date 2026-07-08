param(
  [switch]$SkipPubGet,
  [switch]$ListSteps,
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

function Get-SmokeStepNames {
  $steps = @(
    "tool-state: $toolStateRelative",
    "pub-cache: $pubCache"
  )
  if (-not $SkipPubGet) {
    $steps += 'flutter pub get --offline'
  }
  $steps += @(
    'flutter analyze --no-pub',
    'flutter test --no-pub',
    'rg Demo residual scan',
    'git diff --check'
  )
  return $steps
}

if ($ListSteps) {
  Get-SmokeStepNames | ForEach-Object { Write-Output $_ }
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
    & $dartExe $flutterSnapshot @Arguments
    $script:lastNativeExitCode = $LASTEXITCODE
    return
  }

  & flutter @Arguments
  $script:lastNativeExitCode = $LASTEXITCODE
}

function Invoke-FlutterChecked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  Write-Host "==> $Name"
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
  Write-Host '==> rg Demo residual scan'
  $libPath = Join-Path $appRoot 'lib'
  $testPath = Join-Path $appRoot 'test'
  & rg -n $demoResidualPattern $libPath $testPath
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 0) {
    throw 'Demo residual scan found matches.'
  }
  if ($exitCode -ne 1) {
    throw "Demo residual scan failed with exit code $exitCode"
  }
}

function Invoke-GitDiffCheck {
  Write-Host '==> git diff --check'
  Push-Location -LiteralPath $repoRoot
  try {
    & git diff --check
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "git diff --check failed with exit code $exitCode"
    }
  } finally {
    Pop-Location
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

try {
  New-Item -ItemType Directory -Force -Path $toolState | Out-Null
  $env:APPDATA = $toolState
  $env:LOCALAPPDATA = $toolState
  $env:PUB_CACHE = $pubCache

  if (-not $SkipPubGet) {
    Invoke-FlutterChecked `
      -Name 'flutter pub get --offline' `
      -Arguments @('pub', 'get', '--offline')
  }
  Invoke-FlutterChecked `
    -Name 'flutter analyze --no-pub' `
    -Arguments @('analyze', '--no-pub')
  Invoke-FlutterChecked `
    -Name 'flutter test --no-pub' `
    -Arguments @('test', '--no-pub')
  Invoke-DemoResidualScan
  Invoke-GitDiffCheck
  Write-Host 'RIMS smoke checks passed.'
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
