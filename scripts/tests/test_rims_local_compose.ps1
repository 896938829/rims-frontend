function New-TestPostgresResourceIdentity {
  param(
    [string]$ContainerId = 'controller-container-id',
    [string]$ProjectName = 'rims-test-project',
    [string]$ConfigPath = 'C:\test-backend-runtime\deploy\docker-compose.yml',
    [string]$ConfigHash = 'config-file-hash',
    [string]$ServiceHash = 'compose-service-hash'
  )

  return [pscustomobject][ordered]@{
    containerId = $ContainerId
    composeProjectName = $ProjectName
    composeConfigPath = $ConfigPath
    composeConfigHash = $ConfigHash
    serviceConfigHash = $ServiceHash
  }
}

function New-TestOwnedPostgresState {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Identity
  )

  return [pscustomobject][ordered]@{
    schemaVersion = 1
    dependencyOwnership = [pscustomobject][ordered]@{
      composeStartedByController = $true
      cleanupPending = $true
      postgresResource = $Identity
    }
  }
}

$storedPostgresIdentity = New-TestPostgresResourceIdentity
$ownedPostgresState = New-TestOwnedPostgresState `
  -Identity $storedPostgresIdentity
$removedContainerIds = New-Object 'Collections.Generic.List[string]'
$exactCleanup = Invoke-RimsOwnedPostgresCleanup `
  -State $ownedPostgresState `
  -BackendWorkspaceRoot 'C:\test-backend-runtime' `
  -CurrentIdentityAction {
    param([string]$BackendWorkspaceRoot)
    return [pscustomobject]@{
      ok = $true
      exists = $true
      identity = New-TestPostgresResourceIdentity
      detail = 'Exact current identity.'
    }
  } `
  -RemoveContainerAction {
    param([string]$ContainerId)
    [void]$removedContainerIds.Add($ContainerId)
    return [pscustomobject]@{
      ok = $true
      detail = 'Removed exact controller-created postgres container.'
    }
  }
Assert-True `
  -Value $exactCleanup.ok `
  -Message 'Exact controller-created postgres identity was not cleaned up.'
Assert-Equal `
  -Actual ($removedContainerIds -join '|') `
  -Expected 'controller-container-id' `
  -Message 'Cleanup did not target only the stored postgres container ID.'

$removedContainerIds.Clear()
$absentCleanup = Invoke-RimsOwnedPostgresCleanup `
  -State $ownedPostgresState `
  -BackendWorkspaceRoot 'C:\test-backend-runtime' `
  -CurrentIdentityAction {
    param([string]$BackendWorkspaceRoot)
    return [pscustomobject]@{
      ok = $true
      exists = $false
      identity = $null
      detail = 'Controller-created postgres container is already absent.'
    }
  } `
  -RemoveContainerAction {
    param([string]$ContainerId)
    [void]$removedContainerIds.Add($ContainerId)
    return [pscustomobject]@{ ok = $true; detail = 'Unexpected removal.' }
  }
Assert-True `
  -Value $absentCleanup.ok `
  -Message 'Already-absent controller-created postgres was not idempotent.'
Assert-Equal `
  -Actual $removedContainerIds.Count `
  -Expected 0 `
  -Message 'Absent postgres cleanup invoked container removal.'

$identityMismatches = @(
  [pscustomobject]@{
    name = 'replacement container'
    identity = New-TestPostgresResourceIdentity -ContainerId 'replacement-id'
  },
  [pscustomobject]@{
    name = 'project mismatch'
    identity = New-TestPostgresResourceIdentity -ProjectName 'replacement-project'
  },
  [pscustomobject]@{
    name = 'config path mismatch'
    identity = New-TestPostgresResourceIdentity `
      -ConfigPath 'C:\replacement\docker-compose.yml'
  },
  [pscustomobject]@{
    name = 'config file hash mismatch'
    identity = New-TestPostgresResourceIdentity -ConfigHash 'replacement-config-hash'
  },
  [pscustomobject]@{
    name = 'service config mismatch'
    identity = New-TestPostgresResourceIdentity -ServiceHash 'replacement-service-hash'
  }
)
foreach ($identityMismatch in $identityMismatches) {
  $removedContainerIds.Clear()
  $currentIdentity = $identityMismatch.identity
  $mismatchCleanup = Invoke-RimsOwnedPostgresCleanup `
    -State $ownedPostgresState `
    -BackendWorkspaceRoot 'C:\test-backend-runtime' `
    -CurrentIdentityAction {
      param([string]$BackendWorkspaceRoot)
      return [pscustomobject]@{
        ok = $true
        exists = $true
        identity = $currentIdentity
        detail = 'Current postgres identity.'
      }
    } `
    -RemoveContainerAction {
      param([string]$ContainerId)
      [void]$removedContainerIds.Add($ContainerId)
      return [pscustomobject]@{ ok = $true; detail = 'Unexpected removal.' }
    }
  Assert-False `
    -Value $mismatchCleanup.ok `
    -Message "Cleanup accepted $($identityMismatch.name)."
  Assert-True `
    -Value $mismatchCleanup.cleanupPending `
    -Message "Cleanup did not retain pending ownership for $($identityMismatch.name)."
  Assert-Equal `
    -Actual $removedContainerIds.Count `
    -Expected 0 `
    -Message "Cleanup removed postgres after $($identityMismatch.name)."
}
