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

function Test-RimsStateOwnsLinuxProcess {
  param(
    [AllowNull()]
    [object]$State
  )

  $linuxIdentity = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'linuxIdentity'
  if ($null -eq $linuxIdentity) {
    return $false
  }
  $current = Get-RimsCurrentLinuxProcessIdentity `
    -StoredIdentity $linuxIdentity
  if (-not $current.ok -or -not $current.exists) {
    return $false
  }
  return (Test-RimsLinuxProcessIdentity `
      -Stored $linuxIdentity `
      -Current $current.identity).ok
}

function Test-RimsStateOwnsAnyBackendProcess {
  param(
    [AllowNull()]
    [object]$State,
    [AllowNull()]
    [scriptblock]$LinuxOwnershipAction
  )

  if (Test-RimsStateOwnsProcess -State $State) {
    return $true
  }
  if ($null -eq (Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'linuxIdentity')) {
    return $false
  }
  try {
    $owned = if ($null -eq $LinuxOwnershipAction) {
      Test-RimsStateOwnsLinuxProcess -State $State
    } else {
      [bool](& $LinuxOwnershipAction $State)
    }
    return [bool]$owned
  } catch {
    return $false
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

function Test-RimsLinuxProcessIdentity {
  param(
    [AllowNull()]
    [object]$Stored,
    [AllowNull()]
    [object]$Current
  )

  if ($null -eq $Stored -or $null -eq $Current) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = 'Stored or current Linux process identity is missing.'
    }
  }
  foreach ($propertyName in @(
      'bootId',
      'leaderPid',
      'startTicks',
      'processGroupId',
      'commandMarker'
    )) {
    $storedValue = [string](Get-RimsObjectPropertyValue `
        -Value $Stored `
        -Name $propertyName `
        -DefaultValue '')
    $currentValue = [string](Get-RimsObjectPropertyValue `
        -Value $Current `
        -Name $propertyName `
        -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($storedValue) -or
        -not $storedValue.Equals(
          $currentValue,
          [StringComparison]::Ordinal
        )) {
      return [pscustomobject][ordered]@{
        ok = $false
        detail = "Linux process identity mismatch: $propertyName."
      }
    }
  }
  return [pscustomobject][ordered]@{
    ok = $true
    detail = 'Linux process identity exactly matches controller state.'
  }
}

function Get-RimsCurrentLinuxProcessIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$StoredIdentity
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $false
      identity = $null
      detail = 'wsl.exe is unavailable for Linux identity verification.'
    }
  }
  $leaderPid = [string](Get-RimsObjectPropertyValue `
      -Value $StoredIdentity `
      -Name 'leaderPid' `
      -DefaultValue '')
  $commandMarker = [string](Get-RimsObjectPropertyValue `
      -Value $StoredIdentity `
      -Name 'commandMarker' `
      -DefaultValue '')
  $script = @'
set -euo pipefail
pid=$1
marker=$2
case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
if [ ! -r "/proc/$pid/stat" ]; then
  exit 3
fi
boot_id=$(cat /proc/sys/kernel/random/boot_id)
stat_line=$(cat "/proc/$pid/stat")
stat_tail=${stat_line##*) }
set -- $stat_tail
start_ticks=${20}
pgid=$(ps -o pgid= -p "$pid" | tr -d '[:space:]')
command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
marker_match=0
case "$command_line" in *"$marker"*) marker_match=1 ;; esac
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$boot_id" "$pid" "$start_ticks" "$pgid" "$marker_match"
'@
  $result = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(
      '-e',
      'bash',
      '-c',
      $script,
      'rims-linux-identity',
      $leaderPid,
      $commandMarker
    ) `
    -TimeoutSeconds 10
  if ($result.ExitCode -eq 3) {
    return [pscustomobject][ordered]@{
      ok = $true
      exists = $false
      identity = $null
      detail = 'Recorded Linux process group leader is absent.'
    }
  }
  if ($result.ExitCode -ne 0) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $false
      identity = $null
      detail = "Could not verify Linux process identity: $(Get-RimsExternalCommandSummary -Result $result)"
    }
  }
  $lines = @($result.StandardOutput -split '\r?\n' | Where-Object {
      $_.Length -gt 0
    })
  if ($lines.Count -ne 5) {
    return [pscustomobject][ordered]@{
      ok = $false
      exists = $true
      identity = $null
      detail = 'Linux process identity probe returned malformed metadata.'
    }
  }
  return [pscustomobject][ordered]@{
    ok = $true
    exists = $true
    identity = [pscustomobject][ordered]@{
      bootId = $lines[0]
      leaderPid = [int]$lines[1]
      startTicks = $lines[2]
      processGroupId = [int]$lines[3]
      commandMarker = if ($lines[4] -eq '1') { $commandMarker } else { '' }
    }
    detail = 'Read current Linux process identity.'
  }
}

function Invoke-RimsOwnedLinuxGroupSignal {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$StoredIdentity,
    [ValidateSet('TERM', 'KILL')]
    [string]$Signal = 'TERM',
    [AllowNull()]
    [scriptblock]$IdentityReaderAction,
    [AllowNull()]
    [scriptblock]$SignalAction
  )

  try {
    $current = if ($null -eq $IdentityReaderAction) {
      Get-RimsCurrentLinuxProcessIdentity -StoredIdentity $StoredIdentity
    } else {
      & $IdentityReaderAction $StoredIdentity
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      attempted = $false
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $current `
      -Name 'ok' `
      -DefaultValue $false)) {
    return [pscustomobject][ordered]@{
      ok = $false
      attempted = $false
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput ([string](Get-RimsObjectPropertyValue `
            -Value $current `
            -Name 'detail' `
            -DefaultValue 'Could not verify Linux process identity.')) `
        -StandardError ''
    }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $current `
      -Name 'exists' `
      -DefaultValue $false)) {
    return [pscustomobject][ordered]@{
      ok = $true
      attempted = $false
      cleanupPending = $false
      detail = 'Recorded Linux process group leader is already absent.'
    }
  }
  $identityMatch = Test-RimsLinuxProcessIdentity `
    -Stored $StoredIdentity `
    -Current (Get-RimsObjectPropertyValue -Value $current -Name 'identity')
  if (-not $identityMatch.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      attempted = $false
      cleanupPending = $true
      detail = $identityMatch.detail
    }
  }
  $processGroupId = [int](Get-RimsObjectPropertyValue `
      -Value $StoredIdentity `
      -Name 'processGroupId' `
      -DefaultValue 0)
  try {
    $signaled = if ($null -eq $SignalAction) {
      Invoke-RimsLinuxProcessGroupSignal `
        -ProcessGroupId $processGroupId `
        -Signal $Signal
    } else {
      [bool](& $SignalAction $processGroupId $Signal)
    }
    return [pscustomobject][ordered]@{
      ok = $signaled
      attempted = $true
      cleanupPending = -not $signaled
      detail = if ($signaled) {
        "Sent $Signal only to the exactly verified Linux process group."
      } else {
        "Could not send $Signal to the exactly verified Linux process group."
      }
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      attempted = $true
      cleanupPending = $true
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
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

function Wait-RimsLinuxProcessExit {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$StoredIdentity,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $current = Get-RimsCurrentLinuxProcessIdentity `
      -StoredIdentity $StoredIdentity
    if ($current.ok -and -not $current.exists) {
      return $true
    }
    if ($current.ok -and $current.exists) {
      $match = Test-RimsLinuxProcessIdentity `
        -Stored $StoredIdentity `
        -Current $current.identity
      if (-not $match.ok) {
        return $false
      }
    }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-RimsOwnedBackendProcess {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [AllowNull()]
    [scriptblock]$LinuxSignalAction,
    [AllowNull()]
    [scriptblock]$LinuxExitAction
  )

  $process = Get-RimsOwnedProcess -State $State
  $windowsOwned = $null -ne $process
  if ($windowsOwned) {
    $process.Dispose()
  }

  $linuxIdentity = Get-RimsObjectPropertyValue `
    -Value $State `
    -Name 'linuxIdentity'
  if ($null -ne $linuxIdentity) {
    $term = if ($null -eq $LinuxSignalAction) {
      Invoke-RimsOwnedLinuxGroupSignal `
        -StoredIdentity $linuxIdentity `
        -Signal 'TERM'
    } else {
      & $LinuxSignalAction $linuxIdentity 'TERM'
    }
    if (-not [bool](Get-RimsObjectPropertyValue `
        -Value $term `
        -Name 'ok' `
        -DefaultValue $term)) {
      return $false
    }
    $linuxExited = if ($null -eq $LinuxExitAction) {
      Wait-RimsLinuxProcessExit `
        -StoredIdentity $linuxIdentity `
        -TimeoutSeconds 10
    } else {
      [bool](& $LinuxExitAction $linuxIdentity 10)
    }
    $windowsExited = Wait-RimsOwnedProcessExit `
      -State $State `
      -TimeoutSeconds 10
    if ($linuxExited -and $windowsExited) {
      return $true
    }
    $kill = if ($null -eq $LinuxSignalAction) {
      Invoke-RimsOwnedLinuxGroupSignal `
        -StoredIdentity $linuxIdentity `
        -Signal 'KILL'
    } else {
      & $LinuxSignalAction $linuxIdentity 'KILL'
    }
    if (-not [bool](Get-RimsObjectPropertyValue `
        -Value $kill `
        -Name 'ok' `
        -DefaultValue $kill)) {
      return $false
    }
    $linuxExited = if ($null -eq $LinuxExitAction) {
      Wait-RimsLinuxProcessExit `
        -StoredIdentity $linuxIdentity `
        -TimeoutSeconds 3
    } else {
      [bool](& $LinuxExitAction $linuxIdentity 3)
    }
    $windowsExited = Wait-RimsOwnedProcessExit `
      -State $State `
      -TimeoutSeconds 3
    if ($linuxExited -and $windowsExited) {
      return $true
    }
  }

  if (-not $windowsOwned) {
    return $null -eq $linuxIdentity
  }

  $ownedProcess = Get-RimsOwnedProcess -State $State
  if ($null -ne $ownedProcess) {
    Stop-RimsProcessTree -Process $ownedProcess
    $ownedProcess.Dispose()
  }
  return Wait-RimsOwnedProcessExit -State $State -TimeoutSeconds 5
}
