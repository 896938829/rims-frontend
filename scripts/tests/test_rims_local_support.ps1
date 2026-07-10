$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$localScript = Join-Path $scriptDir 'rims_local.ps1'
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected: '$Expected'. Actual: '$Actual'."
  }
}

function Assert-NotEqual {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -eq $Expected) {
    throw "$Message Expected a value different from: '$Expected'."
  }
}

function Assert-False {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Value -ne $false) {
    throw "$Message Expected: 'False'. Actual: '$Value'."
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Value -ne $true) {
    throw "$Message Expected: 'True'. Actual: '$Value'."
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Collection,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Collection -notcontains $Expected) {
    throw "$Message Expected collection to contain: '$Expected'."
  }
}

function Assert-HasProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  if ($Value.PSObject.Properties.Name -notcontains $PropertyName) {
    throw "Expected JSON result to contain property: '$PropertyName'."
  }
}

function Assert-ComponentSuccess {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $components = @($Result.components | Where-Object { $_.name -eq $Name })
  Assert-Equal `
    -Actual $components.Count `
    -Expected 1 `
    -Message "Expected exactly one '$Name' component."
  Assert-Equal `
    -Actual $components[0].ok `
    -Expected $true `
    -Message "Component '$Name' did not pass."
  Assert-Equal `
    -Actual $components[0].required `
    -Expected $true `
    -Message "Component '$Name' was not required."
}

function Assert-ComponentFailed {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $components = @($Result.components | Where-Object { $_.name -eq $Name })
  Assert-Equal `
    -Actual $components.Count `
    -Expected 1 `
    -Message "Expected exactly one '$Name' component."
  Assert-False `
    -Value $components[0].ok `
    -Message "Component '$Name' unexpectedly passed."
  Assert-Equal `
    -Actual $components[0].required `
    -Expected $true `
    -Message "Failed component '$Name' was not required."
  if ([string]::IsNullOrWhiteSpace([string]$components[0].remediation)) {
    throw "Failed component '$Name' omitted actionable remediation."
  }
}

function Assert-DoctorResultShape {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string[]]$StableResultFields
  )

  Assert-Equal `
    -Actual ($Result.PSObject.Properties.Name -join '|') `
    -Expected ($StableResultFields -join '|') `
    -Message 'Doctor result property sequence changed.'
  Assert-JsonArrayProperty -Value $Result -PropertyName 'components'
  Assert-JsonArrayProperty -Value $Result -PropertyName 'errors'

  $componentFields = @('name', 'ok', 'required', 'detail', 'remediation')
  foreach ($component in @($Result.components)) {
    Assert-Equal `
      -Actual ($component.PSObject.Properties.Name -join '|') `
      -Expected ($componentFields -join '|') `
      -Message "Component '$($component.name)' property sequence changed."
  }
}

function Assert-JsonArrayProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $property = $Value.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    throw "Expected JSON result to contain array property: '$PropertyName'."
  }
  if (-not ($property.Value -is [Array])) {
    throw "Expected JSON property '$PropertyName' to be array-shaped."
  }
}

function ConvertTo-WindowsCommandLineArgument {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

  $builder = New-Object Text.StringBuilder
  [void]$builder.Append('"')
  $backslashCount = 0

  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      $backslashCount++
      continue
    }

    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($backslashCount * 2) + 1)) -join '')
      [void]$builder.Append('"')
    } else {
      [void]$builder.Append(('\' * $backslashCount) -join '')
      [void]$builder.Append($character)
    }
    $backslashCount = 0
  }

  [void]$builder.Append(('\' * ($backslashCount * 2)) -join '')
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-LocalCli {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$Arguments
  )

  $powerShellExecutable = (Get-Process -Id $PID).Path
  $argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $localScript
  ) + $Arguments
  $quotedArguments = $argumentList | ForEach-Object {
    ConvertTo-WindowsCommandLineArgument -Value $_
  }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $powerShellExecutable
  $startInfo.Arguments = $quotedArguments -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
  $standardErrorTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $standardOutput = $standardOutputTask.Result
  $standardError = $standardErrorTask.Result

  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    StandardOutput = $standardOutput
    StandardError = $standardError
  }
}

function ConvertFrom-SingleJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  try {
    return $Text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$Context must write exactly one JSON document to stdout. $($_.Exception.Message)"
  }
}

function Get-TextHelpSectionEntries {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$SectionName
  )

  $header = "${SectionName}:"
  $inSection = $false
  $entries = @()

  foreach ($rawLine in ($Text -split '\r?\n')) {
    $line = $rawLine.Trim()
    if (-not $inSection) {
      if ($line -eq $header) {
        $inSection = $true
      }
      continue
    }

    if ($line.Length -eq 0 -or $line.EndsWith(':')) {
      break
    }
    $entries += $line
  }

  if (-not $inSection) {
    throw "Text help omitted section: '$SectionName'."
  }
  return $entries
}

function Get-TestAndroidChoice {
  $adbPath = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $onlineDevices = @(Get-RimsOnlineAndroidDevices `
      -AdbExecutable $adbPath)
  if ($onlineDevices.Count -gt 0) {
    return $onlineDevices[0]
  }

  $emulatorPath = Resolve-RimsAndroidTool `
    -CommandName 'emulator.exe' `
    -SdkRelativePath 'emulator\emulator.exe'
  $installedAvds = @(Get-RimsInstalledAndroidAvds `
      -EmulatorExecutable $emulatorPath)
  if ($installedAvds.Count -gt 0) {
    return $installedAvds[0]
  }

  return $null
}

function New-TestRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ProcessStartTimeUtc,
    [bool]$ComposeStartedByController = $false,
    [bool]$CleanupPending = $false
  )

  $startTime = $ProcessStartTimeUtc
  if ($null -ne $Process -and [string]::IsNullOrWhiteSpace($startTime)) {
    $startTime = $Process.StartTime.ToUniversalTime().ToString(
      'o',
      [Globalization.CultureInfo]::InvariantCulture
    )
  }
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    frontendPath = [IO.Path]::GetFullPath((Split-Path -Parent $scriptDir))
    backendPath = 'C:\test-backend-source'
    backendWorkspaceRoot = 'C:\test-backend-runtime'
    frontendCommit = $null
    backendCommit = $null
    target = 'none'
    backendPort = $BackendPort
    frontendPort = 8091
    startedAt = Get-RimsLocalTimestamp
    healthUrl = "http://localhost:$BackendPort/healthz"
    healthy = $false
    cleanupPending = $CleanupPending
    failureContext = ''
    windowsPid = if ($null -ne $Process) { $Process.Id } else { $null }
    windowsProcessStartTimeUtc = $startTime
    linuxProcessGroupId = $null
    runtimeRoot = $RuntimePaths.root
    statePath = $RuntimePaths.state
    stdoutLogPath = $RuntimePaths.stdoutLog
    stderrLogPath = $RuntimePaths.stderrLog
    commandSummary = 'test managed PowerShell child'
    dependencyOwnership = [pscustomobject][ordered]@{
      postgresExisted = -not $ComposeStartedByController
      postgresWasRunning = -not $ComposeStartedByController
      composeStartedByController = $ComposeStartedByController
      cleanupPending = $CleanupPending
      cleanupFailureDetail = ''
    }
  }
}

function Start-TestSleepProcess {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [Collections.Generic.List[Diagnostics.Process]]$TrackedProcesses
  )

  $process = Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList @(
      '-NoProfile',
      '-Command',
      'Start-Sleep -Seconds 120'
    ) `
    -WindowStyle Hidden `
    -PassThru
  [void]$TrackedProcesses.Add($process)
  return $process
}

function Test-TestProcessAlive {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Wait-TestProcessExit {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [int]$TimeoutSeconds = 5
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (-not (Test-TestProcessAlive -ProcessId $ProcessId)) {
      return $true
    }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)
  return -not (Test-TestProcessAlive -ProcessId $ProcessId)
}

function Get-TestEphemeralPort {
  $listener = [Net.Sockets.TcpListener]::new(
    [Net.IPAddress]::Loopback,
    0
  )
  try {
    $listener.Start()
    return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}
