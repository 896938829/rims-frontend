param(
  [ValidateSet('help', 'doctor', 'up', 'status', 'logs', 'restart',
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
  [switch]$IncludeDependencies
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
        -ScriptDirectory $scriptDir)
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

if ($Command -in @('up', 'status', 'logs', 'restart', 'down')) {
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
          -IncludeDependencies:$IncludeDependencies
        break
      }
      'status' {
        Invoke-RimsLocalStatus `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -IncludeDependencies:$IncludeDependencies
        break
      }
      'logs' {
        Invoke-RimsLocalLogs -ScriptDirectory $scriptDir
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
      'down' {
        Invoke-RimsLocalDown `
          -ScriptDirectory $scriptDir `
          -BackendDir $BackendDir `
          -BackendWorkspaceRoot $BackendWorkspaceRoot `
          -BackendPort $BackendPort `
          -IncludeDependencies:$IncludeDependencies
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
