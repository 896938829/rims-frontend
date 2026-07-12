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
      backendWindows = [IO.Path]::GetFullPath($BackendDir)
      workspaceWindows = [IO.Path]::GetFullPath($BackendWorkspaceRoot)
      environmentWindows = [IO.Path]::GetFullPath(
        (Join-Path $BackendWorkspaceRoot '.env')
      )
      composeWindows = [IO.Path]::GetFullPath(
        (Join-Path $BackendWorkspaceRoot 'deploy\docker-compose.yml')
      )
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
      linuxIdentityFile = ConvertTo-RimsWslPath `
        -WindowsPath $RuntimePaths.linuxIdentity `
        -WslExecutable $wsl
      activationGate = ConvertTo-RimsWslPath `
        -WindowsPath $RuntimePaths.backendActivationGate `
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

function Get-RimsDotEnvParserScript {
  return @'
load_rims_dotenv() {
  local env_file=$1
  local line=''
  local line_number=0
  local key=''
  local value=''
  local first=''
  local last=''
  local length=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*$ ]] ||
       [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if ! [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      printf 'Malformed dotenv record at line %d.\n' "$line_number" >&2
      return 2
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ "$value" =~ [[:cntrl:]] ]]; then
      printf 'Control character in dotenv value at line %d.\n' "$line_number" >&2
      return 2
    fi
    length=${#value}
    if [ "$length" -gt 0 ]; then
      first=${value:0:1}
      last=${value:length-1:1}
      if [ "$first" = '"' ] || [ "$first" = "'" ]; then
        if [ "$length" -lt 2 ] || [ "$last" != "$first" ]; then
          printf 'Unmatched dotenv quote at line %d.\n' "$line_number" >&2
          return 2
        fi
        value=${value:1:length-2}
      fi
    fi
    export "$key=$value"
  done < "$env_file"
}
'@
}

function Get-RimsMigrationLaunchScript {
  return (Get-RimsDotEnvParserScript) + @'

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
load_rims_dotenv "$env_file"
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

function Invoke-RimsBackendLaunchStateMachine {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$State,
    [Parameter(Mandatory = $true)]
    [scriptblock]$PersistStateAction,
    [Parameter(Mandatory = $true)]
    [scriptblock]$SpawnAction,
    [Parameter(Mandatory = $true)]
    [scriptblock]$LinuxIdentityAction,
    [Parameter(Mandatory = $true)]
    [scriptblock]$ActivateAction,
    [Parameter(Mandatory = $true)]
    [scriptblock]$HealthAction
  )

  $State | Add-Member -MemberType NoteProperty `
    -Name lifecycleStage -Value 'launching' -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name healthy -Value $false -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name cleanupPending -Value $true -Force
  foreach ($propertyName in @(
      'windowsPid',
      'windowsProcessStartTimeUtc',
      'linuxProcessGroupId',
      'linuxIdentity'
    )) {
    $State | Add-Member -MemberType NoteProperty `
      -Name $propertyName -Value $null -Force
  }
  try {
    & $PersistStateAction $State
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'launchingPersistence'
      processStarted = $false
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }

  try {
    $spawned = & $SpawnAction
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'spawn'
      processStarted = $false
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $spawned `
      -Name 'ok' `
      -DefaultValue $false)) {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'spawn'
      processStarted = $false
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput ([string](Get-RimsObjectPropertyValue `
            -Value $spawned `
            -Name 'detail' `
            -DefaultValue 'Backend bootstrap did not start.')) `
        -StandardError ''
    }
  }

  try {
    $identityResult = & $LinuxIdentityAction $spawned
    $linuxIdentity = Get-RimsObjectPropertyValue `
      -Value $identityResult `
      -Name 'identity' `
      -DefaultValue $identityResult
    if ($null -eq $linuxIdentity) {
      throw 'Linux bootstrap identity was not available before activation.'
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'identity'
      processStarted = $true
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      windowsPid = Get-RimsObjectPropertyValue -Value $spawned -Name 'windowsPid'
      windowsProcessStartTimeUtc = Get-RimsObjectPropertyValue `
        -Value $spawned `
        -Name 'windowsProcessStartTimeUtc'
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }

  $State | Add-Member -MemberType NoteProperty `
    -Name windowsPid `
    -Value (Get-RimsObjectPropertyValue -Value $spawned -Name 'windowsPid') `
    -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name windowsProcessStartTimeUtc `
    -Value (Get-RimsObjectPropertyValue `
      -Value $spawned `
      -Name 'windowsProcessStartTimeUtc') `
    -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name linuxProcessGroupId `
    -Value (Get-RimsObjectPropertyValue `
      -Value $linuxIdentity `
      -Name 'processGroupId') `
    -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name linuxIdentity -Value $linuxIdentity -Force
  $State | Add-Member -MemberType NoteProperty `
    -Name lifecycleStage -Value 'starting' -Force
  try {
    & $PersistStateAction $State
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'startingPersistence'
      processStarted = $true
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      windowsPid = $State.windowsPid
      windowsProcessStartTimeUtc = $State.windowsProcessStartTimeUtc
      linuxProcessGroupId = $State.linuxProcessGroupId
      linuxIdentity = $State.linuxIdentity
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }

  $activationDetail = ''
  try {
    $activated = [bool](& $ActivateAction $State)
  } catch {
    $activated = $false
    $activationDetail = $_.Exception.Message
  }
  if (-not $activated) {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'activation'
      processStarted = $true
      ownershipPersisted = $true
      activationOpen = $false
      cleanupAllowed = $true
      windowsPid = $State.windowsPid
      windowsProcessStartTimeUtc = $State.windowsProcessStartTimeUtc
      linuxProcessGroupId = $State.linuxProcessGroupId
      linuxIdentity = $State.linuxIdentity
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $(if ([string]::IsNullOrWhiteSpace($activationDetail)) {
            'Backend activation gate could not be opened.'
          } else {
            $activationDetail
          })
    }
  }

  $healthDetail = ''
  try {
    $healthy = [bool](& $HealthAction $State)
  } catch {
    $healthy = $false
    $healthDetail = $_.Exception.Message
  }
  if (-not $healthy) {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'health'
      processStarted = $true
      ownershipPersisted = $true
      activationOpen = $true
      cleanupAllowed = $true
      windowsPid = $State.windowsPid
      windowsProcessStartTimeUtc = $State.windowsProcessStartTimeUtc
      linuxProcessGroupId = $State.linuxProcessGroupId
      linuxIdentity = $State.linuxIdentity
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $(if ([string]::IsNullOrWhiteSpace($healthDetail)) {
            'Activated backend did not become healthy within the bounded timeout.'
          } else {
            $healthDetail
          })
    }
  }

  return [pscustomobject][ordered]@{
    ok = $true
    phase = 'healthy'
    processStarted = $true
    ownershipPersisted = $true
    activationOpen = $true
    cleanupAllowed = $true
    windowsPid = $State.windowsPid
    windowsProcessStartTimeUtc = $State.windowsProcessStartTimeUtc
    linuxProcessGroupId = $State.linuxProcessGroupId
    linuxIdentity = $State.linuxIdentity
    detail = 'Managed backend passed gated activation and is healthy.'
  }
}


function Get-RimsBackendBootstrapScript {
  return (Get-RimsDotEnvParserScript) + @'

set -euo pipefail
env_file=$1
source_dir=$2
migrations_dir=$3
port=$4
pgid_file=$5
identity_file=$6
activation_gate=$7
command_marker=$8
load_rims_dotenv "$env_file"
export APP_PORT="$port"
export MIGRATIONS_DIR="$migrations_dir"
cd "$source_dir"
exec setsid --fork --wait bash -c '
  set -euo pipefail
  pgid_file=$1
  identity_file=$2
  activation_gate=$3
  command_marker=$4
  leader_pid=$$
  process_group_id=$(ps -o pgid= -p "$leader_pid" | tr -d "[:space:]")
  if [ "$process_group_id" != "$leader_pid" ]; then
    printf "Bootstrap did not become its process-group leader.\n" >&2
    exit 2
  fi
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  stat_line=$(cat "/proc/$leader_pid/stat")
  stat_tail=${stat_line##*) }
  set -- $stat_tail
  start_ticks=${20}
  umask 077
  identity_tmp="$identity_file.tmp.$$"
  printf "%s\n" "$process_group_id" > "$pgid_file"
  printf "{\"bootId\":\"%s\",\"leaderPid\":%s,\"startTicks\":\"%s\",\"processGroupId\":%s,\"commandMarker\":\"%s\"}\n" \
    "$boot_id" "$leader_pid" "$start_ticks" "$process_group_id" "$command_marker" \
    > "$identity_tmp"
  mv -f -- "$identity_tmp" "$identity_file"
  deadline=$((SECONDS + 30))
  while [ ! -f "$activation_gate" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf "Backend activation gate timed out.\n" >&2
      exit 124
    fi
    sleep 0.1
  done
  "$HOME/local/go/bin/go" run ./cmd/server &
  server_pid=$!
  trap "kill -TERM $server_pid 2>/dev/null || true" TERM INT
  wait "$server_pid"
' "rims-server-$command_marker" \
  "$pgid_file" "$identity_file" "$activation_gate" "$command_marker"
'@
}

function Wait-RimsBootstrapLinuxIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)]
    [string]$CommandMarker,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $Process.Refresh()
    if ($Process.HasExited) {
      throw 'Backend bootstrap exited before publishing Linux identity.'
    }
    if (Test-Path -LiteralPath $RuntimePaths.linuxIdentity -PathType Leaf) {
      try {
        $identity = [IO.File]::ReadAllText(
          [string]$RuntimePaths.linuxIdentity
        ) | ConvertFrom-Json -ErrorAction Stop
        if ([string](Get-RimsObjectPropertyValue `
            -Value $identity `
            -Name 'commandMarker' `
            -DefaultValue '') -ne $CommandMarker) {
          throw 'Bootstrap command marker did not match this launch.'
        }
        $current = Get-RimsCurrentLinuxProcessIdentity `
          -StoredIdentity $identity
        if (-not $current.ok -or -not $current.exists) {
          throw $current.detail
        }
        $match = Test-RimsLinuxProcessIdentity `
          -Stored $identity `
          -Current $current.identity
        if (-not $match.ok) {
          throw $match.detail
        }
        return $identity
      } catch {
        if ((Get-Date) -ge $deadline) {
          throw
        }
      }
    }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)
  throw 'Backend bootstrap did not publish Linux identity within the bounded timeout.'
}

function Open-RimsBackendActivationGate {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths
  )

  $temporaryGate = ([string]$RuntimePaths.backendActivationGate) +
    '.tmp.' + [guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText(
      $temporaryGate,
      'activate',
      (New-Object Text.UTF8Encoding($false))
    )
    [IO.File]::Move(
      $temporaryGate,
      [string]$RuntimePaths.backendActivationGate
    )
    return $true
  } finally {
    if (Test-Path -LiteralPath $temporaryGate -PathType Leaf) {
      [IO.File]::Delete($temporaryGate)
    }
  }
}

function Wait-RimsManagedBackendHealth {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)]
    [string]$HealthUrl,
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $Process.Refresh()
    if ($Process.HasExited) {
      return $false
    }
    if (Test-RimsHealthEndpoint -Url $HealthUrl -TimeoutSeconds 2) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Start-RimsManagedBackend {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Context,
    [Parameter(Mandatory = $true)]
    [psobject]$RuntimePaths,
    [Parameter(Mandatory = $true)]
    [int]$BackendPort,
    [Parameter(Mandatory = $true)]
    [psobject]$State
  )

  Initialize-RimsRuntimeDirectories -Paths $RuntimePaths
  $commandMarker = 'rims-local-' + [guid]::NewGuid().ToString('N')
  $healthUrl = "http://localhost:$BackendPort/healthz"
  $State | Add-Member -MemberType NoteProperty `
    -Name healthUrl -Value $healthUrl -Force
  $processHolder = [pscustomobject]@{ process = $null }
  try {
    $launchResult = Invoke-RimsBackendLaunchStateMachine `
      -State $State `
      -PersistStateAction {
        param([psobject]$LaunchState)
        Write-RimsRuntimeState -Paths $RuntimePaths -State $LaunchState
      } `
      -SpawnAction {
        foreach ($path in @(
            [string]$RuntimePaths.stdoutLog,
            [string]$RuntimePaths.stderrLog,
            [string]$RuntimePaths.linuxProcessGroup,
            [string]$RuntimePaths.linuxIdentity,
            [string]$RuntimePaths.backendActivationGate
          )) {
          if (Test-Path -LiteralPath $path -PathType Leaf) {
            [IO.File]::Delete($path)
          }
        }
        $arguments = @(
          '-e',
          'bash',
          '-c',
          (Get-RimsBackendBootstrapScript),
          'rims-backend-launch',
          $Context.environment,
          $Context.backend,
          $Context.migrations,
          [string]$BackendPort,
          $Context.processGroupFile,
          $Context.linuxIdentityFile,
          $Context.activationGate,
          $commandMarker
        )
        $effectiveArguments = @(ConvertTo-RimsWslBashArguments `
            -FilePath $Context.wsl `
            -Arguments $arguments)
        $argumentLine = ($effectiveArguments | ForEach-Object {
            ConvertTo-RimsWindowsCommandLineArgument -Value $_
          }) -join ' '
        $spawnedProcess = Start-Process `
          -FilePath $Context.wsl `
          -ArgumentList $argumentLine `
          -WindowStyle Hidden `
          -PassThru `
          -RedirectStandardOutput $RuntimePaths.stdoutLog `
          -RedirectStandardError $RuntimePaths.stderrLog
        $processHolder.process = $spawnedProcess
        return [pscustomobject][ordered]@{
          ok = $true
          process = $spawnedProcess
          windowsPid = $spawnedProcess.Id
          windowsProcessStartTimeUtc = $spawnedProcess.StartTime.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
          )
        }
      } `
      -LinuxIdentityAction {
        param([psobject]$Spawned)
        return Wait-RimsBootstrapLinuxIdentity `
          -RuntimePaths $RuntimePaths `
          -Process $Spawned.process `
          -CommandMarker $commandMarker
      } `
      -ActivateAction {
        param([psobject]$LaunchState)
        return Open-RimsBackendActivationGate -RuntimePaths $RuntimePaths
      } `
      -HealthAction {
        param([psobject]$LaunchState)
        return Wait-RimsManagedBackendHealth `
          -Process $processHolder.process `
          -HealthUrl $healthUrl
      }
    $launchResult | Add-Member -MemberType NoteProperty `
      -Name healthUrl -Value $healthUrl -Force
    if (-not $launchResult.ok -and $launchResult.phase -eq 'health') {
      $stderrTail = @(Get-RimsSanitizedLogTail `
          -Path $RuntimePaths.stderrLog `
          -MaximumLines 20)
      if ($stderrTail.Count -gt 0) {
        $launchResult.detail = ConvertTo-RimsDiagnosticSummary `
          -StandardOutput ($launchResult.detail + ' ' + ($stderrTail -join ' | ')) `
          -StandardError ''
      }
    }
    return $launchResult
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      phase = 'launcher'
      processStarted = $null -ne $processHolder.process
      ownershipPersisted = $false
      activationOpen = $false
      cleanupAllowed = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
      healthUrl = $healthUrl
      windowsPid = if ($null -ne $processHolder.process) {
        $processHolder.process.Id
      } else {
        $null
      }
      windowsProcessStartTimeUtc = $null
      linuxProcessGroupId = $null
      linuxIdentity = $null
    }
  } finally {
    if ($null -ne $processHolder.process) {
      $processHolder.process.Dispose()
    }
  }
}
