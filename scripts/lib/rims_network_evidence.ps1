Set-StrictMode -Version Latest

function Test-RimsNetworkInteger {
  param($Value)
  return $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
}

function Test-RimsNetworkTimestamp {
  param($Value)
  if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
    return $true
  }
  $parsed = [DateTimeOffset]::MinValue
  return $Value -is [string] -and
    -not [string]::IsNullOrWhiteSpace($Value) -and
    [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Get-RimsNetworkProperty {
  param($Candidate, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Candidate -or $Candidate -is [string] -or
      $Candidate -is [ValueType]) {
    return $null
  }
  return $Candidate.PSObject.Properties[$Name]
}

function Get-NetworkEvidenceErrors {
  param($Candidate)

  $errors = [Collections.Generic.List[string]]::new()
  if ($null -eq $Candidate -or $Candidate -is [string] -or
      $Candidate -is [ValueType] -or $Candidate -is [Array]) {
    [void]$errors.Add('Network evidence must be an object.')
    return @($errors)
  }

  $ports = @{}
  foreach ($name in @(
      'backendTargetPort', 'ownedBridgePort', 'faultProxyPort'
    )) {
    $property = Get-RimsNetworkProperty -Candidate $Candidate -Name $name
    if ($null -eq $property -or
        -not (Test-RimsNetworkInteger $property.Value) -or
        [double]$property.Value -lt 1 -or
        [double]$property.Value -gt 65535) {
      [void]$errors.Add("Network evidence '$name' must be an integer from 1 through 65535.")
    } else {
      $ports[$name] = [int]$property.Value
    }
  }
  if ($ports.Count -eq 3) {
    if ($ports.faultProxyPort -eq $ports.backendTargetPort) {
      [void]$errors.Add('Fault proxy port must differ from the backend target port.')
    }
    if ($ports.faultProxyPort -eq $ports.ownedBridgePort) {
      [void]$errors.Add('Fault proxy port must differ from the owned bridge port.')
    }
  }

  $chain = Get-RimsNetworkProperty -Candidate $Candidate -Name 'connectionChain'
  if ($null -eq $chain -or $chain.Value -isnot [string] -or
      $chain.Value -cne
        'emulator->owned-fault-proxy->owned-host-bridge->verified-wsl-backend') {
    [void]$errors.Add('Network evidence connection chain is missing or invalid.')
  }

  $identities = @{}
  foreach ($name in @('hostBridge', 'faultProxy')) {
    $property = Get-RimsNetworkProperty -Candidate $Candidate -Name $name
    if ($null -eq $property -or $null -eq $property.Value -or
        $property.Value -is [string] -or $property.Value -is [ValueType] -or
        $property.Value -is [Array]) {
      [void]$errors.Add("Network evidence '$name' identity must be an object.")
      continue
    }
    $identity = $property.Value
    $identities[$name] = $identity
    $owned = Get-RimsNetworkProperty -Candidate $identity -Name 'owned'
    if ($null -eq $owned -or $owned.Value -isnot [bool] -or
        -not $owned.Value) {
      [void]$errors.Add("Network evidence '$name.owned' must be Boolean true.")
    }
    $processIdProperty = Get-RimsNetworkProperty `
      -Candidate $identity `
      -Name 'windowsPid'
    if ($null -eq $processIdProperty -or
        -not (Test-RimsNetworkInteger $processIdProperty.Value) -or
        [double]$processIdProperty.Value -lt 1) {
      [void]$errors.Add("Network evidence '$name.windowsPid' must be a positive integer.")
    }
    $start = Get-RimsNetworkProperty `
      -Candidate $identity `
      -Name 'windowsProcessStartTimeUtc'
    if ($null -eq $start -or
        -not (Test-RimsNetworkTimestamp $start.Value)) {
      [void]$errors.Add("Network evidence '$name.windowsProcessStartTimeUtc' must be a parseable timestamp.")
    }
  }

  if ($identities.ContainsKey('hostBridge')) {
    $bridge = $identities.hostBridge
    $listen = Get-RimsNetworkProperty -Candidate $bridge -Name 'listenPort'
    $upstream = Get-RimsNetworkProperty -Candidate $bridge -Name 'upstreamPort'
    $validated = Get-RimsNetworkProperty `
      -Candidate $bridge `
      -Name 'backendIdentityValidated'
    foreach ($address in @(
        @{ Name = 'listenAddress'; Expected = '127.0.0.1' },
        @{ Name = 'upstreamAddress'; Expected = '::1' }
      )) {
      $addressProperty = Get-RimsNetworkProperty `
        -Candidate $bridge `
        -Name $address.Name
      if ($null -eq $addressProperty -or
          $addressProperty.Value -isnot [string] -or
          [string]::IsNullOrWhiteSpace($addressProperty.Value) -or
          $addressProperty.Value -cne $address.Expected) {
        [void]$errors.Add(
          "Host bridge $($address.Name) must be '$($address.Expected)'."
        )
      }
    }
    if ($ports.ContainsKey('ownedBridgePort') -and
        ($null -eq $listen -or
          -not (Test-RimsNetworkInteger $listen.Value) -or
          [int]$listen.Value -ne $ports.ownedBridgePort)) {
      [void]$errors.Add('Host bridge listen port does not match ownedBridgePort.')
    }
    if ($ports.ContainsKey('backendTargetPort') -and
        ($null -eq $upstream -or
          -not (Test-RimsNetworkInteger $upstream.Value) -or
          [int]$upstream.Value -ne $ports.backendTargetPort)) {
      [void]$errors.Add('Host bridge upstream port does not match backendTargetPort.')
    }
    if ($null -eq $validated -or $validated.Value -isnot [bool] -or
        -not $validated.Value) {
      [void]$errors.Add('Host bridge backend identity validation must be Boolean true.')
    }
  }

  if ($identities.ContainsKey('faultProxy')) {
    $proxy = $identities.faultProxy
    $listen = Get-RimsNetworkProperty -Candidate $proxy -Name 'listenPort'
    $upstream = Get-RimsNetworkProperty -Candidate $proxy -Name 'upstreamPort'
    $upstreamOwnership = Get-RimsNetworkProperty `
      -Candidate $proxy `
      -Name 'upstreamOwnership'
    foreach ($address in @(
        @{ Name = 'listenAddress'; Expected = '127.0.0.1' },
        @{ Name = 'upstreamAddress'; Expected = '127.0.0.1' }
      )) {
      $addressProperty = Get-RimsNetworkProperty `
        -Candidate $proxy `
        -Name $address.Name
      if ($null -eq $addressProperty -or
          $addressProperty.Value -isnot [string] -or
          [string]::IsNullOrWhiteSpace($addressProperty.Value) -or
          $addressProperty.Value -cne $address.Expected) {
        [void]$errors.Add(
          "Fault proxy $($address.Name) must be '$($address.Expected)'."
        )
      }
    }
    if ($ports.ContainsKey('faultProxyPort') -and
        ($null -eq $listen -or
          -not (Test-RimsNetworkInteger $listen.Value) -or
          [int]$listen.Value -ne $ports.faultProxyPort)) {
      [void]$errors.Add('Fault proxy listen port does not match faultProxyPort.')
    }
    if ($ports.ContainsKey('ownedBridgePort') -and
        ($null -eq $upstream -or
          -not (Test-RimsNetworkInteger $upstream.Value) -or
          [int]$upstream.Value -ne $ports.ownedBridgePort)) {
      [void]$errors.Add('Fault proxy upstream port does not match ownedBridgePort.')
    }
    if ($null -eq $upstreamOwnership -or
        $upstreamOwnership.Value -isnot [string] -or
        $upstreamOwnership.Value -cne 'validated-owned-host-bridge') {
      [void]$errors.Add('Fault proxy upstream ownership is missing or invalid.')
    }
  }

  $routeProperty = Get-RimsNetworkProperty `
    -Candidate $Candidate `
    -Name 'routeValidation'
  if ($null -eq $routeProperty -or $null -eq $routeProperty.Value -or
      $routeProperty.Value -is [string] -or
      $routeProperty.Value -is [ValueType] -or
      $routeProperty.Value -is [Array]) {
    [void]$errors.Add('Network route validation must be an object.')
    return @($errors)
  }
  $route = $routeProperty.Value
  foreach ($gate in @(
      @{ Name = 'ok'; Expected = $true },
      @{ Name = 'proxyReachedVerifiedBackend'; Expected = $true },
      @{ Name = 'unownedListenerReached'; Expected = $false }
    )) {
    $property = Get-RimsNetworkProperty -Candidate $route -Name $gate.Name
    if ($null -eq $property -or $property.Value -isnot [bool] -or
        $property.Value -ne $gate.Expected) {
      [void]$errors.Add("Network route '$($gate.Name)' must be Boolean $($gate.Expected).")
    }
  }
  $expectedIdentity = Get-RimsNetworkProperty `
    -Candidate $route `
    -Name 'expectedBackendIdentity'
  $observedIdentity = Get-RimsNetworkProperty `
    -Candidate $route `
    -Name 'observedBackendIdentity'
  if ($null -eq $expectedIdentity -or
      $expectedIdentity.Value -isnot [string] -or
      [string]::IsNullOrWhiteSpace($expectedIdentity.Value) -or
      $expectedIdentity.Value -cnotin @(
        'A', 'verified-managed-wsl-runtime'
      ) -or
      $null -eq $observedIdentity -or
      $observedIdentity.Value -isnot [string] -or
      [string]::IsNullOrWhiteSpace($observedIdentity.Value) -or
      $observedIdentity.Value -cne $expectedIdentity.Value -or
      $observedIdentity.Value -match '^(b|fake|unowned)$') {
    [void]$errors.Add('Network route did not match the verified backend identity.')
  }
  $backend = Get-RimsNetworkProperty -Candidate $route -Name 'backend'
  if ($null -ne $backend -and
      ($backend.Value -isnot [string] -or
        $null -eq $observedIdentity -or
        $observedIdentity.Value -isnot [string] -or
        $backend.Value -cne $observedIdentity.Value -or
        $backend.Value -match '^(b|fake|unowned)$')) {
    [void]$errors.Add('Network route reached a fake or unowned backend listener.')
  }
  foreach ($name in @(
      'backendTargetPort', 'ownedBridgePort', 'faultProxyPort'
    )) {
    $routePort = Get-RimsNetworkProperty -Candidate $route -Name $name
    if ($ports.ContainsKey($name) -and
        ($null -eq $routePort -or
          -not (Test-RimsNetworkInteger $routePort.Value) -or
          [int]$routePort.Value -ne $ports[$name])) {
      [void]$errors.Add("Network route '$name' does not match network evidence.")
    }
  }
  return @($errors)
}

function Test-NetworkEvidence {
  param($Candidate)
  return @(Get-NetworkEvidenceErrors -Candidate $Candidate).Count -eq 0
}

function Assert-NetworkEvidence {
  param($Candidate)
  $errors = @(Get-NetworkEvidenceErrors -Candidate $Candidate)
  if ($errors.Count -gt 0) {
    $exception = [IO.InvalidDataException]::new(
      "Invalid network evidence: $($errors -join '; ')"
    )
    $exception.Data['Errors'] = [string[]]$errors
    throw $exception
  }
  return $Candidate
}
