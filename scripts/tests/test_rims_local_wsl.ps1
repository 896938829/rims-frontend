$dotenvRoot = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-dotenv-' + [guid]::NewGuid().ToString('N'))
$dotenvPath = Join-Path $dotenvRoot '.env'
$malformedDotenvPath = Join-Path $dotenvRoot 'malformed.env'
$executionMarker = Join-Path $dotenvRoot 'must-not-execute'
try {
  [void][IO.Directory]::CreateDirectory($dotenvRoot)
  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    throw 'WSL is required for dotenv parser behavior tests.'
  }
  $bootstrapScript = Get-RimsBackendBootstrapScript
  foreach ($requiredBootstrapLine in @(
      'upload_dir=$9',
      'export UPLOAD_DIR="$upload_dir"',
      'export MAX_UPLOAD_MB=10',
      'export MAX_ATTACHMENTS_PER_OBJECT=9'
    )) {
    if (-not $bootstrapScript.Contains($requiredBootstrapLine)) {
      throw "Backend bootstrap omitted attachment setting '$requiredBootstrapLine'."
    }
  }
  $normalizedArguments = ConvertTo-RimsWslBashArguments `
    -FilePath $wsl `
    -Arguments @('-e', 'bash', '-c', "first`r`nsecond", "literal`r`nvalue")
  Assert-Equal `
    -Actual $normalizedArguments[3] `
    -Expected "first`nsecond" `
    -Message 'WSL Bash command argument retained Windows line endings.'
  Assert-Equal `
    -Actual $normalizedArguments[4] `
    -Expected "literal`r`nvalue" `
    -Message 'WSL argument normalization changed a non-command argument.'
  $dotenvWsl = ConvertTo-RimsWslPath `
    -WindowsPath $dotenvPath `
    -WslExecutable $wsl
  $malformedDotenvWsl = ConvertTo-RimsWslPath `
    -WindowsPath $malformedDotenvPath `
    -WslExecutable $wsl
  $markerWsl = ConvertTo-RimsWslPath `
    -WindowsPath $executionMarker `
    -WslExecutable $wsl
  $dotenvContent = @"
# comment
PLAIN=value
DOLLAR=`$(touch '$markerWsl')
BACKTICK=``touch '$markerWsl'``
SEMICOLON=value; touch '$markerWsl'
SPACES="hello world"
HASH=value#literal
SINGLE='quoted value'
"@
  [IO.File]::WriteAllText(
    $dotenvPath,
    $dotenvContent,
    (New-Object Text.UTF8Encoding($false))
  )
  [IO.File]::WriteAllText(
    $malformedDotenvPath,
    "GOOD=value`nMALFORMED LINE`nDB_PASSWORD=must-not-leak",
    (New-Object Text.UTF8Encoding($false))
  )

  $dotenvParser = Get-RimsDotEnvParserScript
  $probeScript = $dotenvParser + @'

set -euo pipefail
load_rims_dotenv "$1"
printf 'PLAIN=%s\n' "$PLAIN"
printf 'DOLLAR=%s\n' "$DOLLAR"
printf 'BACKTICK=%s\n' "$BACKTICK"
printf 'SEMICOLON=%s\n' "$SEMICOLON"
printf 'SPACES=%s\n' "$SPACES"
printf 'HASH=%s\n' "$HASH"
printf 'SINGLE=%s\n' "$SINGLE"
'@
  $probe = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @('-e', 'bash', '-c', $probeScript, 'rims-dotenv-test', $dotenvWsl) `
    -TimeoutSeconds 10
  Assert-Equal `
    -Actual $probe.ExitCode `
    -Expected 0 `
    -Message 'Safe dotenv parser rejected supported literal values.'
  foreach ($expectedLiteral in @(
      'PLAIN=value',
      "DOLLAR=`$(touch '$markerWsl')",
      "BACKTICK=``touch '$markerWsl'``",
      "SEMICOLON=value; touch '$markerWsl'",
      'SPACES=hello world',
      'HASH=value#literal',
      'SINGLE=quoted value'
    )) {
    if (-not $probe.StandardOutput.Contains($expectedLiteral)) {
      throw "Safe dotenv parser changed literal value '$expectedLiteral'."
    }
  }
  Assert-False `
    -Value (Test-Path -LiteralPath $executionMarker) `
    -Message 'Dotenv value syntax executed as shell code.'

  $malformedProbe = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(
      '-e',
      'bash',
      '-c',
      ($dotenvParser + "`nset -euo pipefail`nload_rims_dotenv `"`$1`""),
      'rims-dotenv-test',
      $malformedDotenvWsl
    ) `
    -TimeoutSeconds 10
  Assert-NotEqual `
    -Actual $malformedProbe.ExitCode `
    -Expected 0 `
    -Message 'Safe dotenv parser accepted a malformed record.'
  $malformedSummary = Get-RimsExternalCommandSummary -Result $malformedProbe
  if ($malformedSummary.Contains('must-not-leak')) {
    throw 'Malformed dotenv failure leaked a later secret value.'
  }
} finally {
  Remove-Item `
    -LiteralPath $dotenvRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
}

function New-TestLinuxProcessIdentity {
  param(
    [string]$BootId = 'boot-id-a',
    [int]$LeaderPid = 4201,
    [string]$StartTicks = '123456',
    [int]$ProcessGroupId = 4201,
    [string]$CommandMarker = 'rims-marker-a'
  )

  return [pscustomobject][ordered]@{
    bootId = $BootId
    leaderPid = $LeaderPid
    startTicks = $StartTicks
    processGroupId = $ProcessGroupId
    commandMarker = $CommandMarker
  }
}

$storedLinuxIdentity = New-TestLinuxProcessIdentity
$signalCalls = New-Object 'Collections.Generic.List[string]'
$matchingSignal = Invoke-RimsOwnedLinuxGroupSignal `
  -StoredIdentity $storedLinuxIdentity `
  -Signal 'TERM' `
  -IdentityReaderAction {
    param([psobject]$StoredIdentity)
    return [pscustomobject]@{
      ok = $true
      exists = $true
      identity = New-TestLinuxProcessIdentity
      detail = 'Matching Linux process identity.'
    }
  } `
  -SignalAction {
    param([int]$ProcessGroupId, [string]$Signal)
    [void]$signalCalls.Add("$ProcessGroupId`:$Signal")
    return $true
  }
Assert-True `
  -Value $matchingSignal.ok `
  -Message 'Matching Linux process identity was not signaled.'
Assert-Equal `
  -Actual ($signalCalls -join '|') `
  -Expected '4201:TERM' `
  -Message 'Linux signal did not target the exactly verified process group.'

$linuxIdentityMismatches = @(
  [pscustomobject]@{
    name = 'boot ID change'
    identity = New-TestLinuxProcessIdentity -BootId 'boot-id-b'
  },
  [pscustomobject]@{
    name = 'leader PID change'
    identity = New-TestLinuxProcessIdentity -LeaderPid 4202
  },
  [pscustomobject]@{
    name = 'start tick change'
    identity = New-TestLinuxProcessIdentity -StartTicks '123457'
  },
  [pscustomobject]@{
    name = 'PGID reuse'
    identity = New-TestLinuxProcessIdentity -ProcessGroupId 4202
  },
  [pscustomobject]@{
    name = 'command marker change'
    identity = New-TestLinuxProcessIdentity -CommandMarker 'replacement-marker'
  }
)
foreach ($linuxMismatch in $linuxIdentityMismatches) {
  $signalCalls.Clear()
  $currentLinuxIdentity = $linuxMismatch.identity
  $mismatchSignal = Invoke-RimsOwnedLinuxGroupSignal `
    -StoredIdentity $storedLinuxIdentity `
    -Signal 'KILL' `
    -IdentityReaderAction {
      param([psobject]$StoredIdentity)
      return [pscustomobject]@{
        ok = $true
        exists = $true
        identity = $currentLinuxIdentity
        detail = 'Changed Linux process identity.'
      }
    } `
    -SignalAction {
      param([int]$ProcessGroupId, [string]$Signal)
      [void]$signalCalls.Add("$ProcessGroupId`:$Signal")
      return $true
    }
  Assert-False `
    -Value $mismatchSignal.ok `
    -Message "Linux signal accepted $($linuxMismatch.name)."
  Assert-True `
    -Value $mismatchSignal.cleanupPending `
    -Message "Linux identity mismatch did not retain cleanup for $($linuxMismatch.name)."
  Assert-Equal `
    -Actual $signalCalls.Count `
    -Expected 0 `
    -Message "Linux signal ran after $($linuxMismatch.name)."
}

$linuxOnlyState = [pscustomobject][ordered]@{
  windowsPid = $null
  windowsProcessStartTimeUtc = $null
  linuxProcessGroupId = 4201
  linuxIdentity = New-TestLinuxProcessIdentity
}
$linuxOnlySignals = New-Object 'Collections.Generic.List[string]'
$linuxOnlyStopped = Stop-RimsOwnedBackendProcess `
  -State $linuxOnlyState `
  -LinuxSignalAction {
    param([psobject]$StoredIdentity, [string]$Signal)
    [void]$linuxOnlySignals.Add($Signal)
    return [pscustomobject]@{ ok = $true; detail = 'Injected exact signal.' }
  } `
  -LinuxExitAction {
    param([psobject]$StoredIdentity, [int]$TimeoutSeconds)
    return $true
  }
Assert-True `
  -Value $linuxOnlyStopped `
  -Message 'Linux-only durable ownership could not be cleaned up.'
Assert-Equal `
  -Actual ($linuxOnlySignals -join '|') `
  -Expected 'TERM' `
  -Message 'Absent Windows proxy bypassed exact Linux cleanup.'

$linuxOnlyOwned = Test-RimsStateOwnsAnyBackendProcess `
  -State $linuxOnlyState `
  -LinuxOwnershipAction {
    param([psobject]$State)
    return $true
  }
Assert-True `
  -Value $linuxOnlyOwned `
  -Message 'Lifecycle ownership ignored an exactly owned Linux-only process.'
