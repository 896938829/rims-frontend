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
  'health',
  'logs',
  'restart',
  'reset',
  'smoke',
  'down'
)
$expectedTargets = @('none', 'web', 'android')

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
      $_ -notin @(
        'help',
        'doctor',
        'up',
        'status',
        'health',
        'logs',
        'restart',
        'down'
      )
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

$textFailure = Invoke-LocalCli -Arguments @('-Command', 'reset', '-Output', 'Text')
if ($textFailure.ExitCode -eq 0) {
  throw 'Expected text reset to fail until it is implemented.'
}
Assert-Equal `
  -Actual $textFailure.StandardOutput `
  -Expected '' `
  -Message 'Text failure wrote to stdout.'
if (-not $textFailure.StandardError.Contains('not implemented yet')) {
  throw 'Text failure did not explain that the command is not implemented yet.'
}
