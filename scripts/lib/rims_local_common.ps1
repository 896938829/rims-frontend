$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RimsLocalTimestamp {
  return [DateTime]::UtcNow.ToString(
    'o',
    [Globalization.CultureInfo]::InvariantCulture
  )
}

function New-RimsLocalResult {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command
  )

  return [pscustomobject][ordered]@{
    schemaVersion = 1
    command = $Command
    ok = $false
    exitCode = 1
    startedAt = Get-RimsLocalTimestamp
    finishedAt = $null
    components = @()
    errors = @()
  }
}

function Complete-RimsLocalResult {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result,
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [int]$ExitCode
  )

  $Result.ok = $Ok
  $Result.exitCode = $ExitCode
  $Result.finishedAt = Get-RimsLocalTimestamp
  return $Result
}

function Write-RimsLocalJson {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result
  )

  $json = $Result | ConvertTo-Json -Depth 10 -Compress
  [Console]::Out.WriteLine($json)
}
