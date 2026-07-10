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
