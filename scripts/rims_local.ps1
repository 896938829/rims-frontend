param(
  [ValidateSet('help', 'doctor', 'up', 'status', 'health', 'logs', 'restart',
    'reset', 'smoke', 'down')]
  [string]$Command = 'status',
  [ValidateSet('none', 'web', 'android')]
  [string]$Target = 'none',
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$FrontendPort = 8091,
  [string]$AndroidDevice = $env:RIMS_ANDROID_DEVICE,
  [switch]$IncludeDependencies,
  [switch]$UseLocalTls
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'
. $commonScript

$commands = @(
  'help',
  'doctor',
  'up',
  'status',
  'health',
  'logs',
  'restart',
  'reset',
  'smoke',
  'down'
)
$targets = @('none', 'web', 'android')

if ($Command -eq 'help') {
  $result = New-RimsLocalResult -Command $Command
  $result | Add-Member -MemberType NoteProperty -Name commands -Value $commands
  $result | Add-Member -MemberType NoteProperty -Name targets -Value $targets
  $result = Complete-RimsLocalResult -Result $result -Ok $true -ExitCode 0

  if ($Output -eq 'Json') {
    Write-RimsLocalJson -Result $result
  } else {
    $lines = @(
      'RIMS local runtime',
      'Usage: powershell -File scripts/rims_local.ps1 -Command <command> -Target <target>',
      '',
      'Commands:'
    )
    $lines += $commands | ForEach-Object { "  $_" }
    $lines += @('', 'Targets:')
    $lines += $targets | ForEach-Object { "  $_" }
    [Console]::Out.WriteLine($lines -join [Environment]::NewLine)
  }

  exit 0
}

if ($Command -eq 'doctor') {
  $result = New-RimsLocalResult -Command $Command
  try {
    $result.components = @(Invoke-RimsLocalDoctor `
        -Target $Target `
        -BackendDir $BackendDir `
        -BackendWorkspaceRoot $BackendWorkspaceRoot `
        -AndroidDevice $AndroidDevice `
        -ScriptDirectory $scriptDir `
        -UseLocalTls:$UseLocalTls)
    $failedRequiredComponents = @($result.components | Where-Object {
        $_.required -and -not $_.ok
      })
    $ok = $failedRequiredComponents.Count -eq 0
    $exitCode = if ($ok) { 0 } else { 1 }
    $result = Complete-RimsLocalResult `
      -Result $result `
      -Ok $ok `
      -ExitCode $exitCode
  } catch {
    $result.errors = @("Internal doctor failure: $($_.Exception.Message)")
    $result = Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 2
  }

  if ($Output -eq 'Json') {
    Write-RimsLocalJson -Result $result
  } else {
    Write-RimsDoctorText -Result $result
  }
  exit $result.exitCode
}

if ($Command -eq 'smoke') {
  if ($UseLocalTls) {
    $message = 'Legacy Web and Android smoke wrappers remain pinned to explicit local HTTP until their TLS migration is verified.'
    if ($Output -eq 'Json') {
      $result = New-RimsLocalResult -Command $Command
      $result.errors = @($message)
      $result = Complete-RimsLocalResult `
        -Result $result `
        -Ok $false `
        -ExitCode 2
      Write-RimsLocalJson -Result $result
    } else {
      [Console]::Error.WriteLine($message)
    }
    exit 2
  }
  if ($Target -notin @('web', 'android')) {
    $message = "Smoke target '$Target' is not implemented yet."
    if ($Output -eq 'Json') {
      $result = New-RimsLocalResult -Command $Command
      $result.errors = @($message)
      $result = Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 2
      Write-RimsLocalJson -Result $result
    } else {
      [Console]::Error.WriteLine($message)
    }
    exit 2
  }

  $wrapperName = if ($Target -eq 'android') {
    'rims_android_smoke.ps1'
  } else { 'rims_web_e2e.ps1' }
  $wrapper = Join-Path $scriptDir $wrapperName
  $runtimePaths = Get-RimsRuntimePaths -ScriptDirectory $scriptDir
  $reportsDirectory = Join-Path $runtimePaths.root 'reports'
  New-Item -ItemType Directory -Force -Path $reportsDirectory | Out-Null
  $reportName = if ($Target -eq 'android') {
    'latest-android-smoke.json'
  } else { 'latest-smoke.json' }
  $reportPath = Join-Path $reportsDirectory $reportName
  $runReportPath = Join-Path `
    $reportsDirectory `
    "smoke-$PID-$([guid]::NewGuid().ToString('N')).json"
  $arguments = @('-BackendPort', "$BackendPort", '-ReportPath', $runReportPath)
  if (-not [string]::IsNullOrWhiteSpace($BackendDir)) {
    $arguments += @('-BackendDir', $BackendDir)
  }
  if (-not [string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
    $arguments += @('-BackendWorkspaceRoot', $BackendWorkspaceRoot)
  }
  if ($Target -eq 'android') {
    $arguments += @('-AndroidDevice', $AndroidDevice)
  }
  if ($IncludeDependencies) { $arguments += '-IncludeDependencies' }

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $captured = @(& powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $wrapper `
        @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }

  if (Test-Path -LiteralPath $runReportPath) {
    Move-Item -LiteralPath $runReportPath -Destination $reportPath -Force
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  } else {
    $report = $null
  }

  if ($Output -eq 'Json' -and $null -ne $report) {
    [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 12 -Compress))
  } elseif ($Output -eq 'Json') {
    $failure = New-RimsLocalResult -Command $Command
    $failure.errors = @(
      "Managed $Target smoke exited before producing a fresh report.",
      (($captured | Select-Object -Last 8) -join ' ')
    )
    $failure = Complete-RimsLocalResult `
      -Result $failure `
      -Ok $false `
      -ExitCode $exitCode
    Write-RimsLocalJson -Result $failure
  } else {
    $captured | ForEach-Object { [Console]::Out.WriteLine("$_") }
    if ($null -ne $report) {
      [Console]::Out.WriteLine("Smoke report: $reportPath")
    }
  }
  exit $exitCode
}

if ($Command -in @('up', 'status', 'health', 'logs', 'restart', 'reset', 'down')) {
  try {
    $result = switch ($Command) {
      'up' {
        Invoke-RimsLocalUp `
          -Target $Target `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -FrontendPort $FrontendPort `
          -AndroidDevice $AndroidDevice `
          -IncludeDependencies:$IncludeDependencies `
          -UseLocalTls:$UseLocalTls
        break
      }
      'status' {
        Invoke-RimsLocalStatus `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -IncludeDependencies:$IncludeDependencies `
          -UseLocalTls:$UseLocalTls
        break
      }
      'health' {
        Invoke-RimsLocalHealth `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -IncludeDependencies:$IncludeDependencies
        break
      }
      'logs' {
        Invoke-RimsLocalLogs `
          -ScriptDirectory $scriptDir `
          -UseLocalTls:$UseLocalTls
        break
      }
      'restart' {
        Invoke-RimsLocalRestart `
          -Target $Target `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -FrontendPort $FrontendPort `
          -AndroidDevice $AndroidDevice `
          -IncludeDependencies:$IncludeDependencies
        break
      }
      'reset' {
        Invoke-RimsLocalReset `
          -Target $Target `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort
        break
      }
      'down' {
        Invoke-RimsLocalDown `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -IncludeDependencies:$IncludeDependencies `
          -UseLocalTls:$UseLocalTls
        break
      }
    }
  } catch {
    $summary = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    $result = New-RimsLocalResult -Command $Command
    $result.errors = @("Runtime command failed: $summary")
    $result = Complete-RimsLocalResult `
      -Result $result `
      -Ok $false `
      -ExitCode 2
  }

  if ($Output -eq 'Json') {
    Write-RimsLocalJson -Result $result
  } elseif ($Command -eq 'logs') {
    Write-RimsLogsText -Result $result
  } else {
    Write-RimsLifecycleText -Result $result
  }
  exit $result.exitCode
}

$message = "Command '$Command' is not implemented yet."
$result = New-RimsLocalResult -Command $Command
$result.errors = @($message)
$result = Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 2

if ($Output -eq 'Json') {
  Write-RimsLocalJson -Result $result
} else {
  [Console]::Error.WriteLine($message)
}

exit $result.exitCode
