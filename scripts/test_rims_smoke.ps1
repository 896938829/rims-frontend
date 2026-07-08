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

Write-Host 'Smoke script self-test passed.'
