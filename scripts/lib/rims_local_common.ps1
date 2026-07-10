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

function ConvertTo-RimsWindowsCommandLineArgument {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
    return $Value
  }

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

function Receive-RimsAsyncText {
  param(
    [AllowNull()]
    [object]$Task,
    [int]$TimeoutMilliseconds = 3000
  )

  if ($null -eq $Task) {
    return ''
  }
  try {
    if ($Task.Wait($TimeoutMilliseconds)) {
      return [string]$Task.Result
    }
  } catch {
    return ''
  }
  return ''
}

function Stop-RimsProcessTree {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process
  )

  try {
    if ($Process.HasExited) {
      return
    }
  } catch {
    return
  }

  $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if (Test-Path -LiteralPath $taskkillPath -PathType Leaf) {
    $taskkill = $null
    try {
      $taskkillArguments = @(
        '/PID',
        [string]$Process.Id,
        '/T',
        '/F'
      ) | ForEach-Object {
        ConvertTo-RimsWindowsCommandLineArgument -Value $_
      }
      $taskkillStartInfo = New-Object Diagnostics.ProcessStartInfo
      $taskkillStartInfo.FileName = $taskkillPath
      $taskkillStartInfo.Arguments = $taskkillArguments -join ' '
      $taskkillStartInfo.UseShellExecute = $false
      $taskkillStartInfo.CreateNoWindow = $true
      $taskkillStartInfo.RedirectStandardOutput = $true
      $taskkillStartInfo.RedirectStandardError = $true

      $taskkill = New-Object Diagnostics.Process
      $taskkill.StartInfo = $taskkillStartInfo
      [void]$taskkill.Start()
      $taskkillOutput = $taskkill.StandardOutput.ReadToEndAsync()
      $taskkillError = $taskkill.StandardError.ReadToEndAsync()
      if (-not $taskkill.WaitForExit(5000)) {
        try { $taskkill.Kill() } catch {}
        [void]$taskkill.WaitForExit(1000)
      }
      [void](Receive-RimsAsyncText -Task $taskkillOutput -TimeoutMilliseconds 1000)
      [void](Receive-RimsAsyncText -Task $taskkillError -TimeoutMilliseconds 1000)
    } catch {
      # Fall back to killing the direct process below.
    } finally {
      if ($null -ne $taskkill) {
        $taskkill.Dispose()
      }
    }
  }

  try {
    if (-not $Process.WaitForExit(3000)) {
      $Process.Kill()
      [void]$Process.WaitForExit(2000)
    }
  } catch {
    try { $Process.Kill() } catch {}
  }
}

function Invoke-RimsExternalCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Arguments,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 30
  )

  $process = $null
  $standardOutputTask = $null
  $standardErrorTask = $null
  $processId = $null
  try {
    $quotedArguments = $Arguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value $_
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $processId = $process.Id
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()

    $waitMilliseconds = $TimeoutSeconds * 1000
    $timedOut = -not $process.WaitForExit($waitMilliseconds)
    if ($timedOut) {
      Stop-RimsProcessTree -Process $process
    }

    $standardOutput = Receive-RimsAsyncText `
      -Task $standardOutputTask `
      -TimeoutMilliseconds 3000
    $standardError = Receive-RimsAsyncText `
      -Task $standardErrorTask `
      -TimeoutMilliseconds 3000
    $exitCode = if ($timedOut) {
      124
    } elseif ($process.HasExited) {
      $process.ExitCode
    } else {
      -1
    }
    return [pscustomobject][ordered]@{
      ExitCode = $exitCode
      TimedOut = $timedOut
      ProcessId = $processId
      StandardOutput = $standardOutput
      StandardError = $standardError
    }
  } catch {
    if ($null -ne $process) {
      Stop-RimsProcessTree -Process $process
    }
    return [pscustomobject][ordered]@{
      ExitCode = -1
      TimedOut = $false
      ProcessId = $processId
      StandardOutput = ''
      StandardError = $_.Exception.Message
    }
  } finally {
    if ($null -ne $process) {
      $process.Dispose()
    }
  }
}

function ConvertTo-RimsDiagnosticSummary {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$StandardOutput,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$StandardError,
    [ValidateRange(1, 4096)]
    [int]$MaximumLength = 512
  )

  $line = @($StandardOutput, $StandardError) |
    ForEach-Object { $_ -split '\r?\n' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_.Length -gt 0 } |
    Select-Object -First 1
  if ($null -eq $line) {
    return 'No output returned.'
  }

  $summary = $line -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
  $summary = [regex]::Replace(
    $summary,
    '(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@',
    '$1[REDACTED]@'
  )
  $summary = [regex]::Replace(
    $summary,
    '(?i)\b([a-z0-9_.-]*(?:password|token|secret|authorization|api[_-]?key|(?:access|private|client|secret)[_-]?key|credential(?:s)?)[a-z0-9_.-]*)\s*([=:])\s*(?:(?:bearer|basic)\s+)?(?:"[^"]*"|''[^'']*''|[^,;\s]+)',
    '$1$2[REDACTED]'
  )
  if ($summary.Length -gt $MaximumLength) {
    return $summary.Substring(0, $MaximumLength)
  }
  return $summary
}

function Get-RimsFirstOutputLine {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Output
  )

  return ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $Output `
    -StandardError ''
}

function Get-RimsExternalCommandSummary {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  return ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $Result.StandardOutput `
    -StandardError $Result.StandardError
}

function Resolve-RimsNormalizedPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject][ordered]@{
      success = $false
      path = $null
      error = 'Path is empty.'
    }
  }
  try {
    if ($Path.IndexOf([char]0) -ge 0) {
      throw 'Path contains a NUL character.'
    }
    return [pscustomobject][ordered]@{
      success = $true
      path = [IO.Path]::GetFullPath($Path)
      error = ''
    }
  } catch {
    $summary = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    return [pscustomobject][ordered]@{
      success = $false
      path = $null
      error = $summary
    }
  }
}

function Get-RimsRuntimePaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  $runtimeRoot = $env:RIMS_RUNTIME_DIR
  if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
    $runtimeRoot = Join-Path $repositoryRoot '.runtime\rims-local'
  }
  $rootResolution = Resolve-RimsNormalizedPath -Path $runtimeRoot
  if (-not $rootResolution.success) {
    throw "Runtime root is invalid: $($rootResolution.error)"
  }

  $logDirectory = Join-Path $rootResolution.path 'logs'
  return [pscustomobject][ordered]@{
    root = $rootResolution.path
    state = Join-Path $rootResolution.path 'state.json'
    logs = $logDirectory
    stdoutLog = Join-Path $logDirectory 'backend.stdout.log'
    stderrLog = Join-Path $logDirectory 'backend.stderr.log'
    linuxProcessGroup = Join-Path $rootResolution.path 'backend.pgid'
  }
}

function Initialize-RimsRuntimeDirectories {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  [void][IO.Directory]::CreateDirectory([string]$Paths.root)
  [void][IO.Directory]::CreateDirectory([string]$Paths.logs)
}

function Get-RimsObjectPropertyValue {
  param(
    [AllowNull()]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowNull()]
    [object]$DefaultValue = $null
  )

  if ($null -eq $Value) {
    return $DefaultValue
  }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $DefaultValue
  }
  return $property.Value
}

function Write-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  Initialize-RimsRuntimeDirectories -Paths $Paths
  $temporaryPath = ([string]$Paths.state) + '.tmp'
  $backupPath = ([string]$Paths.state) + '.previous'
  $json = $State | ConvertTo-Json -Depth 10
  try {
    [IO.File]::WriteAllText(
      $temporaryPath,
      $json,
      (New-Object Text.UTF8Encoding($false))
    )
    if (Test-Path -LiteralPath $Paths.state -PathType Leaf) {
      [IO.File]::Replace(
        $temporaryPath,
        [string]$Paths.state,
        $backupPath,
        $true
      )
      [IO.File]::Delete($backupPath)
    } else {
      [IO.File]::Move($temporaryPath, [string]$Paths.state)
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      [IO.File]::Delete($temporaryPath)
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      [IO.File]::Delete($backupPath)
    }
  }
}

function Move-RimsInvalidRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.state -PathType Leaf)) {
    return $null
  }
  for ($offset = 0; $offset -lt 60; $offset++) {
    $timestamp = [DateTime]::UtcNow.AddSeconds($offset).ToString(
      'yyyyMMddTHHmmssZ',
      [Globalization.CultureInfo]::InvariantCulture
    )
    $destination = Join-Path $Paths.root "state.invalid.$timestamp.json"
    if (-not (Test-Path -LiteralPath $destination)) {
      [IO.File]::Move([string]$Paths.state, $destination)
      return $destination
    }
  }
  throw 'Could not allocate a quarantine path for invalid runtime state.'
}

function Read-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.state -PathType Leaf)) {
    return $null
  }
  try {
    $state = [IO.File]::ReadAllText([string]$Paths.state) |
      ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or
        (Get-RimsObjectPropertyValue `
          -Value $state `
          -Name 'schemaVersion') -ne 1) {
      throw 'Unsupported or missing runtime state schemaVersion.'
    }
    return $state
  } catch {
    [void](Move-RimsInvalidRuntimeState -Paths $Paths)
    return $null
  }
}

function Get-RimsOwnedProcess {
  param(
    [AllowNull()]
    [object]$State
  )

  $rawProcessId = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'windowsPid'
  $rawStartTime = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'windowsProcessStartTimeUtc' `
      -DefaultValue '')
  $processId = 0
  if (-not [int]::TryParse([string]$rawProcessId, [ref]$processId) -or
      $processId -le 0 -or
      [string]::IsNullOrWhiteSpace($rawStartTime)) {
    return $null
  }

  $expectedStartTime = [DateTime]::MinValue
  if (-not [DateTime]::TryParse(
      $rawStartTime,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind,
      [ref]$expectedStartTime
    )) {
    return $null
  }

  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $null
  }
  try {
    $actualStartTime = $process.StartTime.ToUniversalTime()
    $expectedUtc = $expectedStartTime.ToUniversalTime()
    if ($actualStartTime.Ticks -ne $expectedUtc.Ticks) {
      $process.Dispose()
      return $null
    }
    return $process
  } catch {
    $process.Dispose()
    return $null
  }
}

function Test-RimsStateOwnsProcess {
  param(
    [AllowNull()]
    [object]$State
  )

  $process = Get-RimsOwnedProcess -State $State
  if ($null -eq $process) {
    return $false
  }
  $process.Dispose()
  return $true
}

function Resolve-RimsBackendDirectoryState {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir
  )

  $candidate = $BackendDir
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = $env:RIMS_BACKEND_DIR
  }
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = 'E:\My Work\RIMS\rims-goProgect'
  }
  return Resolve-RimsNormalizedPath -Path $candidate
}

function Resolve-RimsBackendDirectory {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir
  )

  $resolution = Resolve-RimsBackendDirectoryState -BackendDir $BackendDir
  return $resolution.path
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

function Resolve-RimsBackendWorkspaceRootState {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$BackendDir
  )

  $candidate = $BackendWorkspaceRoot
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = $env:RIMS_BACKEND_WORKSPACE_ROOT
  }
  if (-not [string]::IsNullOrWhiteSpace($candidate)) {
    return Resolve-RimsNormalizedPath -Path $candidate
  }

  $backendResolution = Resolve-RimsNormalizedPath -Path $BackendDir
  if ($backendResolution.success) {
    $current = New-Object IO.DirectoryInfo -ArgumentList `
      $backendResolution.path
    while ($null -ne $current) {
      if (Test-RimsWorkspaceEnvironmentPath -Path $current.FullName) {
        return Resolve-RimsNormalizedPath -Path $current.FullName
      }
      $current = $current.Parent
    }
  }

  return Resolve-RimsNormalizedPath -Path 'E:\My Work\RIMS'
}

function Resolve-RimsBackendWorkspaceRoot {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$BackendDir
  )

  $resolution = Resolve-RimsBackendWorkspaceRootState `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -BackendDir $BackendDir
  return $resolution.path
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
      [string]::IsNullOrWhiteSpace($conversion.StandardOutput)) {
    $summary = Get-RimsExternalCommandSummary -Result $conversion
    throw "wslpath failed for '$WindowsPath': $summary"
  }
  return ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $conversion.StandardOutput `
    -StandardError ''
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
  $ok = $check.ExitCode -eq 0 -and $null -eq $parseError -and
    $webDevices.Count -gt 0
  if ($ok) {
    $deviceIds = @($webDevices | ForEach-Object { $_.id })
    $detail = "Web devices: $($deviceIds -join ', ')."
  } elseif ($null -ne $parseError) {
    $detail = "Could not parse flutter devices --machine: $parseError"
  } else {
    $summary = Get-RimsExternalCommandSummary -Result $check
    $detail = "No web-javascript Flutter device was found. $summary".Trim()
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

function Remove-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  foreach ($path in @(
      [string]$Paths.state,
      ([string]$Paths.state) + '.tmp',
      ([string]$Paths.state) + '.previous',
      [string]$Paths.linuxProcessGroup
    )) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [IO.File]::Delete($path)
    }
  }
}

function Test-RimsTcpPortListening {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [ValidateRange(50, 5000)]
    [int]$TimeoutMilliseconds = 5000
  )

  $client = New-Object Net.Sockets.TcpClient
  try {
    $connectTask = $client.ConnectAsync('127.0.0.1', $Port)
    if (-not $connectTask.Wait($TimeoutMilliseconds)) {
      return $false
    }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Test-RimsHealthEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 2
  )

  try {
    $response = Invoke-WebRequest `
      -Uri $Url `
      -UseBasicParsing `
      -TimeoutSec $TimeoutSeconds `
      -ErrorAction Stop
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
  } catch {
    return $false
  }
}

function Get-RimsSanitizedLogTail {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [ValidateRange(1, 500)]
    [int]$MaximumLines = 80,
    [ValidateRange(1024, 1048576)]
    [int]$MaximumBytes = 65536
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @()
  }
  $lines = New-Object 'Collections.Generic.Queue[string]'
  $stream = $null
  $reader = $null
  try {
    $stream = [IO.FileStream]::new(
      $Path,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    $offset = [Math]::Max(0, $stream.Length - $MaximumBytes)
    if ($offset -gt 0) {
      [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
    }
    $reader = [IO.StreamReader]::new($stream, $true)
    if ($offset -gt 0) {
      [void]$reader.ReadLine()
    }
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      if ($lines.Count -eq $MaximumLines) {
        [void]$lines.Dequeue()
      }
      $sanitized = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput ([string]$line) `
        -StandardError ''
      $lines.Enqueue($sanitized)
    }
  } catch {
    return @('Unable to read log tail safely.')
  } finally {
    if ($null -ne $reader) {
      $reader.Dispose()
      $stream = $null
    }
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
  return @($lines.ToArray())
}

function New-RimsBackendLifecycleComponent {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Detail,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation,
    [Parameter(Mandatory = $true)]
    [bool]$Managed,
    [Parameter(Mandatory = $true)]
    [bool]$Healthy,
    [Parameter(Mandatory = $true)]
    [bool]$Stale,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [AllowNull()]
    [object]$ProcessId = $null,
    [bool]$CleanupPending = $false
  )

  return [pscustomobject][ordered]@{
    name = 'backend'
    ok = $Ok
    required = $true
    detail = $Detail
    remediation = $Remediation
    managed = $Managed
    healthy = $Healthy
    stale = $Stale
    cleanupPending = $CleanupPending
    port = $Port
    windowsPid = $ProcessId
  }
}

function Test-RimsRuntimeCleanupPending {
  param(
    [AllowNull()]
    [object]$State
  )

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  return (
    [bool](Get-RimsObjectPropertyValue `
        -Value $State `
        -Name 'cleanupPending' `
        -DefaultValue $false) -or
    [bool](Get-RimsObjectPropertyValue `
        -Value $dependencyOwnership `
        -Name 'cleanupPending' `
        -DefaultValue $false)
  )
}

function New-RimsRuntimePathsComponent {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  return [pscustomobject][ordered]@{
    name = 'runtimePaths'
    ok = $true
    required = $false
    detail = "State: $($Paths.state); logs: $($Paths.logs)."
    remediation = ''
    runtimeRoot = $Paths.root
    statePath = $Paths.state
    stdoutLogPath = $Paths.stdoutLog
    stderrLogPath = $Paths.stderrLog
  }
}

function New-RimsBackendPortComponent {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Detail,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation
  )

  return [pscustomobject][ordered]@{
    name = 'backendPort'
    ok = $Ok
    required = $true
    detail = $Detail
    remediation = $Remediation
    port = $Port
  }
}

function Get-RimsGitCommit {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $git = Resolve-RimsCommandPath -Name 'git.exe'
  if ([string]::IsNullOrWhiteSpace($git)) {
    $git = Resolve-RimsCommandPath -Name 'git'
  }
  if ([string]::IsNullOrWhiteSpace($git) -or
      -not (Test-Path -LiteralPath $Path -PathType Container)) {
    return $null
  }
  $result = Invoke-RimsExternalCommand `
    -FilePath $git `
    -Arguments @('-C', $Path, 'rev-parse', 'HEAD') `
    -TimeoutSeconds 10
  if ($result.ExitCode -ne 0) {
    return $null
  }
  $commit = $result.StandardOutput.Trim()
  if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
    return $null
  }
  return $commit.ToLowerInvariant()
}

function Compare-RimsPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Left,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Right
  )

  if ([string]::IsNullOrWhiteSpace($Left) -or
      [string]::IsNullOrWhiteSpace($Right)) {
    return $false
  }
  try {
    $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd('\')
    $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd('\')
    return $leftPath.Equals(
      $rightPath,
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Test-RimsRuntimeRequestMatchesState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendDir,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort
  )

  $stateBackend = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendPath' `
      -DefaultValue '')
  $stateWorkspace = [string](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendWorkspaceRoot' `
      -DefaultValue '')
  $statePort = [int](Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'backendPort' `
      -DefaultValue 0)
  return (
    (Compare-RimsPath -Left $stateBackend -Right $BackendDir) -and
    (Compare-RimsPath -Left $stateWorkspace -Right $BackendWorkspaceRoot) -and
    $statePort -eq $BackendPort
  )
}

function Resolve-RimsLifecyclePaths {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot
  )

  $backendState = Resolve-RimsBackendDirectoryState -BackendDir $BackendDir
  $workspaceState = Resolve-RimsBackendWorkspaceRootState `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -BackendDir $(if ($backendState.success) {
        $backendState.path
      } else {
        $BackendDir
      })
  return [pscustomobject][ordered]@{
    success = $backendState.success -and $workspaceState.success
    backendPath = $backendState.path
    backendError = $backendState.error
    workspacePath = $workspaceState.path
    workspaceError = $workspaceState.error
  }
}

function Invoke-RimsLocalStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'status'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  if (-not $resolved.success) {
    $detail = "Lifecycle paths are invalid: $($resolved.backendError) $($resolved.workspaceError)".Trim()
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $detail `
      -Remediation 'Pass valid -BackendDir and -BackendWorkspaceRoot paths.' `
      -Managed $false `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $dependenciesHealthy = $true
  if ($IncludeDependencies) {
    $context = Get-RimsWslLifecycleContext `
      -BackendDir $resolved.backendPath `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -RuntimePaths $paths
    $postgresStatus = if ($context.ok) {
      Get-RimsPostgresStatus -Context $context
    } else {
      [pscustomobject]@{
        ok = $false
        healthy = $false
        detail = $context.detail
      }
    }
    $dependenciesHealthy = $postgresStatus.ok -and $postgresStatus.healthy
    $result.components += New-RimsLocalComponent `
      -Name 'postgres' `
      -Ok $dependenciesHealthy `
      -Required $true `
      -Detail $postgresStatus.detail `
      -Remediation $(if ($dependenciesHealthy) { '' } else {
          'Start PostgreSQL or run up with -IncludeDependencies.'
        })
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state) {
    $occupied = Test-RimsTcpPortListening -Port $BackendPort
    $healthy = if ($occupied) {
      Test-RimsHealthEndpoint -Url "http://localhost:$BackendPort/healthz"
    } else {
      $false
    }
    $detail = if ($occupied) {
      "Port $BackendPort is occupied by an unmanaged process; it was left untouched."
    } else {
      "No managed backend state exists; port $BackendPort is not listening."
    }
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $detail `
      -Remediation $(if ($occupied) {
          'Choose a free -BackendPort or stop the user-managed process yourself.'
        } else {
          'Run the up command to start a managed backend.'
        }) `
      -Managed $false `
      -Healthy $healthy `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $matches = Test-RimsRuntimeRequestMatchesState `
    -State $state `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort
  $owned = Test-RimsStateOwnsProcess -State $state
  $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
  if (-not $matches) {
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Managed state belongs to different backend paths or port; controller-owned resources were left untouched.' `
      -Remediation 'Repeat the command with the paths and port recorded in state.json.' `
      -Managed $owned `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid') `
      -CleanupPending $cleanupPending
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  if ($cleanupPending) {
    $dependencyOwnership = Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'dependencyOwnership'
    $dependencyDetail = [string](Get-RimsObjectPropertyValue `
        -Value $dependencyOwnership `
        -Name 'cleanupFailureDetail' `
        -DefaultValue 'Controller-owned dependency cleanup remains pending.')
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail $(if ($owned) {
          'Backend and dependency cleanup remain pending; exact backend ownership was preserved.'
        } else {
          'Dependency cleanup remains pending; no managed backend process is present.'
        }) `
      -Remediation 'Run down with the same backend paths and port to retry bounded cleanup.' `
      -Managed $owned `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId $(if ($owned) {
          Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
        } else {
          $null
        }) `
      -CleanupPending $true
    $result.components += New-RimsLocalComponent `
      -Name 'dependencyCleanup' `
      -Ok $false `
      -Required $true `
      -Detail (ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $dependencyDetail `
        -StandardError '') `
      -Remediation 'Restore WSL and Docker, then run down with the same parameters.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  if (-not $owned) {
    Remove-RimsRuntimeState -Paths $paths
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Stale managed state was removed; no process matched both the recorded PID and start time.' `
      -Remediation 'Run the up command to start a fresh managed backend.' `
      -Managed $false `
      -Healthy $false `
      -Stale $true `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $healthUrl = [string](Get-RimsObjectPropertyValue `
      -Value $state `
      -Name 'healthUrl' `
      -DefaultValue "http://localhost:$BackendPort/healthz")
  $healthy = Test-RimsHealthEndpoint -Url $healthUrl
  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $healthy `
    -Detail $(if ($healthy) {
        "Managed backend is healthy at $healthUrl."
      } else {
        "Managed backend process exists but is not healthy at $healthUrl."
      }) `
    -Remediation $(if ($healthy) { '' } else {
        'Inspect logs, then run restart or down without changing backend paths or port.'
      }) `
    -Managed $true `
    -Healthy $healthy `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
  $overallHealthy = $healthy -and $dependenciesHealthy
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $overallHealthy `
    -ExitCode $(if ($overallHealthy) { 0 } else { 1 })
}

function Invoke-RimsLocalLogs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory
  )

  $result = New-RimsLocalResult -Command 'logs'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $stdoutTail = @(Get-RimsSanitizedLogTail -Path $paths.stdoutLog)
  $stderrTail = @(Get-RimsSanitizedLogTail -Path $paths.stderrLog)
  $hasLogs = $stdoutTail.Count -gt 0 -or $stderrTail.Count -gt 0
  $component = [pscustomobject][ordered]@{
    name = 'backendLogs'
    ok = $hasLogs
    required = $false
    detail = if ($hasLogs) {
      'Returned bounded sanitized backend log tails.'
    } else {
      'No backend log output is available yet.'
    }
    remediation = if ($hasLogs) { '' } else {
      'Run up to start the managed backend and create logs.'
    }
    stdoutLogPath = $paths.stdoutLog
    stderrLogPath = $paths.stderrLog
    stdoutTail = $stdoutTail
    stderrTail = $stderrTail
  }
  $result.components = @(
    $component,
    (New-RimsRuntimePathsComponent -Paths $paths)
  )
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $true `
    -ExitCode 0
}

function Invoke-RimsLinuxProcessGroupSignal {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessGroupId,
    [ValidateSet('TERM', 'KILL')]
    [string]$Signal = 'TERM'
  )

  if ($ProcessGroupId -le 0) {
    return $false
  }
  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return $false
  }
  $script = @'
set -euo pipefail
pgid=$1
signal=$2
case "$pgid" in ''|*[!0-9]*) exit 2 ;; esac
case "$signal" in TERM|KILL) ;; *) exit 2 ;; esac
kill -s "$signal" -- "-$pgid" 2>/dev/null || true
'@
  $signalResult = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(
      '-e',
      'bash',
      '-c',
      $script,
      'rims-signal',
      [string]$ProcessGroupId,
      $Signal
    ) `
    -TimeoutSeconds 10
  return $signalResult.ExitCode -eq 0
}

function Wait-RimsOwnedProcessExit {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (-not (Test-RimsStateOwnsProcess -State $State)) {
      return $true
    }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return -not (Test-RimsStateOwnsProcess -State $State)
}

function Stop-RimsOwnedBackendProcess {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  $process = Get-RimsOwnedProcess -State $State
  if ($null -eq $process) {
    return $true
  }
  $process.Dispose()

  $processGroupId = 0
  $rawProcessGroupId = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'linuxProcessGroupId'
  $hasProcessGroup = [int]::TryParse(
    [string]$rawProcessGroupId,
    [ref]$processGroupId
  ) -and $processGroupId -gt 0
  if ($hasProcessGroup) {
    [void](Invoke-RimsLinuxProcessGroupSignal `
        -ProcessGroupId $processGroupId `
        -Signal 'TERM')
    if (Wait-RimsOwnedProcessExit -State $State -TimeoutSeconds 10) {
      return $true
    }
    [void](Invoke-RimsLinuxProcessGroupSignal `
        -ProcessGroupId $processGroupId `
        -Signal 'KILL')
    if (Wait-RimsOwnedProcessExit -State $State -TimeoutSeconds 3) {
      return $true
    }
  }

  $ownedProcess = Get-RimsOwnedProcess -State $State
  if ($null -ne $ownedProcess) {
    Stop-RimsProcessTree -Process $ownedProcess
    $ownedProcess.Dispose()
  }
  return Wait-RimsOwnedProcessExit -State $State -TimeoutSeconds 5
}

function Invoke-RimsDependencyCleanup {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [AllowNull()]
    [scriptblock]$ComposeCleanupAction
  )

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  $composeOwned = [bool](Get-RimsObjectPropertyValue `
      -Value $dependencyOwnership `
      -Name 'composeStartedByController' `
      -DefaultValue $false)
  if (-not $composeOwned) {
    return [pscustomobject][ordered]@{
      required = $false
      attempted = $false
      ok = $true
      detail = 'PostgreSQL was not started by this controller and was left untouched.'
    }
  }

  try {
    $rawResult = if ($null -eq $ComposeCleanupAction) {
      Invoke-RimsComposeDown -BackendWorkspaceRoot $BackendWorkspaceRoot
    } else {
      & $ComposeCleanupAction $BackendWorkspaceRoot
    }
    $ok = [bool](Get-RimsObjectPropertyValue `
        -Value $rawResult `
        -Name 'ok' `
        -DefaultValue $false)
    $rawDetail = [string](Get-RimsObjectPropertyValue `
        -Value $rawResult `
        -Name 'detail' `
        -DefaultValue $(if ($ok) {
            'Controller-owned dependency cleanup completed.'
          } else {
            'Controller-owned dependency cleanup failed without detail.'
          }))
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $ok
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $rawDetail `
        -StandardError ''
    }
  } catch {
    return [pscustomobject][ordered]@{
      required = $true
      attempted = $true
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function Resolve-RimsFailedLifecycleCleanup {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FailureContext,
    [AllowNull()]
    [scriptblock]$BackendCleanupAction,
    [AllowNull()]
    [scriptblock]$ComposeCleanupAction
  )

  $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $FailureContext `
    -StandardError ''
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name healthy `
    -Value $false `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name failureContext `
    -Value $sanitizedFailure `
    -Force

  $dependencyOwnership = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'dependencyOwnership'
  if ($null -eq $dependencyOwnership) {
    $dependencyOwnership = [pscustomobject][ordered]@{
      postgresExisted = $true
      postgresWasRunning = $true
      composeStartedByController = $false
      cleanupPending = $false
      cleanupFailureDetail = ''
    }
    $State | Add-Member `
      -MemberType NoteProperty `
      -Name dependencyOwnership `
      -Value $dependencyOwnership `
      -Force
  }
  $composeOwned = [bool](Get-RimsObjectPropertyValue `
      -Value $dependencyOwnership `
      -Name 'composeStartedByController' `
      -DefaultValue $false)
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $composeOwned `
    -Force

  try {
    Write-RimsRuntimeState -Paths $Paths -State $State
  } catch {
    # Cleanup still proceeds; pending ownership is persisted again if needed.
  }

  $backendWasOwned = Test-RimsStateOwnsProcess -State $State
  $backendCleanupOk = $true
  $backendCleanupDetail = 'No owned backend process required cleanup.'
  $backendCleanupAttempted = $false
  if ($backendWasOwned) {
    $backendCleanupAttempted = $true
    $reportedBackendCleanup = $false
    $backendActionDetail = ''
    try {
      $rawBackendCleanup = if ($null -eq $BackendCleanupAction) {
        Stop-RimsOwnedBackendProcess -State $State
      } else {
        & $BackendCleanupAction $State
      }
      $reportedBackendCleanup = [bool](Get-RimsObjectPropertyValue `
          -Value $rawBackendCleanup `
          -Name 'ok' `
          -DefaultValue $rawBackendCleanup)
      $backendActionDetail = [string](Get-RimsObjectPropertyValue `
          -Value $rawBackendCleanup `
          -Name 'detail' `
          -DefaultValue '')
    } catch {
      $reportedBackendCleanup = $false
      $backendActionDetail = $_.Exception.Message
    }
    $backendCleanupOk = -not (Test-RimsStateOwnsProcess -State $State)
    $backendCleanupDetail = if ($backendCleanupOk) {
      'The exactly owned backend process was confirmed stopped.'
    } elseif ($reportedBackendCleanup) {
      'Backend cleanup reported success, but exact process ownership remains.'
    } elseif ([string]::IsNullOrWhiteSpace($backendActionDetail)) {
      'The exactly owned backend process did not stop within the bounded cleanup.'
    } else {
      ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $backendActionDetail `
        -StandardError ''
    }
  }

  if ($backendCleanupOk) {
    foreach ($propertyName in @(
        'windowsPid',
        'windowsProcessStartTimeUtc',
        'linuxProcessGroupId'
      )) {
      $State | Add-Member `
        -MemberType NoteProperty `
        -Name $propertyName `
        -Value $null `
        -Force
    }
  }

  $dependencyCleanup = if ($backendCleanupOk) {
    Invoke-RimsDependencyCleanup `
      -State $State `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -ComposeCleanupAction $ComposeCleanupAction
  } else {
    [pscustomobject][ordered]@{
      required = $composeOwned
      attempted = $false
      ok = -not $composeOwned
      detail = if ($composeOwned) {
        'Dependency cleanup is deferred until the owned backend is confirmed stopped.'
      } else {
        'No controller-owned dependency requires cleanup.'
      }
    }
  }
  $backendCleanup = [pscustomobject][ordered]@{
    required = $backendWasOwned
    attempted = $backendCleanupAttempted
    ok = $backendCleanupOk
    detail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput $backendCleanupDetail `
      -StandardError ''
  }

  if ($backendCleanup.ok -and $dependencyCleanup.ok) {
    if ($composeOwned) {
      $dependencyOwnership | Add-Member `
        -MemberType NoteProperty `
        -Name composeStartedByController `
        -Value $false `
        -Force
    }
    try {
      Remove-RimsRuntimeState -Paths $Paths
      return [pscustomobject][ordered]@{
        ok = $true
        backendCleanup = $backendCleanup
        dependencyCleanup = $dependencyCleanup
        cleanupPending = $false
        managed = $false
        healthy = $false
        stateRetained = $false
        detail = 'All controller-owned runtime resources were cleaned up and state was removed.'
        remediation = ''
      }
    } catch {
      $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput "Cleanup completed, but runtime state removal failed: $($_.Exception.Message)" `
        -StandardError ''
    }
  }

  $dependencyStillPending = -not $dependencyCleanup.ok -and $composeOwned
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $true `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name healthy `
    -Value $false `
    -Force
  $State | Add-Member `
    -MemberType NoteProperty `
    -Name failureContext `
    -Value $sanitizedFailure `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $dependencyStillPending `
    -Force
  $dependencyOwnership | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupFailureDetail `
    -Value $(if ($dependencyStillPending) {
        ConvertTo-RimsDiagnosticSummary `
          -StandardOutput $dependencyCleanup.detail `
          -StandardError ''
      } else {
        ''
      }) `
    -Force

  $statePersisted = $false
  $stateWriteDetail = ''
  try {
    Write-RimsRuntimeState -Paths $Paths -State $State
    $statePersisted = $true
  } catch {
    $stateWriteDetail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
  }
  $managed = Test-RimsStateOwnsProcess -State $State
  $detail = if ($statePersisted) {
    'Cleanup remains pending; controller ownership state was retained for a bounded down retry.'
  } else {
    "Cleanup remains pending and ownership state could not be persisted: $stateWriteDetail"
  }
  return [pscustomobject][ordered]@{
    ok = $false
    backendCleanup = $backendCleanup
    dependencyCleanup = $dependencyCleanup
    cleanupPending = $true
    managed = $managed
    healthy = $false
    stateRetained = $statePersisted
    detail = $detail
    remediation = 'Run down with the same backend paths and port to retry bounded cleanup.'
  }
}

function Get-RimsComposeArguments {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Arguments
  )

  return @(
    '-e',
    'docker',
    'compose',
    '--project-directory',
    [string]$Context.workspace,
    '--env-file',
    [string]$Context.environment,
    '-f',
    [string]$Context.compose
  ) + $Arguments
}

function Get-RimsPostgresDiscoveryArguments {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  return @(Get-RimsComposeArguments `
      -Context $Context `
      -Arguments @('ps', '-a', '-q', 'postgres'))
}

function Invoke-RimsComposeDown {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'wsl.exe is unavailable, so owned Compose services could not be stopped.'
    }
  }
  try {
    $context = [pscustomobject][ordered]@{
      workspace = ConvertTo-RimsWslPath `
        -WindowsPath $BackendWorkspaceRoot `
        -WslExecutable $wsl
      environment = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot '.env') `
        -WslExecutable $wsl
      compose = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot 'deploy\docker-compose.yml') `
        -WslExecutable $wsl
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  $command = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(Get-RimsComposeArguments `
      -Context $context `
      -Arguments @('down')) `
    -TimeoutSeconds 60
  return [pscustomobject][ordered]@{
    ok = $command.ExitCode -eq 0
    detail = if ($command.ExitCode -eq 0) {
      'Stopped controller-owned Compose services without deleting volumes.'
    } else {
      "Could not stop controller-owned Compose services: $(Get-RimsExternalCommandSummary -Result $command)"
    }
  }
}

function Invoke-RimsLocalDown {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'down'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  if (-not $resolved.success) {
    $result.errors = @('Backend paths are invalid; no process was changed.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state) {
    $occupied = Test-RimsTcpPortListening -Port $BackendPort
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $true `
      -Detail $(if ($occupied) {
          "No managed state exists. The process on port $BackendPort was left untouched."
        } else {
          'No managed backend state exists; the runtime is already down.'
        }) `
      -Remediation '' `
      -Managed $false `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort
    return Complete-RimsLocalResult -Result $result -Ok $true -ExitCode 0
  }

  if (-not (Test-RimsRuntimeRequestMatchesState `
      -State $state `
      -BackendDir $resolved.backendPath `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -BackendPort $BackendPort)) {
    $result.components += New-RimsBackendLifecycleComponent `
      -Ok $false `
      -Detail 'Managed state belongs to different backend paths or port; no process was changed.' `
      -Remediation 'Repeat down with the paths and port recorded in state.json.' `
      -Managed (Test-RimsStateOwnsProcess -State $state) `
      -Healthy $false `
      -Stale $false `
      -Port $BackendPort `
      -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $wasOwned = Test-RimsStateOwnsProcess -State $state
  $wasCleanupPending = Test-RimsRuntimeCleanupPending -State $state
  $cleanupOutcome = Resolve-RimsFailedLifecycleCleanup `
    -Paths $paths `
    -State $state `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -FailureContext 'The down command is completing controller-owned runtime cleanup.'
  $result.components += New-RimsLocalComponent `
    -Name 'dependencyCleanup' `
    -Ok $cleanupOutcome.dependencyCleanup.ok `
    -Required $cleanupOutcome.dependencyCleanup.required `
    -Detail $cleanupOutcome.dependencyCleanup.detail `
    -Remediation $(if ($cleanupOutcome.dependencyCleanup.ok) { '' } else {
        'Restore WSL and Docker, then retry down with the same parameters.'
      })
  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $cleanupOutcome.backendCleanup.ok `
    -Detail $(if ($cleanupOutcome.ok -and $wasOwned) {
        'Stopped the exactly owned managed backend and completed runtime cleanup.'
      } elseif ($cleanupOutcome.ok -and $wasCleanupPending) {
        'Completed pending controller-owned runtime cleanup.'
      } elseif ($cleanupOutcome.ok) {
        'Removed stale runtime state without terminating any unrelated process.'
      } else {
        "$($cleanupOutcome.backendCleanup.detail) $($cleanupOutcome.detail)"
      }) `
    -Remediation $cleanupOutcome.remediation `
    -Managed $cleanupOutcome.managed `
    -Healthy $false `
    -Stale (-not $wasOwned -and -not $wasCleanupPending) `
    -Port $BackendPort `
    -ProcessId $(if ($cleanupOutcome.managed) {
        Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
      } else {
        $null
      }) `
    -CleanupPending $cleanupOutcome.cleanupPending
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $cleanupOutcome.ok `
    -ExitCode $(if ($cleanupOutcome.ok) { 0 } else { 1 })
}

function Get-RimsWslLifecycleContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BackendDir,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'wsl.exe is unavailable.'
    }
  }
  try {
    return [pscustomobject][ordered]@{
      ok = $true
      detail = ''
      wsl = $wsl
      backend = ConvertTo-RimsWslPath `
        -WindowsPath $BackendDir `
        -WslExecutable $wsl
      workspace = ConvertTo-RimsWslPath `
        -WindowsPath $BackendWorkspaceRoot `
        -WslExecutable $wsl
      environment = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot '.env') `
        -WslExecutable $wsl
      compose = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendWorkspaceRoot 'deploy\docker-compose.yml') `
        -WslExecutable $wsl
      migrations = ConvertTo-RimsWslPath `
        -WindowsPath (Join-Path $BackendDir 'migrations') `
        -WslExecutable $wsl
      runtime = ConvertTo-RimsWslPath `
        -WindowsPath $RuntimePaths.root `
        -WslExecutable $wsl
      processGroupFile = ConvertTo-RimsWslPath `
        -WindowsPath $RuntimePaths.linuxProcessGroup `
        -WslExecutable $wsl
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function ConvertTo-RimsPostgresStatus {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ContainerId,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$StateStatus,
    [Parameter(Mandatory = $true)]
    [bool]$Running,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$HealthStatus
  )

  $exists = -not [string]::IsNullOrWhiteSpace($ContainerId)
  $normalizedState = ([string]$StateStatus).Trim().ToLowerInvariant()
  $normalizedHealth = ([string]$HealthStatus).Trim().ToLowerInvariant()
  $status = if (-not $exists) {
    'absent'
  } elseif (-not $Running -and $normalizedState.Length -gt 0) {
    $normalizedState
  } elseif ($normalizedHealth.Length -gt 0) {
    $normalizedHealth
  } elseif ($normalizedState.Length -gt 0) {
    $normalizedState
  } else {
    'unknown'
  }
  $healthy = $exists -and $Running -and $normalizedHealth -eq 'healthy'
  return [pscustomobject][ordered]@{
    ok = $true
    exists = $exists
    running = $exists -and $Running
    healthy = $healthy
    containerId = if ($exists) { $ContainerId.Trim() } else { $null }
    status = $status
    detail = "PostgreSQL container status: $status."
  }
}

function Get-RimsPostgresDependencyOwnership {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Status
  )

  $controllerOwned = -not [bool]$Status.exists
  return [pscustomobject][ordered]@{
    postgresExisted = [bool]$Status.exists
    postgresWasRunning = [bool]$Status.running
    composeStartedByController = $controllerOwned
    cleanupComposeOnFailure = $controllerOwned
    stopComposeOnDown = $controllerOwned
  }
}

function Get-RimsPostgresStatus {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $check = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(Get-RimsPostgresDiscoveryArguments -Context $Context) `
    -TimeoutSeconds 20
  if ($check.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $false
      running = $false
      healthy = $false
      containerId = $null
      status = 'unknown'
      detail = Get-RimsExternalCommandSummary -Result $check
    }
  }
  $containerId = $check.StandardOutput.Trim()
  if ([string]::IsNullOrWhiteSpace($containerId)) {
    return ConvertTo-RimsPostgresStatus `
      -ContainerId '' `
      -StateStatus '' `
      -Running $false `
      -HealthStatus ''
  }
  $inspect = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(
      '-e',
      'docker',
      'inspect',
      '--format',
      '{{json .State}}',
      $containerId
    ) `
    -TimeoutSeconds 20
  if ($inspect.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      running = $false
      healthy = $false
      containerId = $containerId
      status = 'unknown'
      detail = Get-RimsExternalCommandSummary -Result $inspect
    }
  }
  try {
    $containerState = $inspect.StandardOutput |
      ConvertFrom-Json -ErrorAction Stop
    $health = Get-RimsObjectPropertyValue `
      -Value $containerState `
      -Name 'Health'
    return ConvertTo-RimsPostgresStatus `
      -ContainerId $containerId `
      -StateStatus ([string](Get-RimsObjectPropertyValue `
          -Value $containerState `
          -Name 'Status' `
          -DefaultValue 'unknown')) `
      -Running ([bool](Get-RimsObjectPropertyValue `
          -Value $containerState `
          -Name 'Running' `
          -DefaultValue $false)) `
      -HealthStatus ([string](Get-RimsObjectPropertyValue `
          -Value $health `
          -Name 'Status' `
          -DefaultValue ''))
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      running = $false
      healthy = $false
      containerId = $containerId
      status = 'unknown'
      detail = 'Docker returned malformed PostgreSQL state.'
    }
  }
}

function Invoke-RimsComposeUpPostgres {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $command = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(Get-RimsComposeArguments `
      -Context $Context `
      -Arguments @('up', '-d', 'postgres')) `
    -TimeoutSeconds 120
  return [pscustomobject][ordered]@{
    ok = $command.ExitCode -eq 0
    detail = if ($command.ExitCode -eq 0) {
      'Started PostgreSQL with Docker Compose.'
    } else {
      "Docker Compose could not start PostgreSQL: $(Get-RimsExternalCommandSummary -Result $command)"
    }
  }
}

function Wait-RimsPostgresHealthy {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = $null
  do {
    $lastStatus = Get-RimsPostgresStatus -Context $Context
    if ($lastStatus.ok -and $lastStatus.healthy) {
      return $lastStatus
    }
    Start-Sleep -Milliseconds 1000
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}

function Get-RimsMigrationLaunchScript {
  return @'
set -euo pipefail
env_file=$1
source_dir=$2
runtime_dir=$3
stage_dir="$runtime_dir/migrations.normalized.$$"
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage_dir"
found=0
for file in "$source_dir"/migrations/*.sql; do
  [ -f "$file" ] || continue
  found=1
  name=$(basename "$file")
  sed 's/\r$//' "$file" > "$stage_dir/$name"
done
if [ "$found" -ne 1 ]; then
  printf 'No source migration files were found.\n' >&2
  exit 1
fi
set -a
. "$env_file"
set +a
unshare --user --map-root-user --mount bash -c '
  set -euo pipefail
  stage_dir=$1
  source_dir=$2
  mount --bind "$stage_dir" "$source_dir/migrations"
  export MIGRATIONS_DIR="$source_dir/migrations"
  cd "$source_dir"
  exec "$HOME/local/go/bin/go" run ./cmd/migrate up
' rims-migrate-namespace "$stage_dir" "$source_dir"
'@
}

function Invoke-RimsBackendMigrations {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context
  )

  $script = Get-RimsMigrationLaunchScript
  $migration = Invoke-RimsExternalCommand `
    -FilePath $Context.wsl `
    -Arguments @(
      '-e',
      'bash',
      '-c',
      $script,
      'rims-migrate',
      $Context.environment,
      $Context.backend,
      $Context.runtime
    ) `
    -TimeoutSeconds 180
  return [pscustomobject][ordered]@{
    ok = $migration.ExitCode -eq 0
    detail = if ($migration.ExitCode -eq 0) {
      'Backend migrations are up to date.'
    } else {
      "Backend migrations failed: $(Get-RimsExternalCommandSummary -Result $migration)"
    }
  }
}

function Start-RimsManagedBackend {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort
  )

  Initialize-RimsRuntimeDirectories -Paths $RuntimePaths
  foreach ($path in @(
      [string]$RuntimePaths.stdoutLog,
      [string]$RuntimePaths.stderrLog,
      [string]$RuntimePaths.linuxProcessGroup
    )) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [IO.File]::Delete($path)
    }
  }

  $launchScript = @'
set -euo pipefail
env_file=$1
source_dir=$2
migrations_dir=$3
port=$4
pgid_file=$5
set -a
. "$env_file"
set +a
export APP_PORT="$port"
export MIGRATIONS_DIR="$migrations_dir"
cd "$source_dir"
exec setsid --fork --wait bash -c '
  set -euo pipefail
  pgid_file=$1
  umask 077
  printf "%s\n" "$$" > "$pgid_file"
  exec "$HOME/local/go/bin/go" run ./cmd/server
' rims-server "$pgid_file"
'@
  $arguments = @(
    '-e',
    'bash',
    '-c',
    $launchScript,
    'rims-backend-launch',
    $Context.environment,
    $Context.backend,
    $Context.migrations,
    [string]$BackendPort,
    $Context.processGroupFile
  )
  $argumentLine = ($arguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value $_
    }) -join ' '
  $process = $null
  $processStartTime = $null
  $processGroupId = 0
  $healthUrl = "http://localhost:$BackendPort/healthz"
  try {
    $process = Start-Process `
      -FilePath $Context.wsl `
      -ArgumentList $argumentLine `
      -WindowStyle Hidden `
      -PassThru `
      -RedirectStandardOutput $RuntimePaths.stdoutLog `
      -RedirectStandardError $RuntimePaths.stderrLog
    $processStartTime = $process.StartTime.ToUniversalTime().ToString(
      'o',
      [Globalization.CultureInfo]::InvariantCulture
    )
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    do {
      $process.Refresh()
      if ($process.HasExited) {
        break
      }
      if ($processGroupId -le 0 -and
          (Test-Path `
            -LiteralPath $RuntimePaths.linuxProcessGroup `
            -PathType Leaf)) {
        $rawProcessGroup = [IO.File]::ReadAllText(
          [string]$RuntimePaths.linuxProcessGroup
        ).Trim()
        [void][int]::TryParse($rawProcessGroup, [ref]$processGroupId)
      }
      if ($processGroupId -gt 0 -and
          (Test-RimsHealthEndpoint -Url $healthUrl -TimeoutSeconds 2)) {
        $ready = $true
        break
      }
      Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if ($ready) {
      return [pscustomobject][ordered]@{
        ok = $true
        processStarted = $true
        detail = "Managed backend is healthy at $healthUrl."
        healthUrl = $healthUrl
        windowsPid = $process.Id
        windowsProcessStartTimeUtc = $processStartTime
        linuxProcessGroupId = $processGroupId
      }
    }

    $stderrTail = @(Get-RimsSanitizedLogTail `
        -Path $RuntimePaths.stderrLog `
        -MaximumLines 20)
    $tailDetail = if ($stderrTail.Count -gt 0) {
      $stderrTail -join ' | '
    } else {
      'No backend stderr was captured.'
    }
    return [pscustomobject][ordered]@{
      ok = $false
      processStarted = $true
      detail = "Backend did not become ready within 90 seconds. $tailDetail"
      healthUrl = $healthUrl
      windowsPid = $process.Id
      windowsProcessStartTimeUtc = $processStartTime
      linuxProcessGroupId = if ($processGroupId -gt 0) {
        $processGroupId
      } else {
        $null
      }
    }
  } catch {
    if ($null -ne $process) {
      try {
        if ([string]::IsNullOrWhiteSpace([string]$processStartTime)) {
          $processStartTime = $process.StartTime.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
          )
        }
      } catch {}
    }
    if ($processGroupId -le 0 -and
        (Test-Path `
          -LiteralPath $RuntimePaths.linuxProcessGroup `
          -PathType Leaf)) {
      try {
        $rawProcessGroup = [IO.File]::ReadAllText(
          [string]$RuntimePaths.linuxProcessGroup
        ).Trim()
        [void][int]::TryParse($rawProcessGroup, [ref]$processGroupId)
      } catch {}
    }
    return [pscustomobject][ordered]@{
      ok = $false
      processStarted = $null -ne $process -and
        -not [string]::IsNullOrWhiteSpace([string]$processStartTime)
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      healthUrl = "http://localhost:$BackendPort/healthz"
      windowsPid = if ($null -ne $process) { $process.Id } else { $null }
      windowsProcessStartTimeUtc = $processStartTime
      linuxProcessGroupId = if ($processGroupId -gt 0) {
        $processGroupId
      } else {
        $null
      }
    }
  } finally {
    if ($null -ne $process) {
      $process.Dispose()
    }
  }
}

function New-RimsManagedRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FrontendPath,
    [Parameter(Mandatory = $true)]
    [string]$BackendPath,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [psobject]$StartedBackend,
    [Parameter(Mandatory = $true)]
    [bool]$PostgresExisted,
    [Parameter(Mandatory = $true)]
    [bool]$PostgresWasRunning,
    [Parameter(Mandatory = $true)]
    [bool]$ComposeStartedByController,
    [bool]$Healthy = $true,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FailureContext = ''
  )

  $runtimeCommit = Get-RimsGitCommit -Path $FrontendPath
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    frontendPath = $FrontendPath
    backendPath = $BackendPath
    backendWorkspaceRoot = $BackendWorkspaceRoot
    frontendCommit = $runtimeCommit
    runtimeCommit = $runtimeCommit
    backendCommit = Get-RimsGitCommit -Path $BackendPath
    target = $Target
    backendPort = $BackendPort
    frontendPort = $FrontendPort
    startedAt = Get-RimsLocalTimestamp
    healthUrl = $StartedBackend.healthUrl
    healthy = $Healthy
    cleanupPending = $false
    failureContext = if ([string]::IsNullOrWhiteSpace($FailureContext)) {
      ''
    } else {
      ConvertTo-RimsDiagnosticSummary `
        -StandardOutput $FailureContext `
        -StandardError ''
    }
    windowsPid = $StartedBackend.windowsPid
    windowsProcessStartTimeUtc = $StartedBackend.windowsProcessStartTimeUtc
    linuxProcessGroupId = $StartedBackend.linuxProcessGroupId
    runtimeRoot = $RuntimePaths.root
    statePath = $RuntimePaths.state
    stdoutLogPath = $RuntimePaths.stdoutLog
    stderrLogPath = $RuntimePaths.stderrLog
    commandSummary = "wsl.exe managed go run ./cmd/server with APP_PORT=$BackendPort"
    dependencyOwnership = [pscustomobject][ordered]@{
      postgresExisted = $PostgresExisted
      postgresWasRunning = $PostgresWasRunning
      composeStartedByController = $ComposeStartedByController
      cleanupPending = $false
      cleanupFailureDetail = ''
    }
  }
}

function Complete-RimsFailedUpResult {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result,
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FailureContext,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Remediation
  )

  $cleanupOutcome = Resolve-RimsFailedLifecycleCleanup `
    -Paths $Paths `
    -State $State `
    -BackendWorkspaceRoot $BackendWorkspaceRoot `
    -FailureContext $FailureContext
  $sanitizedFailure = ConvertTo-RimsDiagnosticSummary `
    -StandardOutput $FailureContext `
    -StandardError ''
  $Result.components += New-RimsLocalComponent `
    -Name 'dependencyCleanup' `
    -Ok $cleanupOutcome.dependencyCleanup.ok `
    -Required $cleanupOutcome.dependencyCleanup.required `
    -Detail $cleanupOutcome.dependencyCleanup.detail `
    -Remediation $(if ($cleanupOutcome.dependencyCleanup.ok) { '' } else {
        'Restore WSL and Docker, then run down with the same parameters.'
      })
  $Result.components += New-RimsBackendLifecycleComponent `
    -Ok $false `
    -Detail "$sanitizedFailure $($cleanupOutcome.detail)" `
    -Remediation $(if ($cleanupOutcome.cleanupPending) {
        $cleanupOutcome.remediation
      } else {
        $Remediation
      }) `
    -Managed $cleanupOutcome.managed `
    -Healthy $false `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId $(if ($cleanupOutcome.managed) {
        Get-RimsObjectPropertyValue -Value $State -Name 'windowsPid'
      } else {
        $null
      }) `
    -CleanupPending $cleanupOutcome.cleanupPending
  return Complete-RimsLocalResult -Result $Result -Ok $false -ExitCode 1
}

function Invoke-RimsLocalUp {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'up'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $result.components += New-RimsRuntimePathsComponent -Paths $paths
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot

  $doctorComponents = @(Invoke-RimsLocalDoctor `
      -Target $Target `
      -BackendDir $BackendDir `
      -BackendWorkspaceRoot $BackendWorkspaceRoot `
      -AndroidDevice $AndroidDevice `
      -ScriptDirectory $ScriptDirectory)
  $result.components += $doctorComponents
  $failedDoctor = @($doctorComponents | Where-Object {
      $_.required -and -not $_.ok
    })
  if (-not $resolved.success -or $failedDoctor.Count -gt 0) {
    $result.errors = @('Required local runtime checks failed; no process was started.')
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -ne $state) {
    $owned = Test-RimsStateOwnsProcess -State $state
    $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
    if ($cleanupPending) {
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'Controller-owned cleanup is pending; up will not discard or replace its ownership state.' `
        -Remediation 'Run down with the paths and port recorded in state.json before retrying up.' `
        -Managed $owned `
        -Healthy $false `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId $(if ($owned) {
            Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid'
          } else {
            $null
          }) `
        -CleanupPending $true
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    } elseif (-not $owned) {
      Remove-RimsRuntimeState -Paths $paths
      $state = $null
    } elseif (-not (Test-RimsRuntimeRequestMatchesState `
        -State $state `
        -BackendDir $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -BackendPort $BackendPort)) {
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'An owned backend is already managed with different paths or port.' `
        -Remediation 'Run down with the values recorded in state.json before changing lifecycle parameters.' `
        -Managed $true `
        -Healthy $false `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    } else {
      $healthUrl = [string](Get-RimsObjectPropertyValue `
          -Value $state `
          -Name 'healthUrl' `
          -DefaultValue "http://localhost:$BackendPort/healthz")
      $healthy = Test-RimsHealthEndpoint -Url $healthUrl
      $result.components += New-RimsBackendLifecycleComponent `
        -Ok $healthy `
        -Detail $(if ($healthy) {
            "The already-owned backend is healthy at $healthUrl; no process was started."
          } else {
            'The owned backend process exists but is unhealthy; up will not replace it implicitly.'
          }) `
        -Remediation $(if ($healthy) { '' } else {
            'Inspect logs and run restart or down with the same parameters.'
          }) `
        -Managed $true `
        -Healthy $healthy `
        -Stale $false `
        -Port $BackendPort `
        -ProcessId (Get-RimsObjectPropertyValue -Value $state -Name 'windowsPid')
      return Complete-RimsLocalResult `
        -Result $result `
        -Ok $healthy `
        -ExitCode $(if ($healthy) { 0 } else { 1 })
    }
  }

  if (Test-RimsTcpPortListening -Port $BackendPort) {
    $result.components += New-RimsBackendPortComponent `
      -Ok $false `
      -Port $BackendPort `
      -Detail "Port $BackendPort is occupied without matching managed state; the listener was left untouched." `
      -Remediation 'Choose a free -BackendPort or stop the user-managed process yourself.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
  $result.components += New-RimsBackendPortComponent `
    -Ok $true `
    -Port $BackendPort `
    -Detail "Port $BackendPort is available for the managed backend." `
    -Remediation ''

  $frontendPath = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  Initialize-RimsRuntimeDirectories -Paths $paths
  $context = Get-RimsWslLifecycleContext `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -RuntimePaths $paths
  if (-not $context.ok) {
    $result.errors = @("Could not prepare WSL lifecycle paths: $($context.detail)")
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $postgresBefore = Get-RimsPostgresStatus -Context $context
  if (-not $postgresBefore.ok) {
    $result.components += New-RimsLocalComponent `
      -Name 'postgres' `
      -Ok $false `
      -Required $true `
      -Detail "Could not inspect PostgreSQL: $($postgresBefore.detail)" `
      -Remediation 'Start Docker Desktop and verify the configured Compose project.'
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }
  $postgresOwnership = Get-RimsPostgresDependencyOwnership `
    -Status $postgresBefore
  $postgresExisted = $postgresOwnership.postgresExisted
  $postgresWasRunning = $postgresOwnership.postgresWasRunning
  $composeStarted = $postgresOwnership.composeStartedByController
  $notStartedBackend = [pscustomobject][ordered]@{
    healthUrl = "http://localhost:$BackendPort/healthz"
    windowsPid = $null
    windowsProcessStartTimeUtc = $null
    linuxProcessGroupId = $null
  }
  $failedLifecycleState = New-RimsManagedRuntimeState `
    -FrontendPath $frontendPath `
    -BackendPath $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -Target $Target `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -RuntimePaths $paths `
    -StartedBackend $notStartedBackend `
    -PostgresExisted $postgresExisted `
    -PostgresWasRunning $postgresWasRunning `
    -ComposeStartedByController $composeStarted `
    -Healthy $false `
    -FailureContext 'Backend startup did not complete.'
  if (-not $postgresBefore.healthy) {
    if (-not $IncludeDependencies) {
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail "PostgreSQL is not healthy ($($postgresBefore.status))." `
        -Remediation 'Run up with -IncludeDependencies or start PostgreSQL yourself.'
      return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
    }
    $composeUp = Invoke-RimsComposeUpPostgres -Context $context
    if (-not $composeUp.ok) {
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail $composeUp.detail `
        -Remediation 'Repair Docker Compose, then retry up with -IncludeDependencies.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $composeUp.detail `
        -BackendPort $BackendPort `
        -Remediation 'Repair Docker Compose, then retry up with -IncludeDependencies.'
    }
    $postgresReady = Wait-RimsPostgresHealthy -Context $context
    if ($null -eq $postgresReady -or -not $postgresReady.healthy) {
      $readinessFailure = if ($composeStarted) {
        'Controller-started PostgreSQL did not become healthy within 90 seconds.'
      } else {
        'Pre-existing PostgreSQL did not become healthy within 90 seconds and remains user-managed.'
      }
      $result.components += New-RimsLocalComponent `
        -Name 'postgres' `
        -Ok $false `
        -Required $true `
        -Detail $readinessFailure `
        -Remediation 'Inspect Docker Compose logs and retry after PostgreSQL is healthy.'
      return Complete-RimsFailedUpResult `
        -Result $result `
        -Paths $paths `
        -State $failedLifecycleState `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -FailureContext $readinessFailure `
        -BackendPort $BackendPort `
        -Remediation 'Inspect Docker Compose logs and retry after PostgreSQL is healthy.'
    }
  }
  $result.components += New-RimsLocalComponent `
    -Name 'postgres' `
    -Ok $true `
    -Required $true `
    -Detail $(if ($postgresBefore.healthy) {
        'PostgreSQL was already healthy and remains user-managed.'
      } elseif ($postgresExisted) {
        'Pre-existing PostgreSQL was repaired and remains user-managed.'
      } else {
        'PostgreSQL was started by this controller and is healthy.'
      }) `
    -Remediation ''

  $migration = Invoke-RimsBackendMigrations -Context $context
  $result.components += New-RimsLocalComponent `
    -Name 'migrations' `
    -Ok $migration.ok `
    -Required $true `
    -Detail $migration.detail `
    -Remediation $(if ($migration.ok) { '' } else {
        'Inspect the sanitized migration error and verify database configuration.'
      })
  if (-not $migration.ok) {
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $failedLifecycleState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext $migration.detail `
      -BackendPort $BackendPort `
      -Remediation 'Inspect the sanitized migration error and verify database configuration.'
  }

  $started = Start-RimsManagedBackend `
    -Context $context `
    -RuntimePaths $paths `
    -BackendPort $BackendPort
  if (-not $started.ok) {
    $failedState = if ($started.processStarted) {
      New-RimsManagedRuntimeState `
        -FrontendPath $frontendPath `
        -BackendPath $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -Target $Target `
        -BackendPort $BackendPort `
        -FrontendPort $FrontendPort `
        -RuntimePaths $paths `
        -StartedBackend $started `
        -PostgresExisted $postgresExisted `
        -PostgresWasRunning $postgresWasRunning `
        -ComposeStartedByController $composeStarted `
        -Healthy $false `
        -FailureContext $started.detail
    } else {
      $failedLifecycleState
    }
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $failedState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext $started.detail `
      -BackendPort $BackendPort `
      -Remediation 'Inspect the sanitized backend stderr tail, correct the failure, and retry up.'
  }

  $newState = New-RimsManagedRuntimeState `
    -FrontendPath $frontendPath `
    -BackendPath $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -Target $Target `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -RuntimePaths $paths `
    -StartedBackend $started `
    -PostgresExisted $postgresExisted `
    -PostgresWasRunning $postgresWasRunning `
    -ComposeStartedByController $composeStarted `
    -Healthy $true
  try {
    Write-RimsRuntimeState -Paths $paths -State $newState
  } catch {
    $summary = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    $result.errors = @("Could not persist managed ownership state: $summary")
    return Complete-RimsFailedUpResult `
      -Result $result `
      -Paths $paths `
      -State $newState `
      -BackendWorkspaceRoot $resolved.workspacePath `
      -FailureContext "Could not persist managed ownership state: $summary" `
      -BackendPort $BackendPort `
      -Remediation 'Restore runtime directory write access, then retry up.'
  }

  $result.components += New-RimsBackendLifecycleComponent `
    -Ok $true `
    -Detail $started.detail `
    -Remediation '' `
    -Managed $true `
    -Healthy $true `
    -Stale $false `
    -Port $BackendPort `
    -ProcessId $started.windowsPid
  return Complete-RimsLocalResult -Result $result -Ok $true -ExitCode 0
}

function Invoke-RimsLocalRestart {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('none', 'web', 'android')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendDir,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BackendWorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [int]$FrontendPort,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$AndroidDevice,
    [switch]$IncludeDependencies
  )

  $result = New-RimsLocalResult -Command 'restart'
  $paths = Get-RimsRuntimePaths -ScriptDirectory $ScriptDirectory
  $resolved = Resolve-RimsLifecyclePaths `
    -BackendDir $BackendDir `
    -BackendWorkspaceRoot $BackendWorkspaceRoot
  $state = Read-RimsRuntimeState -Paths $paths
  if ($null -eq $state -or
      -not $resolved.success -or
      -not (Test-RimsStateOwnsProcess -State $state) -or
      -not (Test-RimsRuntimeRequestMatchesState `
        -State $state `
        -BackendDir $resolved.backendPath `
        -BackendWorkspaceRoot $resolved.workspacePath `
        -BackendPort $BackendPort)) {
    if ($null -ne $state -and
        -not (Test-RimsStateOwnsProcess -State $state) -and
        -not (Test-RimsRuntimeCleanupPending -State $state)) {
      Remove-RimsRuntimeState -Paths $paths
    }
    $cleanupPending = Test-RimsRuntimeCleanupPending -State $state
    $result.components = @(
      (New-RimsRuntimePathsComponent -Paths $paths),
      (New-RimsBackendLifecycleComponent `
        -Ok $false `
        -Detail 'Restart requires an exactly owned backend matching the requested paths and port.' `
        -Remediation 'Use status, then start with up or repeat restart using state.json values.' `
        -Managed $false `
        -Healthy $false `
        -Stale ($null -ne $state) `
        -Port $BackendPort `
        -CleanupPending $cleanupPending)
    )
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode 1
  }

  $down = Invoke-RimsLocalDown `
    -ScriptDirectory $ScriptDirectory `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort `
    -IncludeDependencies:$IncludeDependencies
  if (-not $down.ok) {
    $result.components = @($down.components)
    $result.errors = @($down.errors)
    return Complete-RimsLocalResult -Result $result -Ok $false -ExitCode $down.exitCode
  }

  $up = Invoke-RimsLocalUp `
    -Target $Target `
    -ScriptDirectory $ScriptDirectory `
    -BackendDir $resolved.backendPath `
    -BackendWorkspaceRoot $resolved.workspacePath `
    -BackendPort $BackendPort `
    -FrontendPort $FrontendPort `
    -AndroidDevice $AndroidDevice `
    -IncludeDependencies:$IncludeDependencies
  $result.components = @($up.components)
  $result.errors = @($up.errors)
  return Complete-RimsLocalResult `
    -Result $result `
    -Ok $up.ok `
    -ExitCode $up.exitCode
}

function Write-RimsLifecycleText {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  foreach ($component in @($Result.components)) {
    $status = if ($component.ok) { 'PASS' } else { 'FAIL' }
    [Console]::Out.WriteLine(
      "[$status] $($component.name) - $($component.detail)"
    )
    if (-not $component.ok -and
        -not [string]::IsNullOrWhiteSpace([string]$component.remediation)) {
      [Console]::Out.WriteLine(
        "       Remediation: $($component.remediation)"
      )
    }
  }
  foreach ($message in @($Result.errors)) {
    [Console]::Out.WriteLine("[FAIL] $($Result.command) - $message")
  }
}

function Write-RimsLogsText {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  $logs = @($Result.components | Where-Object {
      $_.name -eq 'backendLogs'
    }) | Select-Object -First 1
  if ($null -eq $logs) {
    Write-RimsLifecycleText -Result $Result
    return
  }
  [Console]::Out.WriteLine("Backend stdout ($($logs.stdoutLogPath)):")
  foreach ($line in @($logs.stdoutTail)) {
    [Console]::Out.WriteLine($line)
  }
  [Console]::Out.WriteLine("Backend stderr ($($logs.stderrLogPath)):")
  foreach ($line in @($logs.stderrTail)) {
    [Console]::Out.WriteLine($line)
  }
}
