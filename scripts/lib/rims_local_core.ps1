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
    $effectiveArguments = @(ConvertTo-RimsWslBashArguments `
        -FilePath $FilePath `
        -Arguments $Arguments)
    $quotedArguments = $effectiveArguments | ForEach-Object {
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

function ConvertTo-RimsWslBashArguments {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Arguments
  )

  $normalized = [string[]]@($Arguments)
  if ([IO.Path]::GetFileName($FilePath) -ieq 'wsl.exe' -and
      $normalized.Count -ge 4 -and
      $normalized[1] -eq 'bash' -and
      $normalized[2] -in @('-c', '-lc')) {
    $normalized[3] = $normalized[3].Replace("`r`n", "`n").Replace("`r", "`n")
  }
  return $normalized
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
    if ($Path.IndexOfAny([char[]]@('<', '>', '"', '|')) -ge 0) {
      throw 'Path contains a reserved Windows path character.'
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

function Get-RimsFileSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = $null
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $stream = [IO.File]::Open(
      $Path,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::Read
    )
    return ([BitConverter]::ToString(
        $sha256.ComputeHash($stream)
      ) -replace '-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
    $sha256.Dispose()
  }
}
