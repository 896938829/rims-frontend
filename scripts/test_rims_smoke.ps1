$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$smokeScript = Join-Path $scriptDir 'rims_smoke.ps1'

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Expected
  )

  if (-not $Text.Contains($Expected)) {
    throw "Expected smoke script output to contain: $Expected"
  }
}

function Assert-DoesNotContain {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Unexpected
  )

  if ($Text.Contains($Unexpected)) {
    throw "Expected smoke script output to omit: $Unexpected"
  }
}

if (-not (Test-Path -LiteralPath $smokeScript)) {
  throw "Missing smoke script: $smokeScript"
}

$listedSteps = (& $smokeScript -ListSteps) -join "`n"
Assert-Contains -Text $listedSteps -Expected 'tool-state: rims_frontend\.tool-state-smoke'
Assert-Contains -Text $listedSteps -Expected 'pub-cache:'
Assert-DoesNotContain -Text $listedSteps -Unexpected 'pub-cache: rims_frontend\.tool-state-smoke\Pub\Cache'
Assert-Contains -Text $listedSteps -Expected 'flutter pub get --offline'
Assert-Contains -Text $listedSteps -Expected 'flutter analyze --no-pub'
Assert-Contains -Text $listedSteps -Expected 'flutter test --no-pub'
Assert-Contains -Text $listedSteps -Expected 'rg Demo residual scan'
Assert-Contains -Text $listedSteps -Expected 'git diff --check'

$listedWithoutPubGet = (& $smokeScript -ListSteps -SkipPubGet) -join "`n"
Assert-Contains -Text $listedWithoutPubGet -Expected 'tool-state: rims_frontend\.tool-state-smoke'
Assert-Contains -Text $listedWithoutPubGet -Expected 'pub-cache:'
Assert-DoesNotContain -Text $listedWithoutPubGet -Unexpected 'pub-cache: rims_frontend\.tool-state-smoke\Pub\Cache'
Assert-DoesNotContain -Text $listedWithoutPubGet -Unexpected 'flutter pub get --offline'
Assert-Contains -Text $listedWithoutPubGet -Expected 'flutter analyze --no-pub'
Assert-Contains -Text $listedWithoutPubGet -Expected 'flutter test --no-pub'

$jsonPlan = (& $smokeScript -ListSteps -Output Json) -join "`n" |
  ConvertFrom-Json
if ($jsonPlan.schemaVersion -ne 1) {
  throw 'Smoke JSON plan has an unexpected schema version.'
}
if (@($jsonPlan.steps).Count -lt 6) {
  throw 'Smoke JSON plan omitted required steps.'
}
foreach ($step in @($jsonPlan.steps)) {
  foreach ($property in @('name', 'command')) {
    if ($step.PSObject.Properties.Name -notcontains $property) {
      throw "Smoke JSON plan step omitted '$property'."
    }
  }
}

Write-Host 'Smoke script self-test passed.'
