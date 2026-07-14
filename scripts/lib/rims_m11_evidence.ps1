function Test-RimsM11StrictInteger {
  param($Value)
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
}

function Get-RimsM11DiscreteEvidenceErrors {
  param($Candidate)
  $errors = [Collections.Generic.List[string]]::new()
  foreach ($field in @(
      'stockBefore', 'stockAfter', 'serverDocumentCount',
      'duplicateDocumentCount', 'duplicateInventoryTransactionCount',
      'attachmentCount', 'databaseBytes', 'unknownStatusProbeCount',
      'unknownReplayRequestCount', 'expectedStockDecrease',
      'observedStockDecrease'
    )) {
    $property = if ($null -eq $Candidate) {
      $null
    } else {
      $Candidate.PSObject.Properties[$field]
    }
    if ($null -eq $property -or
        -not (Test-RimsM11StrictInteger $property.Value) -or
        $property.Value -lt 0) {
      [void]$errors.Add(
        "Evidence '$field' must be a non-negative JSON integer."
      )
    }
  }
  return @($errors)
}
