$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RimsLocalTimestamp {
  return [DateTime]::UtcNow.ToString(
    'o',
    [Globalization.CultureInfo]::InvariantCulture
  )
}

function New-RimsLocalResult {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command
  )

  return [pscustomobject][ordered]@{
    schemaVersion = 1
    command = $Command
    ok = $false
    exitCode = 1
    startedAt = Get-RimsLocalTimestamp
    finishedAt = $null
    components = @()
    errors = @()
  }
}

function Complete-RimsLocalResult {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result,
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [int]$ExitCode
  )

  $Result.ok = $Ok
  $Result.exitCode = $ExitCode
  $Result.finishedAt = Get-RimsLocalTimestamp
  return $Result
}

function Write-RimsLocalJson {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  $json = $Result | ConvertTo-Json -Depth 10 -Compress
  [Console]::Out.WriteLine($json)
}

function New-RimsLocalComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [bool]$Required,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Detail,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation
  )

  return [pscustomobject][ordered]@{
    name = $Name
    ok = $Ok
    required = $Required
    detail = $Detail
    remediation = $Remediation
  }
}

function Resolve-RimsCommandPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $command = Get-Command -Name $Name -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandType -in @('Application', 'ExternalScript')
    } |
    Select-Object -First 1
  if ($null -eq $command) {
    return $null
  }
  return $command.Source
}

function Invoke-RimsExternalCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Arguments
  )

  try {
    $captured = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output = ($captured | ForEach-Object { [string]$_ }) -join `
      [Environment]::NewLine
    return [pscustomobject]@{
      ExitCode = $exitCode
      Output = $output.Trim()
    }
  } catch {
    return [pscustomobject]@{
      ExitCode = -1
      Output = $_.Exception.Message
    }
  }
}

function Get-RimsFirstOutputLine {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Output
  )

  $line = $Output -split '\r?\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_.Length -gt 0 } |
    Select-Object -First 1
  if ($null -eq $line) {
    return 'No output returned.'
  }
  return $line
}

function Resolve-RimsBackendDirectory {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir
  )

  $candidate = $BackendDir
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = 'E:\My Work\RIMS\rims-goProgect'
  }
  return [IO.Path]::GetFullPath($candidate)
}

function Test-RimsWorkspaceEnvironmentPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return (
    (Test-Path -LiteralPath (Join-Path $Path '.env') -PathType Leaf) -and
    (Test-Path `
      -LiteralPath (Join-Path $Path 'deploy\docker-compose.yml') `
      -PathType Leaf)
  )
}

function Resolve-RimsBackendWorkspaceRoot {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$BackendDir
  )

  if (-not [string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
    return [IO.Path]::GetFullPath($BackendWorkspaceRoot)
  }

  $current = New-Object IO.DirectoryInfo -ArgumentList `
    ([IO.Path]::GetFullPath($BackendDir))
  while ($null -ne $current) {
    if (Test-RimsWorkspaceEnvironmentPath -Path $current.FullName) {
      return $current.FullName
    }
    $current = $current.Parent
  }

  $defaultRoot = 'E:\My Work\RIMS'
  if (Test-RimsWorkspaceEnvironmentPath -Path $defaultRoot) {
    return [IO.Path]::GetFullPath($defaultRoot)
  }
  return $null
}

function ConvertTo-RimsWslPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WindowsPath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  $wslPath = $WslExecutable
  if ([string]::IsNullOrWhiteSpace($wslPath)) {
    $wslPath = Resolve-RimsCommandPath -Name 'wsl.exe'
  }
  if ([string]::IsNullOrWhiteSpace($wslPath)) {
    throw 'wsl.exe is not available for path conversion.'
  }

  $conversion = Invoke-RimsExternalCommand `
    -FilePath $wslPath `
    -Arguments @('-e', 'wslpath', '-a', '--', $WindowsPath)
  if ($conversion.ExitCode -ne 0 -or
      [string]::IsNullOrWhiteSpace($conversion.Output)) {
    throw "wslpath failed for '$WindowsPath': $($conversion.Output)"
  }
  return Get-RimsFirstOutputLine -Output $conversion.Output
}

function Get-RimsWslPathSuffix {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WindowsPath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  if ([string]::IsNullOrWhiteSpace($WslExecutable)) {
    return ''
  }
  try {
    $convertedPath = ConvertTo-RimsWslPath `
      -WindowsPath $WindowsPath `
      -WslExecutable $WslExecutable
    return "; WSL path: $convertedPath"
  } catch {
    return ''
  }
}

function Test-RimsPowerShellComponent {
  $version = $PSVersionTable.PSVersion
  $edition = if ($PSVersionTable.ContainsKey('PSEdition')) {
    $PSVersionTable.PSEdition
  } else {
    'Desktop'
  }
  $ok = $edition -eq 'Desktop' -and $version -ge [version]'5.1'
  $remediation = if ($ok) {
    ''
  } else {
    'Run this script with Windows PowerShell 5.1 (powershell.exe).'
  }
  return New-RimsLocalComponent `
    -Name 'powershell' `
    -Ok $ok `
    -Required $true `
    -Detail "Edition $edition, version $version." `
    -Remediation $remediation
}

function Test-RimsWslComponent {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  if ([string]::IsNullOrWhiteSpace($WslExecutable)) {
    return New-RimsLocalComponent `
      -Name 'wsl' `
      -Ok $false `
      -Required $true `
      -Detail 'wsl.exe was not found.' `
      -Remediation 'Install WSL and ensure wsl.exe is available on PATH.'
  }

  $check = Invoke-RimsExternalCommand `
    -FilePath $WslExecutable `
    -Arguments @('-e', 'bash', '-lc', 'printf RIMS_WSL_OK')
  $ok = $check.ExitCode -eq 0 -and $check.Output.Contains('RIMS_WSL_OK')
  $detail = if ($ok) {
    "bash is available through $WslExecutable."
  } else {
    "wsl.exe could not run bash: $($check.Output)"
  }
  $remediation = if ($ok) {
    ''
  } else {
    'Install or repair a default WSL distribution with bash available.'
  }
  return New-RimsLocalComponent `
    -Name 'wsl' `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $remediation
}

function Test-RimsVersionedCommandComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [Parameter(Mandatory = $true)]
    [string]$MissingRemediation
  )

  if ([string]::IsNullOrWhiteSpace($FilePath)) {
    return New-RimsLocalComponent `
      -Name $Name `
      -Ok $false `
      -Required $true `
      -Detail "$Name command was not found." `
      -Remediation $MissingRemediation
  }

  $check = Invoke-RimsExternalCommand -FilePath $FilePath -Arguments $Arguments
  $ok = $check.ExitCode -eq 0
  $detail = if ($ok) {
    "$(Get-RimsFirstOutputLine -Output $check.Output) Path: $FilePath"
  } else {
    "$Name command failed: $($check.Output)"
  }
  $remediation = if ($ok) { '' } else { $MissingRemediation }
  return New-RimsLocalComponent `
    -Name $Name `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $remediation
}

function Test-RimsFrontendWorkspaceComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $ScriptDirectory))
  $flutterRoot = Join-Path $repositoryRoot 'rims_frontend'
  $ok = (
    (Test-Path -LiteralPath $repositoryRoot -PathType Container) -and
    (Test-Path -LiteralPath $flutterRoot -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $flutterRoot 'pubspec.yaml') -PathType Leaf)
  )
  $remediation = if ($ok) {
    ''
  } else {
    'Run the CLI from a RIMS frontend checkout containing rims_frontend/pubspec.yaml.'
  }
  return New-RimsLocalComponent `
    -Name 'frontendWorkspace' `
    -Ok $ok `
    -Required $true `
    -Detail "Repository: $repositoryRoot; Flutter workspace: $flutterRoot." `
    -Remediation $remediation
}

function Test-RimsBackendWorkspaceComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  $exists = Test-Path -LiteralPath $BackendDir -PathType Container
  $goModule = Join-Path $BackendDir 'go.mod'
  $ok = $exists -and (Test-Path -LiteralPath $goModule -PathType Leaf)
  $suffix = Get-RimsWslPathSuffix `
    -WindowsPath $BackendDir `
    -WslExecutable $WslExecutable
  $detail = if (-not $exists) {
    "Backend source: $BackendDir$suffix; directory does not exist."
  } elseif (-not $ok) {
    "Backend source: $BackendDir$suffix; go.mod is missing."
  } else {
    "Backend source: $BackendDir$suffix; go.mod found."
  }
  $remediation = if ($ok) {
    ''
  } else {
    'Set -BackendDir or RIMS_BACKEND_DIR to the rims-goProgect source directory.'
  }
  return New-RimsLocalComponent `
    -Name 'backendWorkspace' `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $remediation
}

function Test-RimsWorkspaceEnvComponent {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  if ([string]::IsNullOrWhiteSpace($BackendWorkspaceRoot)) {
    return New-RimsLocalComponent `
      -Name 'workspaceEnv' `
      -Ok $false `
      -Required $true `
      -Detail 'Backend runtime root could not be resolved.' `
      -Remediation 'Set -BackendWorkspaceRoot or RIMS_BACKEND_WORKSPACE_ROOT to a directory containing .env and deploy/docker-compose.yml.'
  }

  $exists = Test-Path -LiteralPath $BackendWorkspaceRoot -PathType Container
  $envPath = Join-Path $BackendWorkspaceRoot '.env'
  $composePath = Join-Path $BackendWorkspaceRoot 'deploy\docker-compose.yml'
  $hasEnv = Test-Path -LiteralPath $envPath -PathType Leaf
  $hasCompose = Test-Path -LiteralPath $composePath -PathType Leaf
  $ok = $exists -and $hasEnv -and $hasCompose
  $suffix = Get-RimsWslPathSuffix `
    -WindowsPath $BackendWorkspaceRoot `
    -WslExecutable $WslExecutable
  $missing = @()
  if (-not $exists) { $missing += 'directory' }
  if (-not $hasEnv) { $missing += '.env' }
  if (-not $hasCompose) { $missing += 'deploy/docker-compose.yml' }
  $detail = "Backend runtime root: $BackendWorkspaceRoot$suffix"
  if ($ok) {
    $detail += '; .env and Compose file found.'
  } else {
    $detail += "; missing: $($missing -join ', ')."
  }
  $remediation = if ($ok) {
    ''
  } else {
    'Set -BackendWorkspaceRoot or RIMS_BACKEND_WORKSPACE_ROOT to a directory containing .env and deploy/docker-compose.yml.'
  }
  return New-RimsLocalComponent `
    -Name 'workspaceEnv' `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $remediation
}

function Test-RimsWslCommandComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable,
    [Parameter(Mandatory = $true)]
    [string]$BashCommand,
    [Parameter(Mandatory = $true)]
    [string]$Remediation
  )

  if ([string]::IsNullOrWhiteSpace($WslExecutable)) {
    return New-RimsLocalComponent `
      -Name $Name `
      -Ok $false `
      -Required $true `
      -Detail "$Name could not be checked because wsl.exe was not found." `
      -Remediation $Remediation
  }

  $check = Invoke-RimsExternalCommand `
    -FilePath $WslExecutable `
    -Arguments @('-e', 'bash', '-lc', $BashCommand)
  $ok = $check.ExitCode -eq 0
  $detail = if ($ok) {
    Get-RimsFirstOutputLine -Output $check.Output
  } else {
    "$Name check failed through WSL: $($check.Output)"
  }
  return New-RimsLocalComponent `
    -Name $Name `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $(if ($ok) { '' } else { $Remediation })
}

function Test-RimsWebDeviceComponent {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FlutterExecutable,
    [Parameter(Mandatory = $true)]
    [bool]$Required
  )

  if ([string]::IsNullOrWhiteSpace($FlutterExecutable)) {
    return New-RimsLocalComponent `
      -Name 'webDevice' `
      -Ok $false `
      -Required $Required `
      -Detail 'Flutter is unavailable, so Web devices could not be queried.' `
      -Remediation 'Install Flutter and enable at least one Web browser device.'
  }

  $check = Invoke-RimsExternalCommand `
    -FilePath $FlutterExecutable `
    -Arguments @('devices', '--machine')
  $devices = @()
  $parseError = $null
  if ($check.ExitCode -eq 0) {
    try {
      $parsedDevices = $check.Output | ConvertFrom-Json -ErrorAction Stop
      $devices = @($parsedDevices | ForEach-Object { $_ })
    } catch {
      $parseError = $_.Exception.Message
    }
  }
  $webDevices = @($devices | Where-Object {
      $_.targetPlatform -eq 'web-javascript'
    })
  $ok = $check.ExitCode -eq 0 -and $null -eq $parseError -and
    $webDevices.Count -gt 0
  if ($ok) {
    $deviceIds = @($webDevices | ForEach-Object { $_.id })
    $detail = "Web devices: $($deviceIds -join ', ')."
  } elseif ($null -ne $parseError) {
    $detail = "Could not parse flutter devices --machine: $parseError"
  } else {
    $detail = "No web-javascript Flutter device was found. $($check.Output)".Trim()
  }
  return New-RimsLocalComponent `
    -Name 'webDevice' `
    -Ok $ok `
    -Required $Required `
    -Detail $detail `
    -Remediation $(if ($ok) { '' } else {
        'Install or enable Chrome/Edge and run flutter config --enable-web.'
      })
}

function Get-RimsAndroidSdkRoots {
  $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk'
  }
  $seen = @{}
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    $fullPath = [IO.Path]::GetFullPath($candidate)
    if (-not $seen.ContainsKey($fullPath)) {
      $seen[$fullPath] = $true
      $fullPath
    }
  }
}

function Resolve-RimsAndroidTool {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName,
    [Parameter(Mandatory = $true)]
    [string]$SdkRelativePath
  )

  $fromPath = Resolve-RimsCommandPath -Name $CommandName
  if (-not [string]::IsNullOrWhiteSpace($fromPath)) {
    return $fromPath
  }
  foreach ($sdkRoot in @(Get-RimsAndroidSdkRoots)) {
    $candidate = Join-Path $sdkRoot $SdkRelativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return $null
}

function Get-RimsOnlineAndroidDevices {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AdbExecutable
  )

  if ([string]::IsNullOrWhiteSpace($AdbExecutable)) {
    return
  }
  $check = Invoke-RimsExternalCommand `
    -FilePath $AdbExecutable `
    -Arguments @('devices')
  if ($check.ExitCode -ne 0) {
    return
  }
  foreach ($line in ($check.Output -split '\r?\n')) {
    if ($line -match '^([^\s]+)\s+device$') {
      $Matches[1]
    }
  }
}

function Get-RimsInstalledAndroidAvds {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$EmulatorExecutable
  )

  if ([string]::IsNullOrWhiteSpace($EmulatorExecutable)) {
    return
  }
  $check = Invoke-RimsExternalCommand `
    -FilePath $EmulatorExecutable `
    -Arguments @('-list-avds')
  if ($check.ExitCode -ne 0) {
    return
  }
  foreach ($line in ($check.Output -split '\r?\n')) {
    $avd = $line.Trim()
    if ($avd.Length -gt 0 -and $avd -notmatch '^(INFO|WARNING|ERROR)\s') {
      $avd
    }
  }
}

function Test-RimsAndroidToolComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [Parameter(Mandatory = $true)]
    [string]$Remediation
  )

  if ([string]::IsNullOrWhiteSpace($FilePath)) {
    return New-RimsLocalComponent `
      -Name $Name `
      -Ok $false `
      -Required $true `
      -Detail "$Name executable was not found in PATH or an Android SDK root." `
      -Remediation $Remediation
  }
  $check = Invoke-RimsExternalCommand -FilePath $FilePath -Arguments $Arguments
  $ok = $check.ExitCode -eq 0
  $detail = if ($ok) {
    "Path: $FilePath. $(Get-RimsFirstOutputLine -Output $check.Output)"
  } else {
    "$name failed: $($check.Output)"
  }
  return New-RimsLocalComponent `
    -Name $Name `
    -Ok $ok `
    -Required $true `
    -Detail $detail `
    -Remediation $(if ($ok) { '' } else { $Remediation })
}

function Test-RimsAndroidDeviceComponent {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$OnlineDevices,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$InstalledAvds
  )

  $choices = @($OnlineDevices + $InstalledAvds | Select-Object -Unique)
  $choiceDetail = if ($choices.Count -gt 0) {
    $choices -join ', '
  } else {
    '(none)'
  }
  $remediation = 'Pass -AndroidDevice <id> using an online adb device id or installed AVD id.'

  if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
    return New-RimsLocalComponent `
      -Name 'androidDevice' `
      -Ok $false `
      -Required $true `
      -Detail "No Android device was requested. Available choices: $choiceDetail." `
      -Remediation $remediation
  }
  if ($OnlineDevices -contains $AndroidDevice) {
    return New-RimsLocalComponent `
      -Name 'androidDevice' `
      -Ok $true `
      -Required $true `
      -Detail "Requested Android device '$AndroidDevice' is online. Available choices: $choiceDetail." `
      -Remediation ''
  }
  if ($InstalledAvds -contains $AndroidDevice) {
    return New-RimsLocalComponent `
      -Name 'androidDevice' `
      -Ok $true `
      -Required $true `
      -Detail "Requested Android AVD '$AndroidDevice' is installed. Available choices: $choiceDetail." `
      -Remediation ''
  }
  return New-RimsLocalComponent `
    -Name 'androidDevice' `
    -Ok $false `
    -Required $true `
    -Detail "Requested Android device '$AndroidDevice' was not found. Available choices: $choiceDetail." `
    -Remediation $remediation
}

function Invoke-RimsLocalDoctor {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $resolvedBackendDir = Resolve-RimsBackendDirectory -BackendDir $BackendDir
  $resolvedWorkspaceRoot = Resolve-RimsBackendWorkspaceRoot `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -BackendDir $resolvedBackendDir
  $wslExecutable = Resolve-RimsCommandPath -Name 'wsl.exe'
  $gitExecutable = Resolve-RimsCommandPath -Name 'git.exe'
  if ([string]::IsNullOrWhiteSpace($gitExecutable)) {
    $gitExecutable = Resolve-RimsCommandPath -Name 'git'
  }
  $flutterExecutable = Resolve-RimsCommandPath -Name 'flutter.bat'
  if ([string]::IsNullOrWhiteSpace($flutterExecutable)) {
    $flutterExecutable = Resolve-RimsCommandPath -Name 'flutter'
  }

  $components = New-Object Collections.Generic.List[object]
  [void]$components.Add((Test-RimsPowerShellComponent))
  [void]$components.Add((Test-RimsWslComponent -WslExecutable $wslExecutable))
  [void]$components.Add((Test-RimsVersionedCommandComponent `
        -Name 'git' `
        -FilePath $gitExecutable `
        -Arguments @('--version') `
        -MissingRemediation 'Install Git for Windows and add git.exe to PATH.'))
  [void]$components.Add((Test-RimsVersionedCommandComponent `
        -Name 'flutter' `
        -FilePath $flutterExecutable `
        -Arguments @('--version') `
        -MissingRemediation 'Install Flutter and add its bin directory to PATH.'))
  [void]$components.Add((Test-RimsFrontendWorkspaceComponent `
        -ScriptDirectory $ScriptDirectory))
  [void]$components.Add((Test-RimsBackendWorkspaceComponent `
        -BackendDir $resolvedBackendDir `
        -WslExecutable $wslExecutable))
  [void]$components.Add((Test-RimsWorkspaceEnvComponent `
        -BackendWorkspaceRoot $resolvedWorkspaceRoot `
        -WslExecutable $wslExecutable))
  [void]$components.Add((Test-RimsWslCommandComponent `
        -Name 'go' `
        -WslExecutable $wslExecutable `
        -BashCommand 'test -x ~/local/go/bin/go && ~/local/go/bin/go version' `
        -Remediation 'Install Go at ~/local/go/bin/go inside the default WSL distribution.'))
  [void]$components.Add((Test-RimsWslCommandComponent `
        -Name 'docker' `
        -WslExecutable $wslExecutable `
        -BashCommand "docker version --format '{{.Server.Version}}'" `
        -Remediation 'Start Docker Desktop with WSL integration and verify docker can reach the daemon.'))
  [void]$components.Add((Test-RimsWslCommandComponent `
        -Name 'dockerCompose' `
        -WslExecutable $wslExecutable `
        -BashCommand 'docker compose version' `
        -Remediation 'Install the Docker Compose plugin in WSL or repair Docker Desktop integration.'))
  [void]$components.Add((Test-RimsWebDeviceComponent `
        -FlutterExecutable $flutterExecutable `
        -Required ($Target -in @('web', 'android'))))

  if ($Target -eq 'android') {
    $adbExecutable = Resolve-RimsAndroidTool `
      -CommandName 'adb.exe' `
      -SdkRelativePath 'platform-tools\adb.exe'
    $emulatorExecutable = Resolve-RimsAndroidTool `
      -CommandName 'emulator.exe' `
      -SdkRelativePath 'emulator\emulator.exe'
    [void]$components.Add((Test-RimsAndroidToolComponent `
          -Name 'adb' `
          -FilePath $adbExecutable `
          -Arguments @('version') `
          -Remediation 'Install Android SDK Platform-Tools and set ANDROID_SDK_ROOT or ANDROID_HOME.'))
    [void]$components.Add((Test-RimsAndroidToolComponent `
          -Name 'emulator' `
          -FilePath $emulatorExecutable `
          -Arguments @('-list-avds') `
          -Remediation 'Install the Android Emulator package and set ANDROID_SDK_ROOT or ANDROID_HOME.'))
    $onlineDevices = @(Get-RimsOnlineAndroidDevices `
        -AdbExecutable $adbExecutable)
    $installedAvds = @(Get-RimsInstalledAndroidAvds `
        -EmulatorExecutable $emulatorExecutable)
    [void]$components.Add((Test-RimsAndroidDeviceComponent `
          -AndroidDevice $AndroidDevice `
          -OnlineDevices $onlineDevices `
          -InstalledAvds $installedAvds))
  }

  return $components.ToArray()
}

function Write-RimsDoctorText {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  foreach ($component in @($Result.components)) {
    $status = if ($component.ok) {
      'PASS'
    } elseif ($component.required) {
      'FAIL'
    } else {
      'SKIP'
    }
    [Console]::Out.WriteLine("[$status] $($component.name) - $($component.detail)")
    if (-not $component.ok -and
        -not [string]::IsNullOrWhiteSpace($component.remediation)) {
      [Console]::Out.WriteLine("       Remediation: $($component.remediation)")
    }
  }
  foreach ($errorMessage in @($Result.errors)) {
    [Console]::Out.WriteLine("[FAIL] doctor - $errorMessage")
  }
}
