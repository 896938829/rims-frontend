function Test-RimsPowerShellComponent {
  $version = $PSVersionTable.PSVersion
  $edition = if ($PSVersionTable.ContainsKey('PSEdition')) {
    $PSVersionTable.PSEdition
  } else {
    'Desktop'
  }
  $runsOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
  $ok = $runsOnWindows -and (
    ($edition -eq 'Desktop' -and $version -ge [version]'5.1') -or
    ($edition -eq 'Core' -and $version -ge [version]'7.0')
  )
  $remediation = if ($ok) {
    ''
  } else {
    'Run this script on Windows with Windows PowerShell 5.1+ or PowerShell 7+.'
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
  $ok = $check.ExitCode -eq 0 -and
    $check.StandardOutput.Contains('RIMS_WSL_OK')
  $detail = if ($ok) {
    "bash is available through $WslExecutable."
  } else {
    "wsl.exe could not run bash: $(Get-RimsExternalCommandSummary -Result $check)"
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
  $summary = Get-RimsExternalCommandSummary -Result $check
  $detail = if ($ok) {
    "$summary Path: $FilePath"
  } else {
    "$Name command failed: $summary"
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
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$PathError,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  if (-not [string]::IsNullOrWhiteSpace($PathError)) {
    return New-RimsLocalComponent `
      -Name 'backendWorkspace' `
      -Ok $false `
      -Required $true `
      -Detail "Backend source path is invalid: $PathError" `
      -Remediation 'Set -BackendDir or RIMS_BACKEND_DIR to a valid rims-goProgect source path.'
  }
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
    [string]$PathError,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$WslExecutable
  )

  if (-not [string]::IsNullOrWhiteSpace($PathError)) {
    return New-RimsLocalComponent `
      -Name 'workspaceEnv' `
      -Ok $false `
      -Required $true `
      -Detail "Backend runtime root path is invalid: $PathError" `
      -Remediation 'Set -BackendWorkspaceRoot or RIMS_BACKEND_WORKSPACE_ROOT to a valid runtime workspace path.'
  }
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
  $summary = Get-RimsExternalCommandSummary -Result $check
  $detail = if ($ok) {
    $summary
  } else {
    "$Name check failed through WSL: $summary"
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
    [bool]$Required,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$RequiredDeviceId,
    [AllowNull()]
    [scriptblock]$DeviceQueryAction
  )

  if ([string]::IsNullOrWhiteSpace($FlutterExecutable)) {
    return New-RimsLocalComponent `
      -Name 'webDevice' `
      -Ok $false `
      -Required $Required `
      -Detail 'Flutter is unavailable, so Web devices could not be queried.' `
      -Remediation 'Install Flutter and enable at least one Web browser device.'
  }

  $check = if ($null -eq $DeviceQueryAction) {
    Invoke-RimsExternalCommand `
      -FilePath $FlutterExecutable `
      -Arguments @('devices', '--machine')
  } else {
    & $DeviceQueryAction $FlutterExecutable
  }
  $devices = @()
  $parseError = $null
  if ($check.ExitCode -eq 0) {
    try {
      $parsedDevices = $check.StandardOutput |
        ConvertFrom-Json -ErrorAction Stop
      $devices = @($parsedDevices | ForEach-Object { $_ })
    } catch {
      $parseError = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  $webDevices = @($devices | Where-Object {
      $_.targetPlatform -eq 'web-javascript'
    })
  $matchingDevices = if ([string]::IsNullOrWhiteSpace($RequiredDeviceId)) {
    $webDevices
  } else {
    @($webDevices | Where-Object { [string]$_.id -ceq $RequiredDeviceId })
  }
  $ok = $check.ExitCode -eq 0 -and $null -eq $parseError -and
    @($matchingDevices).Count -gt 0
  if ($ok) {
    $deviceIds = @($webDevices | ForEach-Object { $_.id })
    $detail = "Web devices: $($deviceIds -join ', ')."
  } elseif ($null -ne $parseError) {
    $detail = "Could not parse flutter devices --machine: $parseError"
  } else {
    $summary = Get-RimsExternalCommandSummary -Result $check
    $detail = if ([string]::IsNullOrWhiteSpace($RequiredDeviceId)) {
      "No web-javascript Flutter device was found. $summary".Trim()
    } else {
      "Required Flutter Web device ID '$RequiredDeviceId' was not found. $summary".Trim()
    }
  }
  return New-RimsLocalComponent `
    -Name 'webDevice' `
    -Ok $ok `
    -Required $Required `
    -Detail $detail `
    -Remediation $(if ($ok) { '' } else {
        if ([string]::IsNullOrWhiteSpace($RequiredDeviceId)) {
          'Install or enable Chrome/Edge and run flutter config --enable-web.'
        } else {
          "Install or enable the Flutter Web device '$RequiredDeviceId' and run flutter config --enable-web."
        }
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
    $resolution = Resolve-RimsNormalizedPath -Path $candidate
    if ($resolution.success -and -not $seen.ContainsKey($resolution.path)) {
      $seen[$resolution.path] = $true
      $resolution.path
    }
  }
}

function Resolve-RimsAndroidToolState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName,
    [Parameter(Mandatory = $true)]
    [string]$SdkRelativePath
  )

  $fromPath = Resolve-RimsCommandPath -Name $CommandName
  if (-not [string]::IsNullOrWhiteSpace($fromPath)) {
    return Resolve-RimsNormalizedPath -Path $fromPath
  }

  $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $sdkRoots += Join-Path $env:LOCALAPPDATA 'Android\Sdk'
  }
  foreach ($sdkRoot in $sdkRoots) {
    if ([string]::IsNullOrWhiteSpace($sdkRoot)) {
      continue
    }
    $rootResolution = Resolve-RimsNormalizedPath -Path $sdkRoot
    if (-not $rootResolution.success) {
      return [pscustomobject][ordered]@{
        success = $false
        path = $null
        error = "Android SDK root is invalid: $($rootResolution.error)"
      }
    }
    try {
      $candidate = Join-Path $rootResolution.path $SdkRelativePath
    } catch {
      $summary = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      return [pscustomobject][ordered]@{
        success = $false
        path = $null
        error = "Android tool path is invalid: $summary"
      }
    }
    $candidateResolution = Resolve-RimsNormalizedPath -Path $candidate
    if (-not $candidateResolution.success) {
      return [pscustomobject][ordered]@{
        success = $false
        path = $null
        error = "Android tool path is invalid: $($candidateResolution.error)"
      }
    }
    if (Test-Path -LiteralPath $candidateResolution.path -PathType Leaf) {
      return $candidateResolution
    }
  }
  return [pscustomobject][ordered]@{
    success = $false
    path = $null
    error = "$CommandName was not found in PATH or an Android SDK root."
  }
}

function Resolve-RimsAndroidTool {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName,
    [Parameter(Mandatory = $true)]
    [string]$SdkRelativePath
  )

  $resolution = Resolve-RimsAndroidToolState `
    -CommandName $CommandName `
    -SdkRelativePath $SdkRelativePath
  return $resolution.path
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
  foreach ($line in ($check.StandardOutput -split '\r?\n')) {
    if ($line -match '^([^\s]+)\s+device$') {
      $Matches[1]
    }
  }
}

function ConvertFrom-RimsAndroidAvdOutput {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$StandardOutput,
    [Parameter(Mandatory = $true)]
    [int]$ExitCode
  )

  if ($ExitCode -ne 0) {
    return
  }
  foreach ($line in ($StandardOutput -split '\r?\n')) {
    $avd = $line.Trim()
    if ($avd.Length -eq 0) {
      continue
    }
    if ($avd -match '^(?:\[(?:INFO|WARNING|ERROR)\]|(?:INFO|WARNING|ERROR)(?:\s|:|$))') {
      continue
    }
    $avd
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
  ConvertFrom-RimsAndroidAvdOutput `
    -StandardOutput $check.StandardOutput `
    -ExitCode $check.ExitCode
}

function Test-RimsAndroidToolComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FilePath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$PathError,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [Parameter(Mandatory = $true)]
    [string]$Remediation
  )

  if ([string]::IsNullOrWhiteSpace($FilePath)) {
    $detail = if ([string]::IsNullOrWhiteSpace($PathError)) {
      "$Name executable was not found in PATH or an Android SDK root."
    } else {
      $PathError
    }
    return New-RimsLocalComponent `
      -Name $Name `
      -Ok $false `
      -Required $true `
      -Detail $detail `
      -Remediation $Remediation
  }
  $check = Invoke-RimsExternalCommand -FilePath $FilePath -Arguments $Arguments
  $ok = $check.ExitCode -eq 0
  $summary = Get-RimsExternalCommandSummary -Result $check
  $detail = if ($ok) {
    "Path: $FilePath. $summary"
  } else {
    "$name failed: $summary"
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

  $choices = @($InstalledAvds | Select-Object -Unique)
  $choiceDetail = if ($choices.Count -gt 0) {
    $choices -join ', '
  } else {
    '(none)'
  }
  $remediation = 'Pass -AndroidDevice <avd-name> using an installed Android AVD name.'

  if ([string]::IsNullOrWhiteSpace($AndroidDevice)) {
    return New-RimsLocalComponent `
      -Name 'androidDevice' `
      -Ok $false `
      -Required $true `
      -Detail "No Android device was requested. Available choices: $choiceDetail." `
      -Remediation $remediation
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
    -Detail "Requested Android AVD '$AndroidDevice' was not found. Available choices: $choiceDetail." `
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
    [string]$ScriptDirectory,
    [switch]$UseLocalTls
  )

  $backendPathState = Resolve-RimsBackendDirectoryState `
    -BackendDir $BackendDir
  $workspacePathState = Resolve-RimsBackendWorkspaceRootState `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -BackendDir $(if ($backendPathState.success) {
        $backendPathState.path
      } else {
        $BackendDir
      })
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
        -BackendDir $backendPathState.path `
        -PathError $backendPathState.error `
        -WslExecutable $wslExecutable))
  [void]$components.Add((Test-RimsWorkspaceEnvComponent `
        -BackendWorkspaceRoot $workspacePathState.path `
        -PathError $workspacePathState.error `
        -WslExecutable $wslExecutable))
  [void]$components.Add((Test-RimsWslCommandComponent `
        -Name 'go' `
        -WslExecutable $wslExecutable `
        -BashCommand 'test -x ~/local/go/bin/go && ~/local/go/bin/go version' `
        -Remediation 'Install Go at ~/local/go/bin/go inside the default WSL distribution.'))
  if ($UseLocalTls) {
    [void]$components.Add((Test-RimsWslCommandComponent `
          -Name 'openssl' `
          -WslExecutable $wslExecutable `
          -BashCommand 'openssl version' `
          -Remediation 'Install OpenSSL in the default WSL distribution.'))
  }
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
  $requiredWebDeviceId = if ($UseLocalTls -and $Target -eq 'web') { 'chrome' } else { '' }
  [void]$components.Add((Test-RimsWebDeviceComponent `
        -FlutterExecutable $flutterExecutable `
        -Required ($Target -in @('web', 'android')) `
        -RequiredDeviceId $requiredWebDeviceId))

  if ($Target -eq 'android') {
    $adbPathState = Resolve-RimsAndroidToolState `
      -CommandName 'adb.exe' `
      -SdkRelativePath 'platform-tools\adb.exe'
    $emulatorPathState = Resolve-RimsAndroidToolState `
      -CommandName 'emulator.exe' `
      -SdkRelativePath 'emulator\emulator.exe'
    [void]$components.Add((Test-RimsAndroidToolComponent `
          -Name 'adb' `
          -FilePath $adbPathState.path `
          -PathError $adbPathState.error `
          -Arguments @('version') `
          -Remediation 'Install Android SDK Platform-Tools and set ANDROID_SDK_ROOT or ANDROID_HOME.'))
    [void]$components.Add((Test-RimsAndroidToolComponent `
          -Name 'emulator' `
          -FilePath $emulatorPathState.path `
          -PathError $emulatorPathState.error `
          -Arguments @('-list-avds') `
          -Remediation 'Install the Android Emulator package and set ANDROID_SDK_ROOT or ANDROID_HOME.'))
    $onlineDevices = @(Get-RimsOnlineAndroidDevices `
        -AdbExecutable $adbPathState.path)
    $installedAvds = @(Get-RimsInstalledAndroidAvds `
        -EmulatorExecutable $emulatorPathState.path)
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
