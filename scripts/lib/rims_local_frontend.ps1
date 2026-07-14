function Test-RimsFrontendIdentifier {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  return -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -match '\A[A-Za-z0-9_.:-]+\z'
}

function New-FlutterLaunchSpec {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$FrontendDirectory,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidSerial
  )

  if ($Target -eq 'none') {
    throw 'Target none does not have a Flutter launch command.'
  }
  if ($Target -eq 'android' -and
      -not (Test-RimsFrontendIdentifier -Value $AndroidSerial)) {
    throw 'Android serial contains unsupported command characters.'
  }

  $arguments = if ($Target -eq 'web') {
    @(
      'run',
      '--no-pub',
      '-d',
      'web-server',
      '--web-hostname',
      '127.0.0.1',
      '--web-port',
      [string]$FrontendPort,
      "--dart-define=API_BASE_URL=http://localhost:$BackendPort/api/v1"
    )
  } else {
    @(
      'run',
      '--no-pub',
      '--machine',
      '-d',
      $AndroidSerial,
      "--dart-define=API_BASE_URL=http://10.0.2.2:$BackendPort/api/v1"
    )
  }
  return [pscustomobject][ordered]@{
    target = $Target
    workingDirectory = $FrontendDirectory
    arguments = [object[]]$arguments
    url = if ($Target -eq 'web') {
      "http://127.0.0.1:$FrontendPort"
    } else {
      $null
    }
  }
}

function Get-RimsFrontendRuntimePaths {
  param([Parameter(Mandatory = $true)][psobject]$Paths)

  return [pscustomobject][ordered]@{
    stdoutLog = Join-Path $Paths.logs 'frontend.stdout.log'
    stderrLog = Join-Path $Paths.logs 'frontend.stderr.log'
    emulatorStdoutLog = Join-Path $Paths.logs 'emulator.stdout.log'
    emulatorStderrLog = Join-Path $Paths.logs 'emulator.stderr.log'
    activationGate = Join-Path $Paths.root 'frontend.activate'
    emulatorActivationGate = Join-Path $Paths.root 'emulator.activate'
  }
}

function Get-RimsNestedOwnedProcess {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][string]$PropertyName
  )

  $identity = Get-RimsObjectPropertyValue -Value $State -Name $PropertyName
  if ($null -eq $identity) {
    return $null
  }
  $tuple = [pscustomobject]@{
    windowsPid = Get-RimsObjectPropertyValue -Value $identity -Name 'windowsPid'
    windowsProcessStartTimeUtc = Get-RimsObjectPropertyValue `
      -Value $identity `
      -Name 'windowsProcessStartTimeUtc'
  }
  return Get-RimsOwnedProcess -State $tuple
}

function Test-RimsNestedOwnedProcess {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][string]$PropertyName
  )

  $process = Get-RimsNestedOwnedProcess -State $State -PropertyName $PropertyName
  if ($null -eq $process) {
    return $false
  }
  $process.Dispose()
  return $true
}

function Stop-RimsNestedOwnedProcess {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][string]$PropertyName
  )

  $process = Get-RimsNestedOwnedProcess -State $State -PropertyName $PropertyName
  if ($null -eq $process) {
    return [pscustomobject]@{
      ok = $true
      stopped = $false
      detail = "No exactly owned $PropertyName process is running."
    }
  }
  $processId = $process.Id
  $process.Dispose()
  try {
    $taskkill = Resolve-RimsCommandPath -Name 'taskkill.exe'
    if ([string]::IsNullOrWhiteSpace($taskkill)) {
      Stop-Process -Id $processId -Force -ErrorAction Stop
    } else {
      [void](Invoke-RimsExternalCommand `
          -FilePath $taskkill `
          -Arguments @('/PID', [string]$processId, '/T', '/F') `
          -TimeoutSeconds 15)
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and
        (Test-RimsNestedOwnedProcess -State $State -PropertyName $PropertyName)) {
      Start-Sleep -Milliseconds 100
    }
    $stopped = -not (Test-RimsNestedOwnedProcess `
        -State $State `
        -PropertyName $PropertyName)
    return [pscustomobject]@{
      ok = $stopped
      stopped = $stopped
      detail = if ($stopped) {
        "Stopped exactly owned $PropertyName process $processId."
      } else {
        "Exactly owned $PropertyName process $processId did not stop."
      }
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      stopped = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function Get-RimsAdbDeviceSerialsFromOutput {
  param([AllowNull()][AllowEmptyString()][string]$Output)

  $serials = @()
  foreach ($line in ($Output -split '\r?\n')) {
    if ($line -match '\A([^\s]+)\s+device(?:\s|$)') {
      $serial = $Matches[1]
      if (Test-RimsFrontendIdentifier -Value $serial) {
        $serials += $serial
      }
    }
  }
  return @($serials | Select-Object -Unique)
}

function Get-RimsAdbDeviceSerials {
  param([Parameter(Mandatory = $true)][string]$AdbExecutable)

  $result = Invoke-RimsExternalCommand `
    -FilePath $AdbExecutable `
    -Arguments @('devices') `
    -TimeoutSeconds 15
  if ($result.ExitCode -ne 0) {
    return @()
  }
  return @(Get-RimsAdbDeviceSerialsFromOutput -Output $result.StandardOutput)
}

function Get-RimsAndroidAvdName {
  param(
    [Parameter(Mandatory = $true)][string]$AdbExecutable,
    [Parameter(Mandatory = $true)][string]$Serial
  )

  if (-not (Test-RimsFrontendIdentifier -Value $Serial)) {
    return $null
  }
  $result = Invoke-RimsExternalCommand `
    -FilePath $AdbExecutable `
    -Arguments @('-s', $Serial, 'emu', 'avd', 'name') `
    -TimeoutSeconds 15
  if ($result.ExitCode -ne 0) {
    return $null
  }
  $name = @(($result.StandardOutput -split '\r?\n') | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -ne 'OK'
    } | Select-Object -First 1)
  if ($name.Count -eq 0) {
    return $null
  }
  return $name[0].Trim()
}

function Find-RimsRunningAndroidTarget {
  param(
    [Parameter(Mandatory = $true)][string]$RequestedDevice,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$OnlineSerials,
    [Parameter(Mandatory = $true)][scriptblock]$AvdNameAction
  )

  if (-not (Test-RimsFrontendIdentifier -Value $RequestedDevice)) {
    throw 'Android device contains unsupported command characters.'
  }
  foreach ($serial in $OnlineSerials) {
    $avdName = [string](& $AvdNameAction $serial)
    if ($avdName -ceq $RequestedDevice) {
      return [pscustomobject]@{
        found = $true
        serial = $serial
        avdName = $avdName
      }
    }
  }
  return [pscustomobject]@{ found = $false; serial = $null; avdName = $null }
}

function Wait-RimsAndroidSerialForAvd {
  param(
    [Parameter(Mandatory = $true)][string]$AdbExecutable,
    [Parameter(Mandatory = $true)][string]$AvdName,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    foreach ($serial in @(Get-RimsAdbDeviceSerials -AdbExecutable $AdbExecutable)) {
      if ((Get-RimsAndroidAvdName `
          -AdbExecutable $AdbExecutable `
          -Serial $serial) -ceq $AvdName) {
        return $serial
      }
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $null
}

function Wait-RimsAndroidBootCompleted {
  param(
    [Parameter(Mandatory = $true)][string]$AdbExecutable,
    [Parameter(Mandatory = $true)][string]$Serial,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180,
    [AllowNull()][scriptblock]$ProbeAction
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $completed = if ($null -ne $ProbeAction) {
      [bool](& $ProbeAction $AdbExecutable $Serial)
    } else {
      $result = Invoke-RimsExternalCommand `
        -FilePath $AdbExecutable `
        -Arguments @('-s', $Serial, 'shell', 'getprop', 'sys.boot_completed') `
        -TimeoutSeconds 15
      $result.ExitCode -eq 0 -and $result.StandardOutput.Trim() -eq '1'
    }
    if ($completed) {
      return $true
    }
    Start-Sleep -Milliseconds 1000
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Read-RimsSharedTextFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = $null
  $reader = $null
  try {
    $stream = [IO.FileStream]::new(
      $Path,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    $reader = [IO.StreamReader]::new(
      $stream,
      [Text.Encoding]::UTF8,
      $true
    )
    return $reader.ReadToEnd()
  } finally {
    if ($null -ne $reader) {
      $reader.Dispose()
    } elseif ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Test-RimsFlutterAppStartedMachineOutput {
  param([AllowNull()][AllowEmptyString()][string]$Output)

  foreach ($line in ($Output -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    try {
      $parsed = ConvertFrom-Json -InputObject $line -ErrorAction Stop
      $events = if ($parsed -is [System.Array]) {
        $parsed
      } else {
        ,$parsed
      }
      foreach ($event in $events) {
        $eventName = if ($null -eq $event) {
          ''
        } elseif ($null -eq $event.PSObject.Properties['event']) {
          ''
        } else {
          [string]$event.PSObject.Properties['event'].Value
        }
        if ($eventName -ceq 'app.started') {
          return $true
        }
      }
    } catch {
    }
  }
  return $false
}

function Get-RimsFlutterLaunchDiagnosticLines {
  param([AllowNull()][AllowEmptyString()][string]$Text)

  $lines = @()
  foreach ($line in ($Text -split '\r?\n')) {
    if ($line -match '^RIMS_FLUTTER_LAUNCH\s+(.+)$') {
      $lines += $Matches[1]
    }
  }
  return $lines
}

function Get-RimsAndroidMachineReadinessTimeoutSeconds {
  return 900
}

function Wait-RimsFlutterAppStarted {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 90,
    [AllowNull()][scriptblock]$ReadOutputAction
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (-not (Test-RimsNestedOwnedProcess `
        -State $State `
        -PropertyName 'frontend')) {
      return $false
    }
    try {
      $output = if ($null -ne $ReadOutputAction) {
        [string](& $ReadOutputAction $OutputPath)
      } elseif (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        Read-RimsSharedTextFile -Path $OutputPath
      } else {
        $null
      }
      if ($null -ne $output -and
          (Test-RimsFlutterAppStartedMachineOutput `
            -Output $output)) {
        return $true
      }
    } catch {
      # A redirected stdout handle can be transiently unavailable while Flutter starts.
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  return $false
}

function New-RimsFrontendProcessIdentity {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

  return [pscustomobject][ordered]@{
    windowsPid = $Process.Id
    windowsProcessStartTimeUtc = $Process.StartTime.ToUniversalTime().ToString(
      'o',
      [Globalization.CultureInfo]::InvariantCulture
    )
  }
}

function Test-RimsFrontendPortOwnedByProcess {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$RootProcessId
  )

  try {
    $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
        Select-Object -First 1)
    if ($listener.Count -eq 0) {
      return $false
    }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $known = New-Object 'Collections.Generic.HashSet[int]'
    [void]$known.Add($RootProcessId)
    do {
      $added = $false
      foreach ($process in $processes) {
        if ($known.Contains([int]$process.ParentProcessId) -and
            $known.Add([int]$process.ProcessId)) {
          $added = $true
        }
      }
    } while ($added)
    return $known.Contains([int]$listener[0].OwningProcess)
  } catch {
    return $null
  }
}

function Invoke-RimsFrontendLaunchStateMachine {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][scriptblock]$PersistStateAction,
    [Parameter(Mandatory = $true)][scriptblock]$SpawnAction,
    [Parameter(Mandatory = $true)][scriptblock]$ActivateAction,
    [Parameter(Mandatory = $true)][scriptblock]$ReadinessAction,
    [Parameter(Mandatory = $true)][scriptblock]$CleanupAction
  )

  $spawned = $null
  $ownershipPersisted = $false
  $activationOpen = $false
  try {
    $State.lifecycleStage = 'frontendLaunching'
    $State.cleanupPending = $true
    & $PersistStateAction $State
    $spawned = & $SpawnAction
    if ($null -eq $spawned -or -not $spawned.ok) {
      throw 'Frontend process did not start.'
    }
    $State.frontend = $spawned.identity
    & $PersistStateAction $State
    $ownershipPersisted = $true
    & $ActivateAction
    $activationOpen = $true
    if (-not (& $ReadinessAction $State)) {
      throw 'Frontend readiness timed out.'
    }
    $State.frontend.cleanupPending = $false
    $State.cleanupPending = $false
    $State.lifecycleStage = 'healthy'
    $State.healthy = $true
    & $PersistStateAction $State
    return [pscustomobject]@{
      ok = $true
      ownershipPersisted = $true
      activationOpen = $true
      cleanupAllowed = $true
      detail = 'Frontend became ready.'
    }
  } catch {
    $detail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    $cleanupOk = $true
    if ($null -ne $spawned) {
      try {
        $cleanupOk = [bool](& $CleanupAction $State)
      } catch {
        $cleanupOk = $false
      }
    }
    return [pscustomobject]@{
      ok = $false
      ownershipPersisted = $ownershipPersisted
      activationOpen = $activationOpen
      cleanupAllowed = $ownershipPersisted
      cleanupOk = $cleanupOk
      detail = $detail
    }
  }
}

function Start-RimsHiddenFlutterProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FlutterExecutable,
    [Parameter(Mandatory = $true)][psobject]$LaunchSpec,
    [Parameter(Mandatory = $true)][psobject]$FrontendPaths
  )

  $payload = [pscustomobject]@{
    executable = $FlutterExecutable
    workingDirectory = $LaunchSpec.workingDirectory
    gate = $FrontendPaths.activationGate
    target = $LaunchSpec.target
    arguments = @($LaunchSpec.arguments)
  } | ConvertTo-Json -Compress
  $payload64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($payload)
  )
  $launcher = @'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:RIMS_FLUTTER_LAUNCH))|ConvertFrom-Json
$ErrorActionPreference='Continue'
$limit=(Get-Date).AddSeconds(30)
while(-not (Test-Path -LiteralPath $p.gate -PathType Leaf)){
  if((Get-Date)-ge $limit){exit 124}
  Start-Sleep -Milliseconds 50
}
[Console]::Error.WriteLine("RIMS_FLUTTER_LAUNCH gate-open target=$($p.target) executable=$($p.executable) argumentCount=$(@($p.arguments).Count)")
Set-Location -LiteralPath $p.workingDirectory
[Console]::Error.WriteLine("RIMS_FLUTTER_LAUNCH invoke-before target=$($p.target)")
& $p.executable @($p.arguments)
$code=$LASTEXITCODE
[Console]::Error.WriteLine("RIMS_FLUTTER_LAUNCH invoke-after target=$($p.target) exitCode=$code")
exit $code
'@
  $encoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($launcher)
  )
  $previousPayload = $env:RIMS_FLUTTER_LAUNCH
  try {
    $env:RIMS_FLUTTER_LAUNCH = $payload64
    $process = Start-Process `
      -FilePath (Get-Process -Id $PID).Path `
      -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) `
      -WorkingDirectory $LaunchSpec.workingDirectory `
      -RedirectStandardOutput $FrontendPaths.stdoutLog `
      -RedirectStandardError $FrontendPaths.stderrLog `
      -WindowStyle Hidden `
      -PassThru
    return [pscustomobject]@{
      ok = $true
      process = $process
      identity = New-RimsFrontendProcessIdentity -Process $process
    }
  } finally {
    $env:RIMS_FLUTTER_LAUNCH = $previousPayload
  }
}

function Invoke-RimsAndroidEmulatorLaunchStateMachine {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][scriptblock]$PersistStateAction,
    [Parameter(Mandatory = $true)][scriptblock]$SpawnAction,
    [AllowNull()][scriptblock]$ActivateAction,
    [Parameter(Mandatory = $true)][scriptblock]$SerialAction,
    [Parameter(Mandatory = $true)][scriptblock]$BootAction,
    [Parameter(Mandatory = $true)][scriptblock]$CleanupAction
  )

  $spawned = $null
  $avdName = [string](Get-RimsObjectPropertyValue `
      -Value $State.emulator `
      -Name 'avdName' `
      -DefaultValue '')
  try {
    $spawned = & $SpawnAction
    if ($null -eq $spawned -or -not $spawned.ok -or
        $null -eq $spawned.identity) {
      throw "Android AVD '$avdName' did not start."
    }
    $State.emulator.owned = $true
    $State.emulator.windowsPid = $spawned.identity.windowsPid
    $State.emulator.windowsProcessStartTimeUtc = `
      $spawned.identity.windowsProcessStartTimeUtc
    $State.emulator | Add-Member `
      -MemberType NoteProperty `
      -Name launcherWindowsPid `
      -Value $spawned.identity.windowsPid `
      -Force
    $State.emulator | Add-Member `
      -MemberType NoteProperty `
      -Name launcherWindowsProcessStartTimeUtc `
      -Value $spawned.identity.windowsProcessStartTimeUtc `
      -Force
    & $PersistStateAction $State
    if ($null -ne $ActivateAction) {
      & $ActivateAction
    }

    $serial = [string](& $SerialAction)
    if ([string]::IsNullOrWhiteSpace($serial)) {
      throw "Android AVD '$avdName' did not expose an adb serial in time."
    }
    $State.emulator.serial = $serial
    & $PersistStateAction $State

    if (-not (& $BootAction $serial)) {
      throw "Android AVD '$avdName' did not complete boot in time."
    }
    $State.emulator.cleanupPending = $false
    $State.cleanupPending = $false
    & $PersistStateAction $State
    return [pscustomobject][ordered]@{
      ok = $true
      serial = $serial
      detail = "Started Android AVD '$avdName' as $serial."
    }
  } catch {
    if ($null -ne $spawned) {
      try {
        [void](& $CleanupAction $State)
      } catch {
      }
    }
    return [pscustomobject][ordered]@{
      ok = $false
      serial = $null
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function New-RimsHiddenEmulatorLauncherScript {
  return @'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:RIMS_EMULATOR_LAUNCH))|ConvertFrom-Json
$limit=(Get-Date).AddSeconds(30)
while(-not (Test-Path -LiteralPath $p.gate -PathType Leaf)){
  if((Get-Date)-ge $limit){exit 124}
  Start-Sleep -Milliseconds 50
}
$child=Start-Process -FilePath $p.executable -ArgumentList @('-avd',$p.avdName,'-no-window') -WindowStyle Hidden -PassThru
$child.WaitForExit()
exit $child.ExitCode
'@
}

function Start-RimsHiddenEmulatorLauncher {
  param(
    [Parameter(Mandatory = $true)][string]$EmulatorExecutable,
    [Parameter(Mandatory = $true)][string]$AvdName,
    [Parameter(Mandatory = $true)][psobject]$FrontendPaths
  )

  $payload = [pscustomobject]@{
    executable = $EmulatorExecutable
    avdName = $AvdName
    gate = $FrontendPaths.emulatorActivationGate
  } | ConvertTo-Json -Compress
  $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
  $launcher = New-RimsHiddenEmulatorLauncherScript
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
  $previousPayload = $env:RIMS_EMULATOR_LAUNCH
  try {
    $env:RIMS_EMULATOR_LAUNCH = $payload64
    $process = Start-Process `
      -FilePath (Get-Process -Id $PID).Path `
      -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) `
      -RedirectStandardOutput $FrontendPaths.emulatorStdoutLog `
      -RedirectStandardError $FrontendPaths.emulatorStderrLog `
      -WindowStyle Hidden `
      -PassThru
    return [pscustomobject]@{
      ok = $true
      identity = New-RimsFrontendProcessIdentity -Process $process
    }
  } finally {
    $env:RIMS_EMULATOR_LAUNCH = $previousPayload
  }
}

function Resolve-RimsAndroidRuntime {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][psobject]$Paths,
    [AllowNull()][AllowEmptyString()][string]$AndroidDevice
  )

  $requested = if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
    'Medium_Phone_API_36.1'
  } else {
    $AndroidDevice
  }
  if (-not (Test-RimsFrontendIdentifier -Value $requested)) {
    throw 'Android device contains unsupported command characters.'
  }
  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $emulator = Resolve-RimsAndroidTool `
    -CommandName 'emulator.exe' `
    -SdkRelativePath 'emulator\emulator.exe'
  $online = @(Get-RimsAdbDeviceSerials -AdbExecutable $adb)
  $running = Find-RimsRunningAndroidTarget `
    -RequestedDevice $requested `
    -OnlineSerials $online `
    -AvdNameAction {
      param($serial)
      Get-RimsAndroidAvdName -AdbExecutable $adb -Serial $serial
    }
  if ($running.found) {
    $State.emulator = [pscustomobject][ordered]@{
      avdName = $running.avdName
      serial = $running.serial
      owned = $false
      windowsPid = $null
      windowsProcessStartTimeUtc = $null
      cleanupPending = $false
      stdoutLogPath = $null
      stderrLogPath = $null
    }
    Write-RimsRuntimeState -Paths $Paths -State $State
    return [pscustomobject]@{
      ok = $true
      serial = $running.serial
      avdName = $running.avdName
      owned = $false
      detail = 'Using a pre-existing Android device; it remains user-managed.'
    }
  }

  $installed = @(Get-RimsInstalledAndroidAvds -EmulatorExecutable $emulator)
  if ($installed -notcontains $requested) {
    throw "Requested Android AVD '$requested' is not installed."
  }
  $frontendPaths = Get-RimsFrontendRuntimePaths -Paths $Paths
  $State.emulator = [pscustomobject][ordered]@{
    avdName = $requested
    serial = $null
    owned = $false
    launchRequestedByController = $true
    launcherCommandMarker = 'rims-emulator-launcher'
    launcherWindowsPid = $null
    launcherWindowsProcessStartTimeUtc = $null
    windowsPid = $null
    windowsProcessStartTimeUtc = $null
    cleanupPending = $true
    stdoutLogPath = $frontendPaths.emulatorStdoutLog
    stderrLogPath = $frontendPaths.emulatorStderrLog
  }
  $State.cleanupPending = $true
  Write-RimsRuntimeState -Paths $Paths -State $State
  if (Test-Path -LiteralPath $frontendPaths.emulatorActivationGate -PathType Leaf) {
    Remove-Item -LiteralPath $frontendPaths.emulatorActivationGate -Force
  }

  $launch = Invoke-RimsAndroidEmulatorLaunchStateMachine `
    -State $State `
    -PersistStateAction {
      param($current)
      Write-RimsRuntimeState -Paths $Paths -State $current
    } `
    -SpawnAction {
      Start-RimsHiddenEmulatorLauncher `
        -EmulatorExecutable $emulator `
        -AvdName $requested `
        -FrontendPaths $frontendPaths
    } `
    -ActivateAction {
      [IO.File]::WriteAllText($frontendPaths.emulatorActivationGate, 'activate')
    } `
    -SerialAction {
      Wait-RimsAndroidSerialForAvd `
        -AdbExecutable $adb `
        -AvdName $requested
    } `
    -BootAction {
      param($serial)
      Wait-RimsAndroidBootCompleted `
        -AdbExecutable $adb `
        -Serial $serial
    } `
    -CleanupAction {
      param($current)
      (Stop-RimsNestedOwnedProcess `
          -State $current `
          -PropertyName 'emulator').ok
    }
  if (-not $launch.ok) {
    throw $launch.detail
  }
  Remove-Item -LiteralPath $frontendPaths.emulatorActivationGate -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{
    ok = $true
    serial = $launch.serial
    avdName = $requested
    owned = $true
    detail = "Started Android AVD '$requested' as $($launch.serial)."
  }
}

function Start-RimsManagedFrontend {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][psobject]$Paths,
    [Parameter(Mandatory = $true)][ValidateSet('web', 'android')][string]$Target,
    [Parameter(Mandatory = $true)][int]$BackendPort,
    [Parameter(Mandatory = $true)][int]$FrontendPort,
    [AllowNull()][AllowEmptyString()][string]$AndroidDevice
  )

  $frontendDirectory = Join-Path $State.frontendPath 'rims_frontend'
  $frontendPaths = Get-RimsFrontendRuntimePaths -Paths $Paths
  Initialize-RimsRuntimeDirectories -Paths $Paths
  $frontendPortLock = $null
  try {
    if ($Target -eq 'web') {
      $frontendPortLock = Enter-RimsFrontendPortLock -FrontendPort $FrontendPort
      if (-not $frontendPortLock.ok) {
        return [pscustomobject]@{
          ok = $false
          detail = $frontendPortLock.detail
          cleanupPending = $false
        }
      }
      if (Test-RimsTcpPortListening -Port $FrontendPort) {
        return [pscustomobject]@{
          ok = $false
          detail = "Frontend port $FrontendPort is occupied by an unmanaged listener; it was left untouched."
          cleanupPending = $false
        }
      }
    }

    $android = $null
    try {
    if ($Target -eq 'android') {
      $android = Resolve-RimsAndroidRuntime `
        -State $State `
        -Paths $Paths `
        -AndroidDevice $AndroidDevice
    }
    $serial = if ($null -eq $android) { $null } else { $android.serial }
    $launchSpec = New-FlutterLaunchSpec `
      -Target $Target `
      -FrontendDirectory $frontendDirectory `
      -BackendPort $BackendPort `
      -FrontendPort $FrontendPort `
      -AndroidSerial $serial
    $flutter = Resolve-RimsCommandPath -Name 'flutter'
    if ([string]::IsNullOrWhiteSpace($flutter)) {
      throw 'flutter was not found on PATH.'
    }
    if (Test-Path -LiteralPath $frontendPaths.activationGate -PathType Leaf) {
      Remove-Item -LiteralPath $frontendPaths.activationGate -Force
    }
    $State.target = $Target
    $State.frontendPort = $FrontendPort
    $State.frontend = [pscustomobject][ordered]@{
      target = $Target
      url = $launchSpec.url
      healthUrl = $launchSpec.url
      commit = Get-RimsGitCommit -Path $State.frontendPath
      windowsPid = $null
      windowsProcessStartTimeUtc = $null
      cleanupPending = $true
      appStarted = $false
      stdoutLogPath = $frontendPaths.stdoutLog
      stderrLogPath = $frontendPaths.stderrLog
      commandSummary = "flutter run -d $(if ($Target -eq 'web') { 'web-server' } else { $serial })"
    }
    $outcome = Invoke-RimsFrontendLaunchStateMachine `
      -State $State `
      -PersistStateAction {
        param($current)
        Write-RimsRuntimeState -Paths $Paths -State $current
      } `
      -SpawnAction {
        $spawned = Start-RimsHiddenFlutterProcess `
          -FlutterExecutable $flutter `
          -LaunchSpec $launchSpec `
          -FrontendPaths $frontendPaths
        $identity = $State.frontend
        $identity.windowsPid = $spawned.identity.windowsPid
        $identity.windowsProcessStartTimeUtc = `
          $spawned.identity.windowsProcessStartTimeUtc
        return [pscustomobject]@{ ok = $true; identity = $identity }
      } `
      -ActivateAction {
        [IO.File]::WriteAllText($frontendPaths.activationGate, 'activate')
      } `
      -ReadinessAction {
        param($current)
        if ($Target -eq 'web') {
          $deadline = (Get-Date).AddSeconds(90)
          do {
            if (-not (Test-RimsNestedOwnedProcess `
                -State $current `
                -PropertyName 'frontend')) {
              return $false
            }
            $listenerOwned = Test-RimsFrontendPortOwnedByProcess `
              -Port $FrontendPort `
              -RootProcessId $current.frontend.windowsPid
            if ($listenerOwned -eq $false) {
              return $false
            }
            if (Test-RimsHealthEndpoint `
                -Url $launchSpec.url `
                -TimeoutSeconds 2) {
              return $true
            }
            Start-Sleep -Milliseconds 500
          } while ((Get-Date) -lt $deadline)
          return $false
        }
        $started = Wait-RimsFlutterAppStarted `
          -State $current `
          -OutputPath $frontendPaths.stdoutLog `
          -TimeoutSeconds (Get-RimsAndroidMachineReadinessTimeoutSeconds)
        if ($started) {
          $current.frontend.appStarted = $true
        }
        return $started
      } `
      -CleanupAction {
        param($current)
        return (Stop-RimsNestedOwnedProcess `
            -State $current `
            -PropertyName 'frontend').ok
      }
    if (-not $outcome.ok) {
      throw $outcome.detail
    }
    return [pscustomobject]@{
      ok = $true
      detail = if ($Target -eq 'web') {
        "Managed Web frontend is ready at $($launchSpec.url)."
      } else {
        "Managed Android frontend is running on $serial."
      }
      cleanupPending = $false
    }
    } catch {
    $failure = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    $frontendCleanup = Stop-RimsNestedOwnedProcess `
      -State $State `
      -PropertyName 'frontend'
    $emulatorCleanup = Stop-RimsOwnedEmulator -State $State
    $cleanupOk = $frontendCleanup.ok -and $emulatorCleanup.ok
    if ($cleanupOk) {
      $State.frontend = $null
      $State.emulator = $null
      $State.target = 'none'
      $State.cleanupPending = $false
      $State.healthy = $true
      $State.lifecycleStage = 'healthy'
      $State.failureContext = ''
    } else {
      $State.cleanupPending = $true
      $State.healthy = $false
      $State.failureContext = $failure
    }
    try {
      Write-RimsRuntimeState -Paths $Paths -State $State
    } catch {
      $cleanupOk = $false
    }
      return [pscustomobject]@{
        ok = $false
        detail = $failure
        cleanupPending = -not $cleanupOk
      }
    }
  } finally {
    Exit-RimsFrontendPortLock -Lock $frontendPortLock
  }
}

function Stop-RimsOwnedEmulator {
  param([AllowNull()][object]$State)

  $emulator = Get-RimsObjectPropertyValue -Value $State -Name 'emulator'
  $owned = [bool](Get-RimsObjectPropertyValue `
      -Value $emulator `
      -Name 'owned' `
      -DefaultValue $false)
  if (-not $owned) {
    return [pscustomobject]@{
      ok = $true
      stopped = $false
      detail = 'Pre-existing Android device remains user-managed.'
    }
  }
  return Stop-RimsNestedOwnedProcess -State $State -PropertyName 'emulator'
}

function Get-RimsAndroidEmulatorHealth {
  param(
    [Parameter(Mandatory = $true)][psobject]$Emulator,
    [Parameter(Mandatory = $true)][scriptblock]$OnlineSerialsAction,
    [Parameter(Mandatory = $true)][scriptblock]$AvdNameAction,
    [Parameter(Mandatory = $true)][scriptblock]$BootCompletedAction
  )

  $serial = [string](Get-RimsObjectPropertyValue `
      -Value $Emulator `
      -Name 'serial' `
      -DefaultValue '')
  $expectedAvd = [string](Get-RimsObjectPropertyValue `
      -Value $Emulator `
      -Name 'avdName' `
      -DefaultValue '')
  if ([string]::IsNullOrWhiteSpace($serial) -or
      [string]::IsNullOrWhiteSpace($expectedAvd)) {
    return [pscustomobject][ordered]@{
      healthy = $false
      detail = 'Pre-existing Android device state is missing its serial or AVD name.'
    }
  }
  try {
    $onlineSerials = @(& $OnlineSerialsAction)
    if (-not (@($onlineSerials | Where-Object { $_ -ceq $serial }).Count -eq 1)) {
      return [pscustomobject][ordered]@{
        healthy = $false
        detail = "Pre-existing Android device '$serial' is no longer online."
      }
    }
    $actualAvd = [string](& $AvdNameAction $serial)
    if ($actualAvd -cne $expectedAvd) {
      return [pscustomobject][ordered]@{
        healthy = $false
        detail = "Pre-existing Android device '$serial' does not match recorded AVD '$expectedAvd'."
      }
    }
    $booted = [bool](& $BootCompletedAction $serial)
    return [pscustomobject][ordered]@{
      healthy = $booted
      detail = if ($booted) {
        "Pre-existing Android device '$serial' is online with AVD '$expectedAvd'."
      } else {
        "Pre-existing Android device '$serial' has not completed boot."
      }
    }
  } catch {
    return [pscustomobject][ordered]@{
      healthy = $false
      detail = 'Pre-existing Android device could not be verified through adb.'
    }
  }
}

function Get-RimsUnmanagedAndroidEmulatorHealth {
  param(
    [Parameter(Mandatory = $true)][psobject]$Emulator,
    [Parameter(Mandatory = $true)][scriptblock]$OnlineSerialsAction,
    [Parameter(Mandatory = $true)][scriptblock]$AvdNameAction,
    [AllowNull()][scriptblock]$BootCompletedAction
  )

  if ($null -eq $BootCompletedAction) {
    $BootCompletedAction = { param($serial) return $true }
  }
  return Get-RimsAndroidEmulatorHealth `
    -Emulator $Emulator `
    -OnlineSerialsAction $OnlineSerialsAction `
    -AvdNameAction $AvdNameAction `
    -BootCompletedAction $BootCompletedAction
}

function Test-RimsStateOwnsAnyFrontendProcess {
  param([AllowNull()][object]$State)

  return (Test-RimsNestedOwnedProcess `
      -State $State `
      -PropertyName 'frontend') -or
    (Test-RimsNestedOwnedProcess `
      -State $State `
      -PropertyName 'emulator')
}

function Test-RimsAnyRuntimeCleanupPending {
  param([AllowNull()][object]$State)

  $frontend = Get-RimsObjectPropertyValue -Value $State -Name 'frontend'
  $emulator = Get-RimsObjectPropertyValue -Value $State -Name 'emulator'
  return (Test-RimsRuntimeCleanupPending -State $State) -or
    [bool](Get-RimsObjectPropertyValue `
      -Value $frontend `
      -Name 'cleanupPending' `
      -DefaultValue $false) -or
    [bool](Get-RimsObjectPropertyValue `
      -Value $emulator `
      -Name 'cleanupPending' `
      -DefaultValue $false)
}

function Stop-RimsFrontendResources {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][psobject]$Paths
  )

  $frontend = Stop-RimsNestedOwnedProcess `
    -State $State `
    -PropertyName 'frontend'
  if (-not $frontend.ok) {
    return [pscustomobject]@{
      ok = $false
      cleanupPending = $true
      detail = $frontend.detail
    }
  }
  $emulator = Stop-RimsOwnedEmulator -State $State
  if (-not $emulator.ok) {
    return [pscustomobject]@{
      ok = $false
      cleanupPending = $true
      detail = $emulator.detail
    }
  }
  $State | Add-Member -MemberType NoteProperty -Name frontend -Value $null -Force
  $State | Add-Member -MemberType NoteProperty -Name emulator -Value $null -Force
  $State | Add-Member -MemberType NoteProperty -Name target -Value 'none' -Force
  return [pscustomobject]@{
    ok = $true
    cleanupPending = $false
    detail = 'Exactly owned frontend resources were cleaned up; unmanaged devices were left untouched.'
  }
}

function Get-RimsFrontendComponent {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][int]$FrontendPort
  )

  $target = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'target' `
      -DefaultValue 'none')
  $frontend = Get-RimsObjectPropertyValue -Value $State -Name 'frontend'
  $cleanupPending = [bool](Get-RimsObjectPropertyValue `
      -Value $frontend `
      -Name 'cleanupPending' `
      -DefaultValue $false)
  if ($target -eq 'none' -and -not $cleanupPending) {
    return [pscustomobject][ordered]@{
      name = 'frontend'
      ok = $true
      required = $false
      detail = 'Frontend target is none; only the backend is managed.'
      remediation = ''
      target = 'none'
      managed = $false
      healthy = $true
      port = $FrontendPort
    }
  }
  $owned = Test-RimsNestedOwnedProcess -State $State -PropertyName 'frontend'
  $url = [string](Get-RimsObjectPropertyValue `
      -Value $frontend `
      -Name 'url' `
      -DefaultValue '')
  $appStarted = [bool](Get-RimsObjectPropertyValue `
      -Value $frontend `
      -Name 'appStarted' `
      -DefaultValue $false)
  $healthy = -not $cleanupPending -and $owned -and $(if ($target -eq 'web') {
      Test-RimsHealthEndpoint -Url $url -TimeoutSeconds 2
    } elseif ($target -eq 'android') {
      $appStarted
    } else {
      $true
    })
  return [pscustomobject][ordered]@{
    name = 'frontend'
    ok = $healthy
    required = $true
    detail = if ($cleanupPending) {
      "Managed $target frontend cleanup remains pending."
    } elseif ($healthy) {
      "Managed $target frontend is healthy$(if ($url) { " at $url" })."
    } else {
      "Managed $target frontend is absent or unhealthy."
    }
    remediation = if ($healthy) { '' } elseif ($cleanupPending) {
      'Run down with the same parameters to retry exact frontend cleanup.'
    } else {
      'Inspect frontend logs, then run restart or down.'
    }
    target = $target
    managed = $owned
    healthy = $healthy
    port = $FrontendPort
    windowsPid = Get-RimsObjectPropertyValue -Value $frontend -Name 'windowsPid'
    url = $url
  }
}

function Get-RimsEmulatorComponent {
  param([Parameter(Mandatory = $true)][psobject]$State)

  $emulator = Get-RimsObjectPropertyValue -Value $State -Name 'emulator'
  if ($null -eq $emulator) {
    return $null
  }
  $owned = [bool](Get-RimsObjectPropertyValue `
      -Value $emulator `
      -Name 'owned' `
      -DefaultValue $false)
  $cleanupPending = [bool](Get-RimsObjectPropertyValue `
      -Value $emulator `
      -Name 'cleanupPending' `
      -DefaultValue $false)
  $verification = $null
  $running = if ($cleanupPending) {
    $false
  } else {
    try {
      $adb = Resolve-RimsAndroidTool `
        -CommandName 'adb.exe' `
        -SdkRelativePath 'platform-tools\adb.exe'
      $verification = Get-RimsAndroidEmulatorHealth `
        -Emulator $emulator `
        -OnlineSerialsAction {
          Get-RimsAdbDeviceSerials -AdbExecutable $adb
        } `
        -AvdNameAction {
          param($serial)
          Get-RimsAndroidAvdName -AdbExecutable $adb -Serial $serial
        } `
        -BootCompletedAction {
          param($serial)
          $probe = Invoke-RimsExternalCommand `
            -FilePath $adb `
            -Arguments @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed') `
            -TimeoutSeconds 15
          return $probe.ExitCode -eq 0 -and $probe.StandardOutput.Trim() -eq '1'
        }
      $verification.healthy -and $(if ($owned) {
          Test-RimsNestedOwnedProcess -State $State -PropertyName 'emulator'
        } else {
          $true
        })
    } catch {
      $false
    }
  }
  return [pscustomobject][ordered]@{
    name = 'emulator'
    ok = $running
    required = $true
    detail = if ($cleanupPending) {
      'Android emulator cleanup remains pending.'
    } elseif ($owned) {
      'Controller-owned Android emulator identity is present.'
    } else {
      if ($null -eq $verification) {
        'Pre-existing Android device could not be verified through adb.'
      } else {
        $verification.detail
      }
    }
    remediation = if ($running) { '' } elseif ($cleanupPending) {
      'Run down with the same parameters to retry exact emulator cleanup.'
    } elseif ($owned) {
      'Run down to reconcile exact emulator ownership.'
    } else {
      'Reconnect the recorded AVD or use a matching AndroidDevice; down will leave it user-managed.'
    }
    owned = $owned
    serial = Get-RimsObjectPropertyValue -Value $emulator -Name 'serial'
    avdName = Get-RimsObjectPropertyValue -Value $emulator -Name 'avdName'
    windowsPid = Get-RimsObjectPropertyValue -Value $emulator -Name 'windowsPid'
  }
}
