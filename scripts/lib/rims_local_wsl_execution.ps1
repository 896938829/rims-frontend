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
