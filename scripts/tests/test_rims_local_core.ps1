$testPowerShellExecutable = (Get-Process -Id $PID).Path
$timeoutScript = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-timeout-' + [guid]::NewGuid().ToString('N') + '.ps1')
$timeoutMarker = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-timeout-pids-' + [guid]::NewGuid().ToString('N') + '.txt')
$trackedTimeoutPids = @()
try {
  [IO.File]::WriteAllText(
    $timeoutScript,
    @'
param([string]$MarkerPath)
$child = Start-Process `
  -FilePath (Get-Process -Id $PID).Path `
  -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
  -WindowStyle Hidden `
  -PassThru
[IO.File]::WriteAllLines(
  $MarkerPath,
  @([string]$PID, [string]$child.Id)
)
Start-Sleep -Seconds 30
'@
  )
  $timeoutStopwatch = [Diagnostics.Stopwatch]::StartNew()
  $timeoutResult = Invoke-RimsExternalCommand `
    -FilePath $testPowerShellExecutable `
    -Arguments @('-NoProfile', '-File', $timeoutScript, $timeoutMarker) `
    -TimeoutSeconds 2
  $timeoutStopwatch.Stop()
  Assert-Equal `
    -Actual $timeoutResult.ExitCode `
    -Expected 124 `
    -Message 'Timed-out native command returned the wrong exit code.'
  Assert-Equal `
    -Actual $timeoutResult.TimedOut `
    -Expected $true `
    -Message 'Timed-out native command omitted its timeout state.'
  if ($timeoutStopwatch.Elapsed.TotalSeconds -ge 10) {
    throw 'Native command timeout did not return promptly.'
  }
  $trackedTimeoutPids += $timeoutResult.ProcessId
  if (-not (Test-Path -LiteralPath $timeoutMarker -PathType Leaf)) {
    throw 'Timeout probe did not record its process tree.'
  }
  $recordedTimeoutPids = @([IO.File]::ReadAllLines($timeoutMarker))
  Assert-Equal `
    -Actual $recordedTimeoutPids.Count `
    -Expected 2 `
    -Message 'Timeout probe did not record parent and descendant PIDs.'
  $trackedTimeoutPids += $recordedTimeoutPids
  foreach ($trackedPid in @($trackedTimeoutPids | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace([string]$trackedPid)) {
      continue
    }
    $processDeadline = (Get-Date).AddSeconds(3)
    do {
      $trackedProcess = Get-Process `
        -Id ([int]$trackedPid) `
        -ErrorAction SilentlyContinue
      if ($null -eq $trackedProcess) {
        break
      }
      Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $processDeadline)
    if ($null -ne $trackedProcess) {
      throw "Timed-out native command left process $trackedPid alive."
    }
  }
} finally {
  foreach ($trackedPid in @($trackedTimeoutPids | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$trackedPid)) {
      Stop-Process `
        -Id ([int]$trackedPid) `
        -Force `
        -ErrorAction SilentlyContinue
    }
  }
  [IO.File]::Delete($timeoutScript)
  [IO.File]::Delete($timeoutMarker)
}

$argumentProbeScript = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-arguments-' + [guid]::NewGuid().ToString('N') + '.ps1')
$argumentProbeValue = 'C:\RIMS Backend\api & tool''s "quoted" trailing\'
try {
  [IO.File]::WriteAllText(
    $argumentProbeScript,
    @'
param([string]$Value)
[Console]::Out.Write($Value)
[Console]::Error.Write('stderr-marker')
'@
  )
  $argumentProbe = Invoke-RimsExternalCommand `
    -FilePath $testPowerShellExecutable `
    -Arguments @(
      '-NoProfile',
      '-File',
      $argumentProbeScript,
      $argumentProbeValue
    )
  Assert-Equal `
    -Actual $argumentProbe.ExitCode `
    -Expected 0 `
    -Message 'Native argument round-trip command failed.'
  Assert-False `
    -Value $argumentProbe.TimedOut `
    -Message 'Native argument round-trip unexpectedly timed out.'
  Assert-Equal `
    -Actual $argumentProbe.StandardOutput `
    -Expected $argumentProbeValue `
    -Message 'Native argument quoting changed the argument value.'
  Assert-Equal `
    -Actual $argumentProbe.StandardError `
    -Expected 'stderr-marker' `
    -Message 'Native command did not preserve stderr separately.'
} finally {
  [IO.File]::Delete($argumentProbeScript)
}

$sensitiveDiagnostic = @"

Connection failed $([char]1) PASSWORD=hunter2 token=eyJhbGciOiJIUzI1NiJ9.payload.signature SECRET: super-secret Authorization: Bearer auth-value DB_PASSWORD=db-password-value POSTGRES_PASSWORD=postgres-password-value ACCESS_TOKEN=access-token-value JWT_SECRET=jwt-secret-value API_KEY=api-key-value SERVICE_AUTHORIZATION=Bearer service-auth-value https://uri-user:uri-password@example.com/path
SECOND-LINE-MUST-NOT-APPEAR
"@
$sanitizedDiagnostic = ConvertTo-RimsDiagnosticSummary `
  -StandardOutput $sensitiveDiagnostic `
  -StandardError 'stderr fallback SECRET=stderr-secret'
if (-not $sanitizedDiagnostic.Contains('Connection failed')) {
  throw 'Diagnostic sanitizer removed useful context.'
}
if (-not $sanitizedDiagnostic.Contains('example.com/path')) {
  throw 'Diagnostic sanitizer removed the useful URI destination.'
}
foreach ($sensitiveValue in @(
    'hunter2',
    'eyJhbGciOiJIUzI1NiJ9.payload.signature',
    'super-secret',
    'auth-value',
    'db-password-value',
    'postgres-password-value',
    'access-token-value',
    'jwt-secret-value',
    'api-key-value',
    'service-auth-value',
    'uri-user',
    'uri-password',
    'stderr-secret',
    'SECOND-LINE-MUST-NOT-APPEAR'
  )) {
  if ($sanitizedDiagnostic.Contains($sensitiveValue)) {
    throw "Diagnostic sanitizer leaked '$sensitiveValue'."
  }
}
if ($sanitizedDiagnostic.IndexOf([char]1) -ge 0) {
  throw 'Diagnostic sanitizer retained a control character.'
}
$longDiagnostic = ConvertTo-RimsDiagnosticSummary `
  -StandardOutput ('x' * 600) `
  -StandardError ''
Assert-Equal `
  -Actual $longDiagnostic.Length `
  -Expected 512 `
  -Message 'Diagnostic sanitizer did not cap summary length.'

$sensitiveProbeScript = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-sensitive-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
  [IO.File]::WriteAllText(
    $sensitiveProbeScript,
    @'
[Console]::Error.WriteLine('Probe failed PASSWORD=component-secret')
exit 7
'@
  )
  $sensitiveComponent = Test-RimsVersionedCommandComponent `
    -Name 'sensitiveProbe' `
    -FilePath $testPowerShellExecutable `
    -Arguments @('-NoProfile', '-File', $sensitiveProbeScript) `
    -MissingRemediation 'Repair the sensitive probe.'
  Assert-False `
    -Value $sensitiveComponent.ok `
    -Message 'Sensitive component probe unexpectedly passed.'
  if (-not $sensitiveComponent.detail.Contains('Probe failed')) {
    throw 'Component detail omitted useful sanitized context.'
  }
  if ($sensitiveComponent.detail.Contains('component-secret')) {
    throw 'Component detail leaked raw command output.'
  }
} finally {
  [IO.File]::Delete($sensitiveProbeScript)
}

$nulPathResolution = Resolve-RimsNormalizedPath `
  -Path ("C:\bad$([char]0)path")
Assert-False `
  -Value $nulPathResolution.success `
  -Message 'Path normalizer accepted an embedded NUL.'
if ([string]::IsNullOrWhiteSpace($nulPathResolution.error)) {
  throw 'Path normalizer omitted the embedded-NUL error.'
}
$malformedBackendPath = 'C:\bad|backend'
$malformedRuntimePath = 'C:\bad|runtime'
$malformedPathResolution = Resolve-RimsNormalizedPath `
  -Path $malformedBackendPath
Assert-False `
  -Value $malformedPathResolution.success `
  -Message 'Path normalizer accepted a malformed Windows path.'
if ([string]::IsNullOrWhiteSpace($malformedPathResolution.error)) {
  throw 'Path normalizer omitted the malformed-path error.'
}

$malformedPathDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'web',
  '-Output',
  'Json',
  '-BackendDir',
  $malformedBackendPath,
  '-BackendWorkspaceRoot',
  $malformedRuntimePath
)
Assert-Equal `
  -Actual $malformedPathDoctor.ExitCode `
  -Expected 1 `
  -Message 'Malformed backend paths did not produce component failures.'
Assert-Equal `
  -Actual $malformedPathDoctor.StandardError `
  -Expected '' `
  -Message 'Malformed backend path doctor wrote to stderr.'
$malformedPathResult = ConvertFrom-SingleJson `
  -Text $malformedPathDoctor.StandardOutput `
  -Context 'Malformed backend path JSON doctor'
Assert-ComponentFailed `
  -Result $malformedPathResult `
  -Name 'backendWorkspace'
Assert-ComponentFailed `
  -Result $malformedPathResult `
  -Name 'workspaceEnv'
Assert-ComponentSuccess `
  -Result $malformedPathResult `
  -Name 'powershell'
Assert-Equal `
  -Actual @($malformedPathResult.errors).Count `
  -Expected 0 `
  -Message 'Malformed backend paths became an internal doctor error.'

$originalAndroidSdkRoot = [Environment]::GetEnvironmentVariable(
  'ANDROID_SDK_ROOT',
  'Process'
)
$originalAndroidHome = [Environment]::GetEnvironmentVariable(
  'ANDROID_HOME',
  'Process'
)
try {
  [Environment]::SetEnvironmentVariable(
    'ANDROID_SDK_ROOT',
    'C:\bad|android-sdk',
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'ANDROID_HOME',
    $null,
    'Process'
  )
  $malformedAndroidDoctor = Invoke-LocalCli -Arguments @(
    '-Command',
    'doctor',
    '-Target',
    'android',
    '-Output',
    'Json',
    '-BackendDir',
    'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect',
    '-BackendWorkspaceRoot',
    'E:\My Work\RIMS',
    '-AndroidDevice',
    'Missing_Malformed_Path_Device'
  )
  Assert-Equal `
    -Actual $malformedAndroidDoctor.ExitCode `
    -Expected 1 `
    -Message 'Malformed Android SDK root did not produce component failures.'
  Assert-Equal `
    -Actual $malformedAndroidDoctor.StandardError `
    -Expected '' `
    -Message 'Malformed Android SDK doctor wrote to stderr.'
  $malformedAndroidResult = ConvertFrom-SingleJson `
    -Text $malformedAndroidDoctor.StandardOutput `
    -Context 'Malformed Android SDK JSON doctor'
  Assert-ComponentFailed `
    -Result $malformedAndroidResult `
    -Name 'emulator'
  Assert-ComponentFailed `
    -Result $malformedAndroidResult `
    -Name 'androidDevice'
  Assert-ComponentSuccess `
    -Result $malformedAndroidResult `
    -Name 'powershell'
  Assert-Equal `
    -Actual @($malformedAndroidResult.errors).Count `
    -Expected 0 `
    -Message 'Malformed Android SDK root became an internal doctor error.'
} finally {
  [Environment]::SetEnvironmentVariable(
    'ANDROID_SDK_ROOT',
    $originalAndroidSdkRoot,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'ANDROID_HOME',
    $originalAndroidHome,
    'Process'
  )
}

$avdParserOutput = @'
INFO emulator startup
[WARNING] package metadata is stale
ERROR: diagnostic line
Medium_Phone_API_36.1
'@
$parsedAvds = @(ConvertFrom-RimsAndroidAvdOutput `
    -StandardOutput $avdParserOutput `
    -ExitCode 0)
Assert-Equal `
  -Actual ($parsedAvds -join '|') `
  -Expected 'Medium_Phone_API_36.1' `
  -Message 'AVD parser selected an emulator diagnostic line.'
$failedAvds = @(ConvertFrom-RimsAndroidAvdOutput `
    -StandardOutput 'Must_Not_Be_Selected' `
    -ExitCode 1)
Assert-Equal `
  -Actual $failedAvds.Count `
  -Expected 0 `
  -Message 'AVD parser selected output from a failed emulator command.'

$originalBackendDirEnvironment = [Environment]::GetEnvironmentVariable(
  'RIMS_BACKEND_DIR',
  'Process'
)
$environmentBackendDir = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-source-env-' + [guid]::NewGuid().ToString('N'))
$explicitBackendDir = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-source-explicit-' + [guid]::NewGuid().ToString('N'))
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $environmentBackendDir,
    'Process'
  )
  Assert-Equal `
    -Actual (Resolve-RimsBackendDirectory -BackendDir '') `
    -Expected ([IO.Path]::GetFullPath($environmentBackendDir)) `
    -Message 'Backend source resolver ignored RIMS_BACKEND_DIR.'
  Assert-Equal `
    -Actual (Resolve-RimsBackendDirectory -BackendDir $explicitBackendDir) `
    -Expected ([IO.Path]::GetFullPath($explicitBackendDir)) `
    -Message 'Explicit backend source did not win over RIMS_BACKEND_DIR.'
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $null,
    'Process'
  )
  Assert-Equal `
    -Actual (Resolve-RimsBackendDirectory) `
    -Expected ([IO.Path]::GetFullPath(
      'E:\My Work\RIMS\rims-goProgect'
    )) `
    -Message 'Backend source resolver did not use its final fallback.'
} finally {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $originalBackendDirEnvironment,
    'Process'
  )
}

$originalBackendWorkspaceEnvironment = `
  [Environment]::GetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    'Process'
  )
$environmentBackendWorkspace = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-runtime-env-' + [guid]::NewGuid().ToString('N'))
$explicitBackendWorkspace = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-runtime-explicit-' + [guid]::NewGuid().ToString('N'))
$isolatedBackendSource = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-runtime-source-' + [guid]::NewGuid().ToString('N'))
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $environmentBackendWorkspace,
    'Process'
  )
  Assert-Equal `
    -Actual (Resolve-RimsBackendWorkspaceRoot `
      -BackendWorkspaceRoot '' `
      -BackendDir $isolatedBackendSource) `
    -Expected ([IO.Path]::GetFullPath($environmentBackendWorkspace)) `
    -Message 'Runtime resolver ignored RIMS_BACKEND_WORKSPACE_ROOT.'
  Assert-Equal `
    -Actual (Resolve-RimsBackendWorkspaceRoot `
      -BackendWorkspaceRoot $explicitBackendWorkspace `
      -BackendDir $isolatedBackendSource) `
    -Expected ([IO.Path]::GetFullPath($explicitBackendWorkspace)) `
    -Message 'Explicit runtime root did not win over its environment variable.'
} finally {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $originalBackendWorkspaceEnvironment,
    'Process'
  )
}

$validEnvironmentBackendDir = 'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect'
$validEnvironmentWorkspaceRoot = 'E:\My Work\RIMS'
$originalCliBackendDirEnvironment = [Environment]::GetEnvironmentVariable(
  'RIMS_BACKEND_DIR',
  'Process'
)
$originalCliWorkspaceEnvironment = [Environment]::GetEnvironmentVariable(
  'RIMS_BACKEND_WORKSPACE_ROOT',
  'Process'
)
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $validEnvironmentBackendDir,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $validEnvironmentWorkspaceRoot,
    'Process'
  )
  $environmentDoctor = Invoke-LocalCli -Arguments @(
    '-Command',
    'doctor',
    '-Target',
    'web',
    '-Output',
    'Json'
  )
  Assert-Equal `
    -Actual $environmentDoctor.ExitCode `
    -Expected 0 `
    -Message 'Doctor rejected valid environment-selected backend paths.'
  $environmentDoctorResult = ConvertFrom-SingleJson `
    -Text $environmentDoctor.StandardOutput `
    -Context 'Environment-selected JSON doctor'
  $environmentBackendComponent = @(
    $environmentDoctorResult.components | Where-Object {
      $_.name -eq 'backendWorkspace'
    }
  )[0]
  $environmentRuntimeComponent = @(
    $environmentDoctorResult.components | Where-Object {
      $_.name -eq 'workspaceEnv'
    }
  )[0]
  $environmentBackendPathId = (Get-RimsLocalSafePathMetadata `
      -Path $validEnvironmentBackendDir `
      -Category (Get-RimsLocalAbsolutePathCategory -Value $validEnvironmentBackendDir)).pathId
  $environmentRuntimePathId = (Get-RimsLocalSafePathMetadata `
      -Path $validEnvironmentWorkspaceRoot `
      -Category (Get-RimsLocalAbsolutePathCategory -Value $validEnvironmentWorkspaceRoot)).pathId
  if (-not $environmentBackendComponent.detail.Contains(
      $environmentBackendPathId)) {
    throw 'Doctor did not select RIMS_BACKEND_DIR.'
  }
  if (-not $environmentRuntimeComponent.detail.Contains(
      $environmentRuntimePathId)) {
    throw 'Doctor did not select RIMS_BACKEND_WORKSPACE_ROOT.'
  }

  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $environmentBackendDir,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $environmentBackendWorkspace,
    'Process'
  )
  $explicitDoctor = Invoke-LocalCli -Arguments @(
    '-Command',
    'doctor',
    '-Target',
    'web',
    '-Output',
    'Json',
    '-BackendDir',
    $validEnvironmentBackendDir,
    '-BackendWorkspaceRoot',
    $validEnvironmentWorkspaceRoot
  )
  Assert-Equal `
    -Actual $explicitDoctor.ExitCode `
    -Expected 0 `
    -Message 'Explicit backend paths did not win over invalid environment paths.'
  $explicitDoctorResult = ConvertFrom-SingleJson `
    -Text $explicitDoctor.StandardOutput `
    -Context 'Explicit-over-environment JSON doctor'
  $explicitBackendComponent = @(
    $explicitDoctorResult.components | Where-Object {
      $_.name -eq 'backendWorkspace'
    }
  )[0]
  $explicitRuntimeComponent = @(
    $explicitDoctorResult.components | Where-Object {
      $_.name -eq 'workspaceEnv'
    }
  )[0]
  if (-not $explicitBackendComponent.detail.Contains(
      $environmentBackendPathId)) {
    throw 'Doctor did not prefer explicit BackendDir over its environment value.'
  }
  if (-not $explicitRuntimeComponent.detail.Contains(
      $environmentRuntimePathId)) {
    throw 'Doctor did not prefer explicit runtime root over its environment value.'
  }
} finally {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_DIR',
    $originalCliBackendDirEnvironment,
    'Process'
  )
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $originalCliWorkspaceEnvironment,
    'Process'
  )
}

$originalFallbackWorkspaceEnvironment = `
  [Environment]::GetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    'Process'
  )
$workspacePathTestFunction = Get-Item `
  -LiteralPath 'Function:\Test-RimsWorkspaceEnvironmentPath'
$originalWorkspacePathTest = $workspacePathTestFunction.ScriptBlock
$fallbackBackendSource = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-runtime-fallback-' + [guid]::NewGuid().ToString('N'))
$expectedFallbackWorkspace = [IO.Path]::GetFullPath('E:\My Work\RIMS')
try {
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $null,
    'Process'
  )
  Set-Item `
    -LiteralPath 'Function:\Test-RimsWorkspaceEnvironmentPath' `
    -Value {
      param([string]$Path)
      return $false
    }
  $resolvedFallbackWorkspace = Resolve-RimsBackendWorkspaceRoot `
    -BackendWorkspaceRoot '' `
    -BackendDir $fallbackBackendSource
  if ($resolvedFallbackWorkspace -ne $expectedFallbackWorkspace) {
    throw "Runtime resolver did not retain the final fallback path. Expected: '$expectedFallbackWorkspace'. Actual: '$resolvedFallbackWorkspace'."
  }
} finally {
  Set-Item `
    -LiteralPath 'Function:\Test-RimsWorkspaceEnvironmentPath' `
    -Value $originalWorkspacePathTest
  [Environment]::SetEnvironmentVariable(
    'RIMS_BACKEND_WORKSPACE_ROOT',
    $originalFallbackWorkspaceEnvironment,
    'Process'
  )
}
