$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localScript = Join-Path $scriptDir 'rims_local.ps1'

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

if (-not (Test-Path -LiteralPath $localScript)) {
  throw "Missing local runtime script: $localScript"
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

foreach ($command in ($expectedCommands | Where-Object { $_ -ne 'help' })) {
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
