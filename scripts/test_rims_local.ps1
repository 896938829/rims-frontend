$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localScript = Join-Path $scriptDir 'rims_local.ps1'
$commonScript = Join-Path $scriptDir 'lib\rims_local_common.ps1'

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected: '$Expected'. Actual: '$Actual'."
  }
}

function Assert-NotEqual {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -eq $Expected) {
    throw "$Message Expected a value different from: '$Expected'."
  }
}

function Assert-False {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Value -ne $false) {
    throw "$Message Expected: 'False'. Actual: '$Value'."
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Collection,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Collection -notcontains $Expected) {
    throw "$Message Expected collection to contain: '$Expected'."
  }
}

function Assert-HasProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  if ($Value.PSObject.Properties.Name -notcontains $PropertyName) {
    throw "Expected JSON result to contain property: '$PropertyName'."
  }
}

function Assert-ComponentSuccess {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $components = @($Result.components | Where-Object { $_.name -eq $Name })
  Assert-Equal `
    -Actual $components.Count `
    -Expected 1 `
    -Message "Expected exactly one '$Name' component."
  Assert-Equal `
    -Actual $components[0].ok `
    -Expected $true `
    -Message "Component '$Name' did not pass."
  Assert-Equal `
    -Actual $components[0].required `
    -Expected $true `
    -Message "Component '$Name' was not required."
}

function Assert-ComponentFailed {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $components = @($Result.components | Where-Object { $_.name -eq $Name })
  Assert-Equal `
    -Actual $components.Count `
    -Expected 1 `
    -Message "Expected exactly one '$Name' component."
  Assert-False `
    -Value $components[0].ok `
    -Message "Component '$Name' unexpectedly passed."
  Assert-Equal `
    -Actual $components[0].required `
    -Expected $true `
    -Message "Failed component '$Name' was not required."
  if ([string]::IsNullOrWhiteSpace([string]$components[0].remediation)) {
    throw "Failed component '$Name' omitted actionable remediation."
  }
}

function Assert-DoctorResultShape {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result,
    [Parameter(Mandatory = $true)]
    [string[]]$StableResultFields
  )

  Assert-Equal `
    -Actual ($Result.PSObject.Properties.Name -join '|') `
    -Expected ($StableResultFields -join '|') `
    -Message 'Doctor result property sequence changed.'
  Assert-JsonArrayProperty -Value $Result -PropertyName 'components'
  Assert-JsonArrayProperty -Value $Result -PropertyName 'errors'

  $componentFields = @('name', 'ok', 'required', 'detail', 'remediation')
  foreach ($component in @($Result.components)) {
    Assert-Equal `
      -Actual ($component.PSObject.Properties.Name -join '|') `
      -Expected ($componentFields -join '|') `
      -Message "Component '$($component.name)' property sequence changed."
  }
}

function Assert-JsonArrayProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $property = $Value.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    throw "Expected JSON result to contain array property: '$PropertyName'."
  }
  if (-not ($property.Value -is [Array])) {
    throw "Expected JSON property '$PropertyName' to be array-shaped."
  }
}

function Get-ValidateSetValues {
  param(
    [Parameter(Mandatory = $true)]
    [Management.Automation.Language.ScriptBlockAst]$Ast,
    [Parameter(Mandatory = $true)]
    [string]$ParameterName
  )

  $parameter = @($Ast.ParamBlock.Parameters | Where-Object {
      $_.Name.VariablePath.UserPath -eq $ParameterName
    }) | Select-Object -First 1
  if ($null -eq $parameter) {
    throw "Missing source parameter: '$ParameterName'."
  }

  $validateSet = @($parameter.Attributes | Where-Object {
      $_.TypeName.Name -eq 'ValidateSet'
    }) | Select-Object -First 1
  if ($null -eq $validateSet) {
    throw "Parameter '$ParameterName' is missing ValidateSet."
  }

  foreach ($argument in $validateSet.PositionalArguments) {
    if (-not ($argument -is [Management.Automation.Language.StringConstantExpressionAst])) {
      throw "Parameter '$ParameterName' contains a non-literal ValidateSet value."
    }
    $argument.Value
  }
}

function Get-LiteralAssignmentValues {
  param(
    [Parameter(Mandatory = $true)]
    [Management.Automation.Language.ScriptBlockAst]$Ast,
    [Parameter(Mandatory = $true)]
    [string]$VariableName
  )

  $assignments = @($Ast.FindAll({
      param($node)
      return (
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $VariableName
      )
    }, $true))
  if ($assignments.Count -ne 1) {
    throw "Expected one literal assignment for variable '$VariableName'."
  }

  $literalValues = @($assignments[0].Right.FindAll({
      param($node)
      return $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $true))
  if ($literalValues.Count -eq 0) {
    throw "Variable '$VariableName' does not contain literal values."
  }
  $literalValues | ForEach-Object { $_.Value }
}

function ConvertTo-WindowsCommandLineArgument {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

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

function Invoke-LocalCli {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$Arguments
  )

  $powerShellExecutable = (Get-Process -Id $PID).Path
  $argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $localScript
  ) + $Arguments
  $quotedArguments = $argumentList | ForEach-Object {
    ConvertTo-WindowsCommandLineArgument -Value $_
  }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $powerShellExecutable
  $startInfo.Arguments = $quotedArguments -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
  $standardErrorTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $standardOutput = $standardOutputTask.Result
  $standardError = $standardErrorTask.Result

  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    StandardOutput = $standardOutput
    StandardError = $standardError
  }
}

function ConvertFrom-SingleJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  try {
    return $Text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$Context must write exactly one JSON document to stdout. $($_.Exception.Message)"
  }
}

function Get-TextHelpSectionEntries {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$SectionName
  )

  $header = "${SectionName}:"
  $inSection = $false
  $entries = @()

  foreach ($rawLine in ($Text -split '\r?\n')) {
    $line = $rawLine.Trim()
    if (-not $inSection) {
      if ($line -eq $header) {
        $inSection = $true
      }
      continue
    }

    if ($line.Length -eq 0 -or $line.EndsWith(':')) {
      break
    }
    $entries += $line
  }

  if (-not $inSection) {
    throw "Text help omitted section: '$SectionName'."
  }
  return $entries
}

function Get-TestAndroidChoice {
  $adbPath = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $onlineDevices = @(Get-RimsOnlineAndroidDevices `
      -AdbExecutable $adbPath)
  if ($onlineDevices.Count -gt 0) {
    return $onlineDevices[0]
  }

  $emulatorPath = Resolve-RimsAndroidTool `
    -CommandName 'emulator.exe' `
    -SdkRelativePath 'emulator\emulator.exe'
  $installedAvds = @(Get-RimsInstalledAndroidAvds `
      -EmulatorExecutable $emulatorPath)
  if ($installedAvds.Count -gt 0) {
    return $installedAvds[0]
  }

  return $null
}

if (-not (Test-Path -LiteralPath $localScript)) {
  throw "Missing local runtime script: $localScript"
}
if (-not (Test-Path -LiteralPath $commonScript)) {
  throw "Missing local runtime common script: $commonScript"
}
. $commonScript

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
  -FilePath (Join-Path $PSHOME 'powershell.exe') `
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

Connection failed $([char]1) PASSWORD=hunter2 token=eyJhbGciOiJIUzI1NiJ9.payload.signature SECRET: super-secret Authorization: Bearer auth-value https://uri-user:uri-password@example.com/path
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
  if (-not $environmentBackendComponent.detail.Contains(
      $validEnvironmentBackendDir)) {
    throw 'Doctor did not select RIMS_BACKEND_DIR.'
  }
  if (-not $environmentRuntimeComponent.detail.Contains(
      $validEnvironmentWorkspaceRoot)) {
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
      $validEnvironmentBackendDir)) {
    throw 'Doctor did not prefer explicit BackendDir over its environment value.'
  }
  if (-not $explicitRuntimeComponent.detail.Contains(
      $validEnvironmentWorkspaceRoot)) {
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

$testTokens = $null
$testParseErrors = $null
$testAst = [Management.Automation.Language.Parser]::ParseFile(
  $MyInvocation.MyCommand.Path,
  [ref]$testTokens,
  [ref]$testParseErrors
)
Assert-Equal `
  -Actual @($testParseErrors).Count `
  -Expected 0 `
  -Message 'Contract test script contains parse errors.'
$invokeCliAst = $testAst.FindAll({
    param($node)
    return (
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Invoke-LocalCli'
    )
  }, $true) | Select-Object -First 1
$asyncReads = @($invokeCliAst.FindAll({
    param($node)
    return (
      $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Member.Value -eq 'ReadToEndAsync'
    )
  }, $true))
Assert-Equal `
  -Actual $asyncReads.Count `
  -Expected 2 `
  -Message 'Invoke-LocalCli must read stdout and stderr concurrently.'

$waitCall = $invokeCliAst.FindAll({
    param($node)
    return (
      $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Member.Value -eq 'WaitForExit'
    )
  }, $true) | Select-Object -First 1
foreach ($asyncRead in $asyncReads) {
  if ($asyncRead.Extent.StartOffset -gt $waitCall.Extent.StartOffset) {
    throw 'Invoke-LocalCli must start stream reads before waiting for exit.'
  }
}

$taskResults = @($invokeCliAst.FindAll({
    param($node)
    return (
      $node -is [Management.Automation.Language.MemberExpressionAst] -and
      $node.Member.Value -eq 'Result'
    )
  }, $true))
Assert-Equal `
  -Actual $taskResults.Count `
  -Expected 2 `
  -Message 'Invoke-LocalCli must collect both asynchronous stream results.'
foreach ($taskResult in $taskResults) {
  if ($taskResult.Extent.StartOffset -lt $waitCall.Extent.StartOffset) {
    throw 'Invoke-LocalCli must collect stream results after waiting for exit.'
  }
}

$help = Invoke-LocalCli -Arguments @('-Command', 'help', '-Output', 'Json')
Assert-Equal -Actual $help.ExitCode -Expected 0 -Message 'Help command failed.'
Assert-Equal `
  -Actual $help.StandardError `
  -Expected '' `
  -Message 'JSON help wrote diagnostics to stderr.'

$result = ConvertFrom-SingleJson -Text $help.StandardOutput -Context 'JSON help'

$stableResultFields = @(
  'schemaVersion',
  'command',
  'ok',
  'exitCode',
  'startedAt',
  'finishedAt',
  'components',
  'errors'
)
$stableResultFields | ForEach-Object {
  Assert-HasProperty -Value $result -PropertyName $_
}
$arrayAssertion = Get-Command `
  -Name 'Assert-JsonArrayProperty' `
  -CommandType Function `
  -ErrorAction SilentlyContinue
if ($null -eq $arrayAssertion) {
  throw 'Missing JSON array-shape assertion helper.'
}

$expectedHelpProperties = $stableResultFields + @('commands', 'targets')
Assert-Equal `
  -Actual ($result.PSObject.Properties.Name -join '|') `
  -Expected ($expectedHelpProperties -join '|') `
  -Message 'JSON help property sequence changed.'
@('commands', 'targets', 'components', 'errors') | ForEach-Object {
  Assert-JsonArrayProperty -Value $result -PropertyName $_
}

Assert-Equal -Actual $result.schemaVersion -Expected 1 -Message 'Unexpected schema version.'
Assert-Equal -Actual $result.command -Expected 'help' -Message 'Unexpected result command.'
Assert-Equal -Actual $result.ok -Expected $true -Message 'Help result was not successful.'
Assert-Equal -Actual $result.exitCode -Expected 0 -Message 'Unexpected result exit code.'

$expectedCommands = @(
  'help',
  'doctor',
  'up',
  'status',
  'logs',
  'restart',
  'reset',
  'smoke',
  'down'
)
$expectedTargets = @('none', 'web', 'android')

$validateSetReader = Get-Command `
  -Name 'Get-ValidateSetValues' `
  -CommandType Function `
  -ErrorAction SilentlyContinue
$literalArrayReader = Get-Command `
  -Name 'Get-LiteralAssignmentValues' `
  -CommandType Function `
  -ErrorAction SilentlyContinue
if ($null -eq $validateSetReader -or $null -eq $literalArrayReader) {
  throw 'Missing lifecycle source-contract AST helpers.'
}

$localTokens = $null
$localParseErrors = $null
$localAst = [Management.Automation.Language.Parser]::ParseFile(
  $localScript,
  [ref]$localTokens,
  [ref]$localParseErrors
)
Assert-Equal `
  -Actual @($localParseErrors).Count `
  -Expected 0 `
  -Message 'Local runtime script contains parse errors.'

$validateSetCommands = @(Get-ValidateSetValues `
  -Ast $localAst `
  -ParameterName 'Command')
$helpCommands = @(Get-LiteralAssignmentValues `
  -Ast $localAst `
  -VariableName 'commands')
$validateSetTargets = @(Get-ValidateSetValues `
  -Ast $localAst `
  -ParameterName 'Target')
$helpTargets = @(Get-LiteralAssignmentValues `
  -Ast $localAst `
  -VariableName 'targets')

Assert-Equal `
  -Actual ($validateSetCommands -join '|') `
  -Expected ($expectedCommands -join '|') `
  -Message 'Command ValidateSet and test contract are out of sync.'
Assert-Equal `
  -Actual ($helpCommands -join '|') `
  -Expected ($expectedCommands -join '|') `
  -Message 'Help command list and test contract are out of sync.'
Assert-Equal `
  -Actual ($validateSetTargets -join '|') `
  -Expected ($expectedTargets -join '|') `
  -Message 'Target ValidateSet and test contract are out of sync.'
Assert-Equal `
  -Actual ($helpTargets -join '|') `
  -Expected ($expectedTargets -join '|') `
  -Message 'Help target list and test contract are out of sync.'

$escapedArgumentHelp = Invoke-LocalCli -Arguments @(
  '-Command',
  'help',
  '-Output',
  'Json',
  '-BackendDir',
  'C:\RIMS Backend\api & tool''s',
  '-BackendWorkspaceRoot',
  'C:\RIMS Workspaces\root; $literal [x]',
  '-AndroidDevice',
  'Pixel "9" & device; test'
)
Assert-Equal `
  -Actual $escapedArgumentHelp.ExitCode `
  -Expected 0 `
  -Message 'Help failed to preserve spaced or metacharacter-bearing arguments.'
Assert-Equal `
  -Actual $escapedArgumentHelp.StandardError `
  -Expected '' `
  -Message 'Escaped-argument JSON help wrote diagnostics to stderr.'
[void](ConvertFrom-SingleJson `
  -Text $escapedArgumentHelp.StandardOutput `
  -Context 'Escaped-argument JSON help')

Assert-Equal `
  -Actual @($result.commands).Count `
  -Expected $expectedCommands.Count `
  -Message 'Help returned the wrong number of commands.'
foreach ($command in $expectedCommands) {
  Assert-Contains `
    -Collection $result.commands `
    -Expected $command `
    -Message 'Help omitted a command.'
}

Assert-Equal `
  -Actual @($result.targets).Count `
  -Expected $expectedTargets.Count `
  -Message 'Help returned the wrong number of targets.'
foreach ($target in $expectedTargets) {
  Assert-Contains `
    -Collection $result.targets `
    -Expected $target `
    -Message 'Help omitted a target.'
}

$sectionParser = Get-Command `
  -Name 'Get-TextHelpSectionEntries' `
  -CommandType Function `
  -ErrorAction SilentlyContinue
if ($null -eq $sectionParser) {
  throw 'Missing exact text help section parser.'
}

$misleadingTextHelp = @'
Usage mentions up, down, and android outside help sections.

Commands:
  help

Targets:
  none
'@
$misleadingCommands = @(Get-TextHelpSectionEntries `
  -Text $misleadingTextHelp `
  -SectionName 'Commands')
$misleadingTargets = @(Get-TextHelpSectionEntries `
  -Text $misleadingTextHelp `
  -SectionName 'Targets')
Assert-Equal `
  -Actual $misleadingCommands.Count `
  -Expected 1 `
  -Message 'Command parser included text outside the Commands section.'
Assert-Contains `
  -Collection $misleadingCommands `
  -Expected 'help' `
  -Message 'Command parser omitted an exact section entry.'
Assert-Equal `
  -Actual $misleadingTargets.Count `
  -Expected 1 `
  -Message 'Target parser included text outside the Targets section.'
Assert-Contains `
  -Collection $misleadingTargets `
  -Expected 'none' `
  -Message 'Target parser omitted an exact section entry.'

$textHelp = Invoke-LocalCli -Arguments @('-Command', 'help', '-Output', 'Text')
Assert-Equal -Actual $textHelp.ExitCode -Expected 0 -Message 'Text help command failed.'
$textCommands = @(Get-TextHelpSectionEntries `
  -Text $textHelp.StandardOutput `
  -SectionName 'Commands')
$textTargets = @(Get-TextHelpSectionEntries `
  -Text $textHelp.StandardOutput `
  -SectionName 'Targets')
Assert-Equal `
  -Actual ($textCommands -join '|') `
  -Expected ($expectedCommands -join '|') `
  -Message 'Text help commands do not exactly match the command contract.'
Assert-Equal `
  -Actual ($textTargets -join '|') `
  -Expected ($expectedTargets -join '|') `
  -Message 'Text help targets do not exactly match the target contract.'

$backendDir = 'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect'
$backendWorkspaceRoot = 'E:\My Work\RIMS'
$invalidBackendDir = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-local-missing-' + [guid]::NewGuid().ToString('N'))
Assert-Equal `
  -Actual (Test-Path -LiteralPath $invalidBackendDir) `
  -Expected $false `
  -Message 'Invalid backend test path unexpectedly exists.'

$badDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'web',
  '-Output',
  'Json',
  '-BackendDir',
  $invalidBackendDir
)
Assert-NotEqual `
  -Actual $badDoctor.ExitCode `
  -Expected 0 `
  -Message 'Invalid backend directory doctor exit code.'
Assert-Equal `
  -Actual $badDoctor.StandardError `
  -Expected '' `
  -Message 'Invalid backend JSON doctor wrote diagnostics to stderr.'
$badDoctorResult = ConvertFrom-SingleJson `
  -Text $badDoctor.StandardOutput `
  -Context 'Invalid backend JSON doctor'
Assert-DoctorResultShape `
  -Result $badDoctorResult `
  -StableResultFields $stableResultFields
Assert-False `
  -Value $badDoctorResult.ok `
  -Message 'Invalid backend directory doctor result.'
Assert-ComponentFailed -Result $badDoctorResult -Name 'backendWorkspace'
$badBackendComponent = @($badDoctorResult.components | Where-Object {
    $_.name -eq 'backendWorkspace'
  })[0]
if (-not $badBackendComponent.detail.Contains($invalidBackendDir)) {
  throw 'Backend workspace detail omitted the resolved backend source path.'
}

$webDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'web',
  '-Output',
  'Json',
  '-BackendDir',
  $backendDir,
  '-BackendWorkspaceRoot',
  $backendWorkspaceRoot
)
Assert-Equal `
  -Actual $webDoctor.ExitCode `
  -Expected 0 `
  -Message 'Valid Web environment doctor failed.'
Assert-Equal `
  -Actual $webDoctor.StandardError `
  -Expected '' `
  -Message 'Valid Web JSON doctor wrote diagnostics to stderr.'
$webDoctorResult = ConvertFrom-SingleJson `
  -Text $webDoctor.StandardOutput `
  -Context 'Valid Web JSON doctor'
Assert-DoctorResultShape `
  -Result $webDoctorResult `
  -StableResultFields $stableResultFields
Assert-Equal `
  -Actual $webDoctorResult.ok `
  -Expected $true `
  -Message 'Valid Web doctor result was not successful.'
$webComponents = @(
  'powershell',
  'wsl',
  'git',
  'flutter',
  'frontendWorkspace',
  'backendWorkspace',
  'workspaceEnv',
  'go',
  'docker',
  'dockerCompose',
  'webDevice'
)
foreach ($componentName in $webComponents) {
  Assert-ComponentSuccess -Result $webDoctorResult -Name $componentName
}
$webDeviceComponent = @($webDoctorResult.components | Where-Object {
    $_.name -eq 'webDevice'
  })[0]
if ($webDeviceComponent.detail -match '(^|[ ,:])windows([, .]|$)') {
  throw 'Web device detail included a non-web Flutter device.'
}
$webBackendComponent = @($webDoctorResult.components | Where-Object {
    $_.name -eq 'backendWorkspace'
  })[0]
if (-not $webBackendComponent.detail.Contains($backendDir)) {
  throw 'Successful backend workspace detail omitted the resolved source path.'
}
$workspaceEnvComponent = @($webDoctorResult.components | Where-Object {
    $_.name -eq 'workspaceEnv'
  })[0]
if (-not $workspaceEnvComponent.detail.Contains($backendWorkspaceRoot)) {
  throw 'Workspace environment detail omitted the resolved runtime root.'
}

$androidDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'android',
  '-Output',
  'Json',
  '-BackendDir',
  $backendDir,
  '-BackendWorkspaceRoot',
  $backendWorkspaceRoot,
  '-AndroidDevice',
  ''
)
Assert-NotEqual `
  -Actual $androidDoctor.ExitCode `
  -Expected 0 `
  -Message 'Android doctor without a requested device exit code.'
Assert-Equal `
  -Actual $androidDoctor.StandardError `
  -Expected '' `
  -Message 'Android JSON doctor wrote diagnostics to stderr.'
$androidDoctorResult = ConvertFrom-SingleJson `
  -Text $androidDoctor.StandardOutput `
  -Context 'Android JSON doctor without requested device'
Assert-DoctorResultShape `
  -Result $androidDoctorResult `
  -StableResultFields $stableResultFields
Assert-False `
  -Value $androidDoctorResult.ok `
  -Message 'Android doctor without a requested device result.'
foreach ($componentName in ($webComponents + @('adb', 'emulator'))) {
  Assert-ComponentSuccess -Result $androidDoctorResult -Name $componentName
}
Assert-ComponentFailed -Result $androidDoctorResult -Name 'androidDevice'
$missingAndroidDevice = @($androidDoctorResult.components | Where-Object {
    $_.name -eq 'androidDevice'
  })[0]
if (-not $missingAndroidDevice.detail.Contains('Available choices:')) {
  throw 'Missing Android device failure did not list available choices.'
}

$androidChoice = Get-TestAndroidChoice
if ([string]::IsNullOrWhiteSpace($androidChoice)) {
  throw 'Confirmed test environment did not expose an online device or installed AVD.'
}
$configuredAndroidDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'android',
  '-Output',
  'Json',
  '-BackendDir',
  $backendDir,
  '-BackendWorkspaceRoot',
  $backendWorkspaceRoot,
  '-AndroidDevice',
  $androidChoice
)
Assert-Equal `
  -Actual $configuredAndroidDoctor.ExitCode `
  -Expected 0 `
  -Message 'Android doctor rejected an online device or installed AVD.'
Assert-Equal `
  -Actual $configuredAndroidDoctor.StandardError `
  -Expected '' `
  -Message 'Configured Android JSON doctor wrote diagnostics to stderr.'
$configuredAndroidResult = ConvertFrom-SingleJson `
  -Text $configuredAndroidDoctor.StandardOutput `
  -Context 'Configured Android JSON doctor'
Assert-DoctorResultShape `
  -Result $configuredAndroidResult `
  -StableResultFields $stableResultFields
Assert-ComponentSuccess -Result $configuredAndroidResult -Name 'androidDevice'
$configuredAndroidDevice = @($configuredAndroidResult.components | Where-Object {
    $_.name -eq 'androidDevice'
  })[0]
if (-not $configuredAndroidDevice.detail.Contains($androidChoice)) {
  throw 'Android device success detail omitted the configured choice.'
}

$textDoctor = Invoke-LocalCli -Arguments @(
  '-Command',
  'doctor',
  '-Target',
  'web',
  '-Output',
  'Text',
  '-BackendDir',
  $invalidBackendDir,
  '-BackendWorkspaceRoot',
  $backendWorkspaceRoot
)
Assert-NotEqual `
  -Actual $textDoctor.ExitCode `
  -Expected 0 `
  -Message 'Invalid backend text doctor exit code.'
Assert-Equal `
  -Actual $textDoctor.StandardError `
  -Expected '' `
  -Message 'Normal text diagnosis failure wrote a stack trace to stderr.'
if (-not $textDoctor.StandardOutput.Contains('[FAIL] backendWorkspace')) {
  throw 'Text doctor omitted the failed backend workspace component.'
}
if ($textDoctor.StandardOutput -match 'CategoryInfo|ScriptStackTrace|at <ScriptBlock>') {
  throw 'Text doctor exposed a stack trace for a normal diagnosis failure.'
}

foreach ($command in ($expectedCommands | Where-Object {
      $_ -notin @('help', 'doctor')
    })) {
  $failure = Invoke-LocalCli -Arguments @('-Command', $command, '-Output', 'Json')
  if ($failure.ExitCode -eq 0) {
    throw "Expected '$command' to fail until it is implemented."
  }
  Assert-Equal `
    -Actual $failure.StandardError `
    -Expected '' `
    -Message "JSON $command wrote diagnostics to stderr."

  $failureResult = ConvertFrom-SingleJson `
    -Text $failure.StandardOutput `
    -Context "JSON $command"
  $stableResultFields | ForEach-Object {
    Assert-HasProperty -Value $failureResult -PropertyName $_
  }
  Assert-Equal `
    -Actual $failureResult.command `
    -Expected $command `
    -Message 'Unexpected failure result command.'
  Assert-Equal `
    -Actual $failureResult.ok `
    -Expected $false `
    -Message 'Unimplemented command reported success.'
  Assert-Equal `
    -Actual $failureResult.exitCode `
    -Expected $failure.ExitCode `
    -Message 'Process and result exit codes differ.'
  Assert-Contains `
    -Collection $failureResult.errors `
    -Expected "Command '$command' is not implemented yet." `
    -Message 'Unimplemented command returned an unclear error.'
}

$textFailure = Invoke-LocalCli -Arguments @('-Command', 'status', '-Output', 'Text')
if ($textFailure.ExitCode -eq 0) {
  throw 'Expected text status to fail until it is implemented.'
}
Assert-Equal `
  -Actual $textFailure.StandardOutput `
  -Expected '' `
  -Message 'Text failure wrote to stdout.'
if (-not $textFailure.StandardError.Contains('not implemented yet')) {
  throw 'Text failure did not explain that the command is not implemented yet.'
}

Write-Host 'Local runtime CLI contract test passed.'
