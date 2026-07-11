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
    linuxIdentity = Join-Path $rootResolution.path 'backend.identity.json'
    backendActivationGate = Join-Path $rootResolution.path 'backend.activate'
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

function Get-RimsStateTemporaryPath {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  return ([string]$Paths.state) + '.tmp.' + [guid]::NewGuid().ToString('N')
}

function Write-RimsDurableUtf8File {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Content
  )

  $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Content)
  $stream = $null
  try {
    $stream = New-Object IO.FileStream(
      $Path,
      [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,
      [IO.FileShare]::None,
      4096,
      [IO.FileOptions]::WriteThrough
    )
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Write-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  Initialize-RimsRuntimeDirectories -Paths $Paths
  $temporaryPath = Get-RimsStateTemporaryPath -Paths $Paths
  $backupPath = ([string]$Paths.state) +
    '.previous.' + [guid]::NewGuid().ToString('N')
  $json = $State | ConvertTo-Json -Depth 10
  try {
    Write-RimsDurableUtf8File -Path $temporaryPath -Content $json
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

function Remove-RimsRuntimeState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths
  )

  foreach ($path in @(
      [string]$Paths.state,
      [string]$Paths.linuxProcessGroup,
      [string](Get-RimsObjectPropertyValue `
        -Value $Paths `
        -Name 'linuxIdentity' `
        -DefaultValue ''),
      [string](Get-RimsObjectPropertyValue `
        -Value $Paths `
        -Name 'backendActivationGate' `
        -DefaultValue '')
    )) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and
        (Test-Path -LiteralPath $path -PathType Leaf)) {
      [IO.File]::Delete($path)
    }
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

function Get-RimsLifecycleLockNames {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [AllowNull()]
    [Nullable[int]]$BackendPort
  )

  $canonicalRuntime = [IO.Path]::GetFullPath([string]$Paths.root).
    TrimEnd('\').ToLowerInvariant()
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $runtimeBytes = [Text.Encoding]::UTF8.GetBytes($canonicalRuntime)
    $runtimeHash = ([BitConverter]::ToString(
        $sha256.ComputeHash($runtimeBytes)
      ) -replace '-', '').ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }

  $names = New-Object 'Collections.Generic.List[string]'
  [void]$names.Add("Local\RimsLocal-runtime-$runtimeHash")
  if ($null -ne $BackendPort) {
    [void]$names.Add("Local\RimsLocal-port-$BackendPort")
  }
  $result = $names.ToArray()
  [Array]::Sort($result, [StringComparer]::Ordinal)
  return $result
}

function Enter-RimsLifecycleLock {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Paths,
    [AllowNull()]
    [Nullable[int]]$BackendPort,
    [ValidateRange(1, 60000)]
    [int]$TimeoutMilliseconds = 5000
  )

  $names = @(Get-RimsLifecycleLockNames `
      -Paths $Paths `
      -BackendPort $BackendPort)
  $acquired = New-Object 'Collections.Generic.List[object]'
  $deadline = [Diagnostics.Stopwatch]::StartNew()
  foreach ($name in $names) {
    $mutex = $null
    $ownsMutex = $false
    try {
      $createdNew = $false
      $mutex = New-Object Threading.Mutex(
        $false,
        $name,
        [ref]$createdNew
      )
      $remaining = [Math]::Max(
        0,
        $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
      )
      try {
        $ownsMutex = $mutex.WaitOne($remaining)
      } catch [Threading.AbandonedMutexException] {
        $ownsMutex = $true
      }
      if (-not $ownsMutex) {
        $mutex.Dispose()
        for ($index = $acquired.Count - 1; $index -ge 0; $index--) {
          try { $acquired[$index].mutex.ReleaseMutex() } catch {}
          $acquired[$index].mutex.Dispose()
        }
        return [pscustomobject][ordered]@{
          ok = $false
          busy = $true
          detail = 'Another local lifecycle command owns the runtime or backend port lock.'
          names = $names
          handles = @()
          released = $true
        }
      }
      [void]$acquired.Add([pscustomobject]@{
          name = $name
          mutex = $mutex
        })
    } catch {
      if ($null -ne $mutex -and -not $ownsMutex) {
        $mutex.Dispose()
      }
      for ($index = $acquired.Count - 1; $index -ge 0; $index--) {
        try { $acquired[$index].mutex.ReleaseMutex() } catch {}
        $acquired[$index].mutex.Dispose()
      }
      return [pscustomobject][ordered]@{
        ok = $false
        busy = $false
        detail = ConvertTo-RimsDiagnosticSummary `
          -StandardOutput '' `
          -StandardError $_.Exception.Message
        names = $names
        handles = @()
        released = $true
      }
    }
  }
  $deadline.Stop()
  return [pscustomobject][ordered]@{
    ok = $true
    busy = $false
    detail = 'Acquired exclusive local lifecycle locks.'
    names = $names
    handles = @($acquired.ToArray())
    released = $false
  }
}

function Exit-RimsLifecycleLock {
  param(
    [AllowNull()]
    [object]$Lock
  )

  if ($null -eq $Lock -or
      [bool](Get-RimsObjectPropertyValue `
        -Value $Lock `
        -Name 'released' `
        -DefaultValue $true)) {
    return
  }
  $handles = @(Get-RimsObjectPropertyValue `
      -Value $Lock `
      -Name 'handles' `
      -DefaultValue @())
  for ($index = $handles.Count - 1; $index -ge 0; $index--) {
    try { $handles[$index].mutex.ReleaseMutex() } catch {}
    try { $handles[$index].mutex.Dispose() } catch {}
  }
  $Lock | Add-Member `
    -MemberType NoteProperty `
    -Name released `
    -Value $true `
    -Force
}

function Enter-RimsFrontendPortLock {
  param(
    [ValidateRange(1, 65535)][int]$FrontendPort,
    [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000
  )

  $mutex = $null
  $ownsMutex = $false
  try {
    $mutex = New-Object Threading.Mutex($false, "Local\RimsLocal-frontend-port-$FrontendPort")
    try {
      $ownsMutex = $mutex.WaitOne($TimeoutMilliseconds)
    } catch [Threading.AbandonedMutexException] {
      $ownsMutex = $true
    }
    if (-not $ownsMutex) {
      $mutex.Dispose()
      return [pscustomobject][ordered]@{
        ok = $false
        busy = $true
        detail = "Another local frontend lifecycle command owns port $FrontendPort."
        mutex = $null
        released = $true
      }
    }
    return [pscustomobject][ordered]@{
      ok = $true
      busy = $false
      detail = "Acquired exclusive frontend-port lock for $FrontendPort."
      mutex = $mutex
      released = $false
    }
  } catch {
    if ($null -ne $mutex -and -not $ownsMutex) {
      $mutex.Dispose()
    }
    return [pscustomobject][ordered]@{
      ok = $false
      busy = $false
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
      mutex = $null
      released = $true
    }
  }
}

function Exit-RimsFrontendPortLock {
  param([AllowNull()][object]$Lock)

  if ($null -eq $Lock -or [bool](Get-RimsObjectPropertyValue `
      -Value $Lock -Name 'released' -DefaultValue $true)) {
    return
  }
  try { $Lock.mutex.ReleaseMutex() } catch {}
  try { $Lock.mutex.Dispose() } catch {}
  $Lock | Add-Member -MemberType NoteProperty -Name released -Value $true -Force
}
