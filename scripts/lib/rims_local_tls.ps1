function Get-RimsLocalWorkspaceId {
  param([Parameter(Mandatory = $true)][string]$ScriptDirectory)

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  ).TrimEnd('\', '/')
  $bytes = [Text.Encoding]::UTF8.GetBytes($repositoryRoot.ToLowerInvariant())
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
  } finally {
    $sha256.Dispose()
  }
}

function Get-RimsLocalTlsPaths {
  param([Parameter(Mandatory = $true)][string]$ScriptDirectory)

  $repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $ScriptDirectory)
  )
  $root = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot '.runtime\rims-local\tls')
  )
  $workspaceId = Get-RimsLocalWorkspaceId -ScriptDirectory $ScriptDirectory
  return [pscustomobject][ordered]@{
    repositoryRoot = $repositoryRoot
    workspaceId = $workspaceId
    root = $root
    opensslConfig = Join-Path $root 'openssl.cnf'
    caPrivateKey = Join-Path $root 'ca.key.pem'
    caCertificate = Join-Path $root 'ca.cert.pem'
    serverPrivateKey = Join-Path $root 'server.key.pem'
    serverRequest = Join-Path $root 'server.csr.pem'
    serverCertificate = Join-Path $root 'server.cert.pem'
    serverPfx = Join-Path $root 'server.pfx'
    caSerial = Join-Path $root 'ca.cert.srl'
    proxySource = Join-Path $root 'proxy.go'
    proxyBinary = Join-Path $root 'rims-local-tls-proxy'
    proxyLinuxIdentity = Join-Path $root 'proxy.linux-identity.json'
    proxyScript = Join-Path $root 'proxy.go'
    proxyStdoutLog = Join-Path $root 'proxy.stdout.log'
    proxyStderrLog = Join-Path $root 'proxy.stderr.log'
  }
}

function New-RimsLocalTlsProxySource {
  return @'
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

func handleConnection(ctx context.Context, client net.Conn, backendAddress string) {
	defer client.Close()
	connectionDone := make(chan struct{})
	defer close(connectionDone)
	go func() {
		select {
		case <-ctx.Done():
			_ = client.Close()
		case <-connectionDone:
		}
	}()
	tlsClient, ok := client.(*tls.Conn)
	if !ok {
		return
	}
	if err := tlsClient.Handshake(); err != nil {
		return
	}
	backend, err := (&net.Dialer{}).DialContext(ctx, "tcp", backendAddress)
	if err != nil {
		return
	}
	defer backend.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(backend, tlsClient)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(tlsClient, backend)
		done <- struct{}{}
	}()
	<-done
	_ = tlsClient.Close()
	_ = backend.Close()
	<-done
}

func main() {
	certificatePath := flag.String("cert", "", "server certificate PEM")
	privateKeyPath := flag.String("key", "", "server private key PEM")
	listenPort := flag.String("listen-port", "", "loopback TLS port")
	backendPort := flag.String("backend-port", "", "loopback backend port")
	commandMarker := flag.String("command-marker", "", "ownership marker")
	flag.Parse()
	if *commandMarker == "" {
		log.Fatal("missing command marker")
	}

	certificate, err := tls.LoadX509KeyPair(
		*certificatePath,
		*privateKeyPath,
	)
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+*listenPort)
	if err != nil {
		log.Fatal(err)
	}
	tlsListener := tls.NewListener(listener, &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
	})

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()
	go func() {
		<-ctx.Done()
		_ = tlsListener.Close()
	}()

	backendAddress := "127.0.0.1:" + *backendPort
	var connections sync.WaitGroup
	for {
		client, acceptErr := tlsListener.Accept()
		if acceptErr != nil {
			if errors.Is(acceptErr, net.ErrClosed) || ctx.Err() != nil {
				break
			}
			continue
		}
		connections.Add(1)
		go func() {
			defer connections.Done()
			handleConnection(ctx, client, backendAddress)
		}()
	}
	connections.Wait()
}
'@
}

function Get-RimsLocalTlsPort {
  $configured = $env:RIMS_LOCAL_TLS_PORT
  $port = 8443
  if (-not [string]::IsNullOrWhiteSpace($configured) -and
      (-not [int]::TryParse($configured, [ref]$port) -or
        $port -lt 1 -or $port -gt 65535)) {
    throw 'RIMS_LOCAL_TLS_PORT must be an integer from 1 through 65535.'
  }
  return $port
}

function Test-RimsLocalTlsModeMatchesState {
  param(
    [AllowNull()][object]$State,
    [switch]$UseLocalTls
  )

  $recordedTls = $null -ne (Get-RimsObjectPropertyValue `
      -Value $State `
      -Name 'localTls')
  return $recordedTls -eq [bool]$UseLocalTls
}

function Test-RimsLocalTlsRuntimePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths
  )

  try {
    $root = [IO.Path]::GetFullPath([string]$TlsPaths.root).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath($Path)
    return $candidate.StartsWith(
      $root + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function New-RimsLocalTlsOpenSslConfig {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [string[]]$HostNames = @('localhost'),
    [string[]]$IpAddresses = @('127.0.0.1', '10.0.2.2')
  )

  $dnsEntries = @($HostNames | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
  $ipEntries = @($IpAddresses | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
  $altNames = New-Object 'Collections.Generic.List[string]'
  for ($index = 0; $index -lt $dnsEntries.Count; $index++) {
    [void]$altNames.Add("DNS.$($index + 1) = $($dnsEntries[$index])")
  }
  for ($index = 0; $index -lt $ipEntries.Count; $index++) {
    [void]$altNames.Add("IP.$($index + 1) = $($ipEntries[$index])")
  }
  $sanSummary = @(
    $dnsEntries | ForEach-Object { "DNS:$_" }
    $ipEntries | ForEach-Object { "IP:$_" }
  ) -join ','

  return @"
[req]
prompt = no
distinguished_name = server_dn
req_extensions = server_ext

[server_dn]
CN = localhost
OU = rims-local-$WorkspaceId

[server_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $sanSummary

[alt_names]
$($altNames -join "`n")
"@
}

function Invoke-RimsLocalWslOpenSsl {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject]@{
      exitCode = -1
      stdout = ''
      stderr = 'wsl.exe is unavailable.'
    }
  }
  $converted = New-Object 'Collections.Generic.List[string]'
  foreach ($argument in $Arguments) {
    if ($argument.StartsWith('winpath:')) {
      [void]$converted.Add((ConvertTo-RimsWslPath `
            -WindowsPath $argument.Substring(8) `
            -WslExecutable $wsl))
    } else {
      [void]$converted.Add($argument)
    }
  }
  $result = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments (@('-e', 'openssl') + @($converted)) `
    -TimeoutSeconds 30
  return [pscustomobject]@{
    exitCode = $result.ExitCode
    stdout = $result.StandardOutput
    stderr = $result.StandardError
  }
}

function Get-RimsLocalTlsCertificateFingerprint {
  param([Parameter(Mandatory = $true)][string]$CertificatePath)

  $result = Invoke-RimsLocalWslOpenSsl -Arguments @(
    'x509',
    '-in',
    "winpath:$CertificatePath",
    '-noout',
    '-fingerprint',
    '-sha256'
  )
  if ($result.exitCode -ne 0) {
    throw "OpenSSL certificate fingerprint failed: $($result.stderr)"
  }
  $match = [regex]::Match([string]$result.stdout, 'Fingerprint=([0-9A-Fa-f:]+)')
  if (-not $match.Success) {
    throw 'OpenSSL returned no SHA-256 certificate fingerprint.'
  }
  return $match.Groups[1].Value.Replace(':', '').ToUpperInvariant()
}

function Test-RimsLocalTlsSpkiPin {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Pin
  )

  try {
    return -not [string]::IsNullOrWhiteSpace($Pin) -and
      ([Convert]::FromBase64String($Pin)).Length -eq 32
  } catch {
    return $false
  }
}

function Get-RimsLocalTlsSpkiPin {
  param([Parameter(Mandatory = $true)][string]$CertificatePath)

  $result = Invoke-RimsLocalWslOpenSsl -Arguments @(
    'x509',
    '-in',
    "winpath:$CertificatePath",
    '-pubkey',
    '-noout'
  )
  if ($result.exitCode -ne 0) {
    throw "OpenSSL SPKI export failed: $($result.stderr)"
  }
  $match = [regex]::Match(
    [string]$result.stdout,
    '-----BEGIN PUBLIC KEY-----\s*(?<base64>[A-Za-z0-9+/=\s]+?)\s*-----END PUBLIC KEY-----'
  )
  if (-not $match.Success) {
    throw 'OpenSSL returned no SubjectPublicKeyInfo public key.'
  }
  $spki = [Convert]::FromBase64String(
    ($match.Groups['base64'].Value -replace '\s+', '')
  )
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return [Convert]::ToBase64String($sha256.ComputeHash($spki))
  } finally {
    $sha256.Dispose()
  }
}

function Get-RimsLocalTlsSubjectHash {
  param([Parameter(Mandatory = $true)][string]$CertificatePath)

  $result = Invoke-RimsLocalWslOpenSsl -Arguments @(
    'x509', '-in', "winpath:$CertificatePath", '-noout', '-subject_hash_old'
  )
  if ($result.exitCode -ne 0) {
    throw "OpenSSL subject hash failed: $($result.stderr)"
  }
  $hash = ([string]$result.stdout).Trim().Split("`n")[0].Trim()
  if ($hash -notmatch '\A[0-9a-fA-F]{8}\z') {
    throw 'OpenSSL returned an invalid legacy subject hash.'
  }
  return $hash.ToLowerInvariant()
}

function New-RimsLocalTlsCertificates {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$OpenSslAction,
    [AllowNull()][scriptblock]$FingerprintAction,
    [AllowNull()][scriptblock]$SpkiPinAction,
    [AllowNull()][scriptblock]$CertificateValidationAction,
    [AllowNull()][scriptblock]$CleanupAction
  )

  foreach ($privatePath in @(
      $TlsPaths.caPrivateKey,
      $TlsPaths.serverPrivateKey,
      $TlsPaths.serverPfx
    )) {
    if (-not (Test-RimsLocalTlsRuntimePath `
        -Path $privatePath `
        -TlsPaths $TlsPaths)) {
      return [pscustomobject]@{ ok = $false; detail = 'TLS private path escaped the owned runtime.' }
    }
  }
  [void][IO.Directory]::CreateDirectory([string]$TlsPaths.root)
  $requiredMaterial = @(
    $TlsPaths.caPrivateKey,
    $TlsPaths.caCertificate,
    $TlsPaths.serverPrivateKey,
    $TlsPaths.serverCertificate,
    $TlsPaths.serverPfx
  )
  $materialExists = @($requiredMaterial | Where-Object {
      -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0
  if ($materialExists) {
    $validateCertificate = if ($null -eq $CertificateValidationAction) {
      { param($certificatePath, $caPath, $hostName)
        Test-RimsLocalTlsCertificate `
          -CertificatePath $certificatePath `
          -CaCertificatePath $caPath `
          -HostName $hostName
      }
    } else { $CertificateValidationAction }
    $validForAllHosts = $true
    foreach ($hostName in @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')) {
      $validation = & $validateCertificate `
        $TlsPaths.serverCertificate `
        $TlsPaths.caCertificate `
        $hostName
      if (-not [bool](Get-RimsObjectPropertyValue `
          -Value $validation `
          -Name 'ok' `
          -DefaultValue $false)) {
        $validForAllHosts = $false
        break
      }
    }
    if ($validForAllHosts) {
      $getExistingFingerprint = if ($null -eq $FingerprintAction) {
        { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
      } else { $FingerprintAction }
      $getExistingSpkiPin = if ($null -eq $SpkiPinAction) {
        { param($path) Get-RimsLocalTlsSpkiPin -CertificatePath $path }
      } else { $SpkiPinAction }
      return [pscustomobject][ordered]@{
        ok = $true
        detail = 'Reused valid workspace-scoped local TLS material.'
        workspaceId = $TlsPaths.workspaceId
        caCertificatePath = $TlsPaths.caCertificate
        serverCertificatePath = $TlsPaths.serverCertificate
        caFingerprintSha256 = [string](& $getExistingFingerprint $TlsPaths.caCertificate)
        serverFingerprintSha256 = [string](& $getExistingFingerprint $TlsPaths.serverCertificate)
        serverSpkiSha256 = [string](& $getExistingSpkiPin $TlsPaths.serverCertificate)
        caSubjectHash = if ($null -eq $OpenSslAction) {
          Get-RimsLocalTlsSubjectHash -CertificatePath $TlsPaths.caCertificate
        } else { $TlsPaths.workspaceId.Substring(0, 8) }
        requiredSans = @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')
        privateKeysStoredUnderIgnoredRuntime = $true
        created = $false
      }
    }
  }
  $config = New-RimsLocalTlsOpenSslConfig `
    -WorkspaceId $TlsPaths.workspaceId `
    -HostNames @('localhost', 'rims.local') `
    -IpAddresses @('127.0.0.1', '10.0.2.2')
  [IO.File]::WriteAllText(
    [string]$TlsPaths.opensslConfig,
    $config,
    (New-Object Text.UTF8Encoding($false))
  )
  $invokeOpenSsl = if ($null -eq $OpenSslAction) {
    { param($arguments, $paths) Invoke-RimsLocalWslOpenSsl -Arguments $arguments }
  } else {
    $OpenSslAction
  }
  $commands = @(
    @(
      'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
      '-days', '30', '-subj', "/CN=RIMS Local CA $($TlsPaths.workspaceId)",
      '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
      '-addext', 'subjectKeyIdentifier=hash',
      '-keyout', "winpath:$($TlsPaths.caPrivateKey)",
      '-out', "winpath:$($TlsPaths.caCertificate)"
    ),
    @(
      'req', '-newkey', 'rsa:2048', '-sha256', '-nodes',
      '-config', "winpath:$($TlsPaths.opensslConfig)",
      '-keyout', "winpath:$($TlsPaths.serverPrivateKey)",
      '-out', "winpath:$($TlsPaths.serverRequest)"
    ),
    @(
      'x509', '-req', '-sha256', '-days', '14',
      '-in', "winpath:$($TlsPaths.serverRequest)",
      '-CA', "winpath:$($TlsPaths.caCertificate)",
      '-CAkey', "winpath:$($TlsPaths.caPrivateKey)",
      '-CAcreateserial',
      '-extfile', "winpath:$($TlsPaths.opensslConfig)",
      '-extensions', 'server_ext',
      '-out', "winpath:$($TlsPaths.serverCertificate)"
    ),
    @(
      'pkcs12', '-export', '-passout', 'pass:',
      '-inkey', "winpath:$($TlsPaths.serverPrivateKey)",
      '-in', "winpath:$($TlsPaths.serverCertificate)",
      '-certfile', "winpath:$($TlsPaths.caCertificate)",
      '-out', "winpath:$($TlsPaths.serverPfx)"
    )
  )
  try {
    foreach ($command in $commands) {
      $result = & $invokeOpenSsl $command $TlsPaths
      if ([int](Get-RimsObjectPropertyValue `
          -Value $result `
          -Name 'exitCode' `
          -DefaultValue -1) -ne 0) {
        $detail = [string](Get-RimsObjectPropertyValue `
            -Value $result `
            -Name 'stderr' `
            -DefaultValue 'OpenSSL failed without detail.')
        throw $detail
      }
    }
    foreach ($requiredPath in @(
        $TlsPaths.caPrivateKey,
        $TlsPaths.caCertificate,
        $TlsPaths.serverPrivateKey,
        $TlsPaths.serverCertificate,
        $TlsPaths.serverPfx
      )) {
      if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "OpenSSL did not create $([IO.Path]::GetFileName($requiredPath))."
      }
    }
    $getFingerprint = if ($null -eq $FingerprintAction) {
      { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
    } else {
      $FingerprintAction
    }
    $getSpkiPin = if ($null -eq $SpkiPinAction) {
      { param($path) Get-RimsLocalTlsSpkiPin -CertificatePath $path }
    } else {
      $SpkiPinAction
    }
    return [pscustomobject][ordered]@{
      ok = $true
      detail = 'Generated a workspace-scoped local CA and HTTPS certificate.'
      workspaceId = $TlsPaths.workspaceId
      caCertificatePath = $TlsPaths.caCertificate
      serverCertificatePath = $TlsPaths.serverCertificate
      caFingerprintSha256 = [string](& $getFingerprint $TlsPaths.caCertificate)
      serverFingerprintSha256 = [string](& $getFingerprint $TlsPaths.serverCertificate)
      serverSpkiSha256 = [string](& $getSpkiPin $TlsPaths.serverCertificate)
      caSubjectHash = if ($null -eq $OpenSslAction) {
        Get-RimsLocalTlsSubjectHash -CertificatePath $TlsPaths.caCertificate
      } else {
        $TlsPaths.workspaceId.Substring(0, 8)
      }
      requiredSans = @('localhost', '127.0.0.1', '10.0.2.2', 'rims.local')
      privateKeysStoredUnderIgnoredRuntime = $true
      created = $true
    }
  } catch {
    $generationDetail = ConvertTo-RimsDiagnosticSummary `
      -StandardOutput '' `
      -StandardError $_.Exception.Message
    try {
      $cleanup = if ($null -eq $CleanupAction) {
        Remove-RimsLocalTlsCertificates -TlsPaths $TlsPaths
      } else {
        & $CleanupAction $TlsPaths
      }
    } catch {
      $cleanup = [pscustomobject]@{
        ok = $false
        detail = ConvertTo-RimsDiagnosticSummary `
          -StandardOutput '' `
          -StandardError $_.Exception.Message
      }
    }
    $cleanupOk = [bool](Get-RimsObjectPropertyValue `
        -Value $cleanup `
        -Name 'ok' `
        -DefaultValue $false)
    return [pscustomobject][ordered]@{
      ok = $false
      detail = if ($cleanupOk) {
        $generationDetail
      } else {
        "$generationDetail Cleanup remains pending: $([string](Get-RimsObjectPropertyValue -Value $cleanup -Name 'detail' -DefaultValue 'unknown cleanup failure'))."
      }
      cleanupPending = -not $cleanupOk
      state = if ($cleanupOk) { $null } else {
        [pscustomobject][ordered]@{
          workspaceId = $TlsPaths.workspaceId
          root = $TlsPaths.root
          certificateCreated = $true
          proxy = $null
          androidTrust = $null
          cleanupPending = $true
        }
      }
    }
  }
}

function Test-RimsLocalTlsCertificate {
  param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$CaCertificatePath,
    [Parameter(Mandatory = $true)][string]$HostName,
    [AllowNull()][scriptblock]$OpenSslAction
  )

  $action = if ($null -eq $OpenSslAction) {
    { param($arguments) Invoke-RimsLocalWslOpenSsl -Arguments $arguments }
  } else {
    $OpenSslAction
  }
  $identityOption = 'verify_hostname'
  $parsedIp = [Net.IPAddress]::None
  if ([Net.IPAddress]::TryParse($HostName, [ref]$parsedIp)) {
    $identityOption = 'verify_ip'
  }
  $arguments = @(
    'verify',
    '-purpose', 'sslserver',
    "-$identityOption", $HostName,
    '-CAfile', "winpath:$CaCertificatePath",
    "winpath:$CertificatePath"
  )
  try {
    $result = & $action $arguments
    $exitCode = [int](Get-RimsObjectPropertyValue `
        -Value $result `
        -Name 'exitCode' `
        -DefaultValue -1)
    return [pscustomobject][ordered]@{
      ok = $exitCode -eq 0
      hostName = $HostName
      detail = if ($exitCode -eq 0) {
        'Certificate chain, validity, usage, and host identity are valid.'
      } else {
        ConvertTo-RimsDiagnosticSummary `
          -StandardOutput ([string](Get-RimsObjectPropertyValue -Value $result -Name 'stdout' -DefaultValue '')) `
          -StandardError ([string](Get-RimsObjectPropertyValue -Value $result -Name 'stderr' -DefaultValue 'Certificate verification failed.'))
      }
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      hostName = $HostName
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
    }
  }
}


function Get-RimsLocalTlsProxyBootstrapScript {
  return @'
set -euo pipefail
binary=$1
certificate=$2
private_key=$3
listen_port=$4
backend_port=$5
identity_file=$6
command_marker=$7
stdout_log=$8
stderr_log=$9
exec setsid --fork --wait bash -c '
  set -euo pipefail
  binary=$1
  certificate=$2
  private_key=$3
  listen_port=$4
  backend_port=$5
  identity_file=$6
  command_marker=$7
  stdout_log=$8
  stderr_log=$9
  leader_pid=$$
  process_group_id=$(ps -o pgid= -p "$leader_pid" | tr -d "[:space:]")
  if [ "$process_group_id" != "$leader_pid" ]; then
    printf "TLS bootstrap did not become its process-group leader.\n" >&2
    exit 2
  fi
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  stat_line=$(cat "/proc/$leader_pid/stat")
  stat_tail=${stat_line##*) }
  set -- $stat_tail
  start_ticks=${20}
  umask 077
  identity_tmp="$identity_file.tmp.$$"
  printf "{\"bootId\":\"%s\",\"leaderPid\":%s,\"startTicks\":\"%s\",\"processGroupId\":%s,\"commandMarker\":\"%s\"}\n" \
    "$boot_id" "$leader_pid" "$start_ticks" "$process_group_id" "$command_marker" \
    > "$identity_tmp"
  mv -f -- "$identity_tmp" "$identity_file"
  exec "$binary" \
    -cert "$certificate" \
    -key "$private_key" \
    -listen-port "$listen_port" \
    -backend-port "$backend_port" \
    -command-marker "$command_marker" \
    >> "$stdout_log" 2>> "$stderr_log"
' "rims-local-tls-$command_marker" \
  "$binary" "$certificate" "$private_key" "$listen_port" \
  "$backend_port" "$identity_file" "$command_marker" \
  "$stdout_log" "$stderr_log"
'@
}

function Start-RimsLocalTlsProxyProcess {
  param(
    [Parameter(Mandatory = $true)][psobject]$Spec,
    [AllowNull()][scriptblock]$ProcessFactoryAction,
    [AllowNull()][scriptblock]$BuildAction,
    [AllowNull()][scriptblock]$PathConversionAction,
    [AllowNull()][scriptblock]$LinuxIdentityAction,
    [AllowNull()][scriptblock]$CompensationAction
  )

  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return [pscustomobject]@{
      ok = $false
      detail = 'wsl.exe is unavailable for the local TLS proxy.'
      cleanupPending = $false
      state = $null
    }
  }
  $convertPath = if ($null -eq $PathConversionAction) {
    { param($path) ConvertTo-RimsWslPath -WindowsPath $path -WslExecutable $wsl }
  } else { $PathConversionAction }
  try {
    $wslPaths = [pscustomobject][ordered]@{
      source = [string](& $convertPath ([string]$Spec.proxySource))
      binary = [string](& $convertPath ([string]$Spec.proxyBinary))
      certificate = [string](& $convertPath ([string]$Spec.serverCertificate))
      privateKey = [string](& $convertPath ([string]$Spec.serverPrivateKey))
      identity = [string](& $convertPath ([string]$Spec.linuxIdentityPath))
      stdoutLog = [string](& $convertPath ([string]$Spec.stdoutLogPath))
      stderrLog = [string](& $convertPath ([string]$Spec.stderrLogPath))
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "TLS proxy WSL path conversion failed: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  try {
    $build = if ($null -eq $BuildAction) {
      $buildScript = @'
set -euo pipefail
source=$1
binary=$2
"$HOME/local/go/bin/go" build -trimpath -o "$binary" "$source"
chmod 700 "$binary"
'@
      $buildResult = Invoke-RimsExternalCommand `
        -FilePath $wsl `
        -Arguments @(
          '-e', 'bash', '-c', $buildScript,
          'rims-local-tls-build', $wslPaths.source, $wslPaths.binary
        ) `
        -TimeoutSeconds 60
      [pscustomobject]@{
        ok = $buildResult.ExitCode -eq 0
        detail = Get-RimsExternalCommandSummary -Result $buildResult
      }
    } else { & $BuildAction $Spec }
  } catch {
    $build = [pscustomobject]@{ ok = $false; detail = $_.Exception.Message }
  }
  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $build -Name 'ok' -DefaultValue $build)) {
    return [pscustomobject]@{
      ok = $false
      detail = "TLS proxy Go build failed: $([string](Get-RimsObjectPropertyValue -Value $build -Name 'detail' -DefaultValue 'unknown build failure'))"
      cleanupPending = $false
      state = $null
    }
  }

  Remove-Item `
    -LiteralPath ([string]$Spec.linuxIdentityPath) `
    -Force `
    -ErrorAction SilentlyContinue
  $arguments = @(
    '-e', 'bash', '-c', (Get-RimsLocalTlsProxyBootstrapScript),
    'rims-local-tls-bootstrap',
    $wslPaths.binary,
    $wslPaths.certificate,
    $wslPaths.privateKey,
    [string]$Spec.tlsPort,
    [string]$Spec.backendPort,
    $wslPaths.identity,
    [string]$Spec.ownershipMarker,
    $wslPaths.stdoutLog,
    $wslPaths.stderrLog
  )
  $effectiveArguments = @(ConvertTo-RimsWslBashArguments `
      -FilePath $wsl `
      -Arguments $arguments)
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $wsl
  $startInfo.Arguments = ($effectiveArguments | ForEach-Object {
      ConvertTo-RimsWindowsCommandLineArgument -Value $_
    }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $process = if ($null -eq $ProcessFactoryAction) {
    New-Object Diagnostics.Process
  } else { & $ProcessFactoryAction }
  $process.StartInfo = $startInfo
  $started = $false
  $processId = $null
  $processStartTimeUtc = $null
  $linuxIdentity = $null
  $linuxProcessGroupId = $null
  $commandLine = "$wsl $($startInfo.Arguments)"
  try {
    [void]$process.Start()
    $started = $true
    $processId = $process.Id
    $processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    $linuxIdentity = if ($null -eq $LinuxIdentityAction) {
      Wait-RimsBootstrapLinuxIdentity `
        -RuntimePaths ([pscustomobject]@{
          linuxIdentity = $Spec.linuxIdentityPath
        }) `
        -Process $process `
        -CommandMarker $Spec.ownershipMarker
    } else { & $LinuxIdentityAction $Spec $process }
    foreach ($requiredIdentityProperty in @(
        'bootId',
        'leaderPid',
        'startTicks',
        'processGroupId',
        'commandMarker'
      )) {
      $requiredIdentityValue = [string](Get-RimsObjectPropertyValue `
          -Value $linuxIdentity `
          -Name $requiredIdentityProperty `
          -DefaultValue '')
      if ([string]::IsNullOrWhiteSpace($requiredIdentityValue)) {
        throw "TLS proxy Linux identity is missing $requiredIdentityProperty."
      }
      if ($requiredIdentityProperty -eq 'processGroupId') {
        $linuxProcessGroupId = [int]$requiredIdentityValue
      }
    }
    if (-not ([string]$linuxIdentity.commandMarker).Equals(
        [string]$Spec.ownershipMarker,
        [StringComparison]::Ordinal
      )) {
      throw 'TLS proxy Linux identity command marker does not match the workspace marker.'
    }
    return [pscustomobject]@{
      windowsPid = $processId
      windowsProcessStartTimeUtc = $processStartTimeUtc
      commandLine = $commandLine
      linuxIdentity = $linuxIdentity
      linuxProcessGroupId = $linuxProcessGroupId
      proxyBinaryWslPath = $wslPaths.binary
    }
  } catch {
    $startFailure = $_.Exception.Message
    $cleanupFailure = $null
    $compensationState = [pscustomobject][ordered]@{
      port = $Spec.tlsPort
      backendPort = $Spec.backendPort
      windowsPid = $processId
      windowsProcessStartTimeUtc = $processStartTimeUtc
      commandLine = $commandLine
      ownershipMarker = $Spec.ownershipMarker
      proxySourcePath = $Spec.proxySource
      proxyBinaryPath = $Spec.proxyBinary
      proxyBinaryWslPath = $wslPaths.binary
      linuxIdentity = $linuxIdentity
      linuxProcessGroupId = $linuxProcessGroupId
      cleanupPending = $true
    }
    if ($null -ne $linuxIdentity) {
      try {
        $compensationState.linuxProcessGroupId =
          Get-RimsObjectPropertyValue `
            -Value $linuxIdentity `
            -Name 'processGroupId'
      } catch {}
    }
    $compensated = -not $started
    if ($started) {
      if ($null -ne $linuxIdentity) {
        try {
          $compensated = if ($null -eq $CompensationAction) {
            [bool](Stop-RimsOwnedBackendProcess -State $compensationState)
          } else { [bool](& $CompensationAction $compensationState) }
          if (-not $compensated) {
            $cleanupFailure = 'Exact Windows/Linux compensation returned false.'
          }
        } catch {
          $compensated = $false
          $cleanupFailure = $_.Exception.Message
        }
      } else {
        try {
          $process.Kill()
          if (-not $process.WaitForExit(3000)) {
            throw 'TLS proxy process did not exit within the compensation timeout.'
          }
          $compensated = $true
        } catch {
          $compensated = $false
          $cleanupFailure = $_.Exception.Message
        }
      }
    }
    $cleanupPending = $started -and -not $compensated
    $partialState = if ($cleanupPending) { $compensationState } else { $null }
    return [pscustomobject][ordered]@{
      ok = $false
      detail = "TLS proxy process start or identity acquisition failed: $startFailure$(if ($cleanupPending) { "; cleanup remains pending: $cleanupFailure" })"
      cleanupPending = $cleanupPending
      state = $partialState
    }
  } finally {
    $process.Dispose()
  }
}

function Start-RimsLocalTlsProxy {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$BackendPort,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$TlsPort,
    [AllowNull()][scriptblock]$PortListeningAction,
    [AllowNull()][scriptblock]$StartProcessAction,
    [AllowNull()][scriptblock]$ReadinessAction,
    [AllowNull()][scriptblock]$PortOwnershipAction,
    [AllowNull()][scriptblock]$StopAction
  )

  $testListening = if ($null -eq $PortListeningAction) {
    { param($port) Test-RimsTcpPortListening -Port $port }
  } else { $PortListeningAction }
  if ([bool](& $testListening $TlsPort)) {
    return [pscustomobject]@{
      ok = $false
      detail = "TLS port $TlsPort has an unowned listener; it was left untouched."
    }
  }
  [void][IO.Directory]::CreateDirectory([string]$TlsPaths.root)
  [IO.File]::WriteAllText(
    [string]$TlsPaths.proxySource,
    (New-RimsLocalTlsProxySource),
    (New-Object Text.UTF8Encoding($false))
  )
  $marker = "rims-local-tls-proxy:$($TlsPaths.workspaceId)"
  $spec = [pscustomobject][ordered]@{
    proxySource = $TlsPaths.proxySource
    proxyBinary = $TlsPaths.proxyBinary
    linuxIdentityPath = $TlsPaths.proxyLinuxIdentity
    serverCertificate = $TlsPaths.serverCertificate
    serverPrivateKey = $TlsPaths.serverPrivateKey
    backendPort = $BackendPort
    tlsPort = $TlsPort
    ownershipMarker = $marker
    stdoutLogPath = $TlsPaths.proxyStdoutLog
    stderrLogPath = $TlsPaths.proxyStderrLog
    commandLine = "wsl.exe $($TlsPaths.proxyBinary) $marker"
  }
  try {
    $start = if ($null -eq $StartProcessAction) {
      Start-RimsLocalTlsProxyProcess -Spec $spec
    } else {
      & $StartProcessAction $spec
    }
  } catch {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = "TLS proxy start failed before process identity was obtained: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  if ($null -ne $start.PSObject.Properties['ok'] -and -not [bool]$start.ok) {
    return $start
  }
  $state = [pscustomobject][ordered]@{
    workspaceId = $TlsPaths.workspaceId
    port = $TlsPort
    backendPort = $BackendPort
    windowsPid = $start.windowsPid
    windowsProcessStartTimeUtc = $start.windowsProcessStartTimeUtc
    commandLine = $start.commandLine
    ownershipMarker = $marker
    proxySourcePath = $TlsPaths.proxySource
    proxyBinaryPath = $TlsPaths.proxyBinary
    proxyBinaryWslPath = Get-RimsObjectPropertyValue `
      -Value $start `
      -Name 'proxyBinaryWslPath' `
      -DefaultValue ''
    stdoutLogPath = $TlsPaths.proxyStdoutLog
    stderrLogPath = $TlsPaths.proxyStderrLog
    linuxIdentity = Get-RimsObjectPropertyValue `
      -Value $start `
      -Name 'linuxIdentity'
    linuxProcessGroupId = Get-RimsObjectPropertyValue `
      -Value $start `
      -Name 'linuxProcessGroupId'
    cleanupPending = $true
  }
  $failureDetail = $null
  try {
    $ready = if ($null -eq $ReadinessAction) {
      $deadline = (Get-Date).AddSeconds(15)
      $isReady = $false
      do {
        if (Test-RimsTcpPortListening -Port $TlsPort -TimeoutMilliseconds 250) {
          $isReady = $true
          break
        }
        Start-Sleep -Milliseconds 100
      } while ((Get-Date) -lt $deadline)
      $isReady
    } else {
      [bool](& $ReadinessAction $state)
    }
  } catch {
    $ready = $false
    $failureDetail = "TLS proxy readiness check failed: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
  }
  $testPortOwnership = if ($null -eq $PortOwnershipAction) {
    { param($port, $processId)
      Test-RimsLocalTlsLinuxPortOwnership `
        -TlsState $state `
        -Port $port
    }
  } else { $PortOwnershipAction }
  $portOwned = $false
  if ($null -eq $failureDetail -and $ready) {
    try {
      $portOwned = [bool](& $testPortOwnership $TlsPort $state.windowsPid)
    } catch {
      $failureDetail = "TLS proxy port ownership check failed: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
    }
  }
  if (-not $ready -or -not $portOwned) {
    try {
      $stopResult = Stop-RimsLocalTlsProxy `
        -TlsState $state `
        -StopAction $StopAction
    } catch {
      $stopResult = [pscustomobject]@{
        ok = $false
        detail = ConvertTo-RimsDiagnosticSummary `
          -StandardOutput '' `
          -StandardError $_.Exception.Message
      }
    }
    $stopOk = [bool](Get-RimsObjectPropertyValue `
        -Value $stopResult `
        -Name 'ok' `
        -DefaultValue $false)
    $state.cleanupPending = -not $stopOk
    return [pscustomobject][ordered]@{
      ok = $false
      detail = "$(if ($null -ne $failureDetail) {
        $failureDetail
      } elseif (-not $portOwned) {
        'TLS listener was not owned by the recorded process.'
      } else { 'TLS proxy did not become ready.' })$(if (-not $stopOk) {
          " Proxy cleanup remains pending: $([string](Get-RimsObjectPropertyValue -Value $stopResult -Name 'detail' -DefaultValue 'unknown stop failure'))."
        })"
      cleanupPending = -not $stopOk
      state = if ($stopOk) { $null } else { $state }
    }
  }
  $state.cleanupPending = $false
  return [pscustomobject]@{
    ok = $true
    detail = "Owned HTTPS proxy is listening on port $TlsPort."
    state = $state
  }
}

function Get-RimsProcessCommandLine {
  param([Parameter(Mandatory = $true)][int]$ProcessId)

  try {
    return [string](Get-CimInstance Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction Stop).CommandLine
  } catch {
    return ''
  }
}

function Test-RimsLocalTlsLinuxPortOwnership {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsState,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port
  )

  if (-not (Test-RimsStateOwnsLinuxProcess -State $TlsState)) {
    return $false
  }
  $leaderPid = [string]$TlsState.linuxIdentity.leaderPid
  $wsl = Resolve-RimsCommandPath -Name 'wsl.exe'
  if ([string]::IsNullOrWhiteSpace($wsl)) {
    return $false
  }
  $probe = @'
set -euo pipefail
pid=$1
port=$2
case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
case "$port" in ''|*[!0-9]*) exit 2 ;; esac
if [ ! -d "/proc/$pid/fd" ]; then
  exit 3
fi
port_hex=$(printf '%04X' "$port")
endpoint="0100007F:$port_hex"
for descriptor in "/proc/$pid/fd/"*; do
  target=$(readlink "$descriptor" 2>/dev/null || true)
  inode=$(printf '%s' "$target" | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p')
  if [ -n "$inode" ] && awk -v endpoint="$endpoint" -v inode="$inode" '
      $2 == endpoint && $4 == "0A" && $10 == inode { found = 1 }
      END { exit(found ? 0 : 1) }
    ' /proc/net/tcp; then
    exit 0
  fi
done
exit 4
'@
  $result = Invoke-RimsExternalCommand `
    -FilePath $wsl `
    -Arguments @(
      '-e', 'bash', '-c', $probe,
      'rims-local-tls-port-owner', $leaderPid, [string]$Port
    ) `
    -TimeoutSeconds 10
  return $result.ExitCode -eq 0
}

function Test-RimsLocalTlsProxyOwnership {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsState,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$ProcessOwnershipAction,
    [AllowNull()][scriptblock]$PortOwnershipAction,
    [AllowNull()][scriptblock]$CommandLineAction,
    [AllowNull()][scriptblock]$LinuxOwnershipAction,
    [AllowNull()][scriptblock]$LinuxPortOwnershipAction
  )

  $processOwnership = if ($null -eq $ProcessOwnershipAction) {
    [pscustomobject]@{
      ok = Test-RimsStateOwnsProcess -State $TlsState
      pidMatches = $null
      startTimeMatches = $null
    }
  } else {
    $outcome = & $ProcessOwnershipAction $TlsState
    if ($outcome -is [bool]) {
      [pscustomobject]@{ ok = $outcome; pidMatches = $null; startTimeMatches = $null }
    } else {
      [pscustomobject]@{
        ok = [bool](Get-RimsObjectPropertyValue -Value $outcome -Name 'ok' -DefaultValue $false)
        pidMatches = Get-RimsObjectPropertyValue -Value $outcome -Name 'pidMatches'
        startTimeMatches = Get-RimsObjectPropertyValue -Value $outcome -Name 'startTimeMatches'
      }
    }
  }
  $processOwned = [bool]$processOwnership.ok
  if (-not $processOwned) {
    $detail = if ($processOwnership.pidMatches -eq $false) {
      'TLS PID ownership does not match.'
    } elseif ($processOwnership.startTimeMatches -eq $false) {
      'TLS process start time ownership does not match.'
    } else {
      'TLS PID/start-time ownership does not match.'
    }
    return [pscustomobject]@{ ok = $false; detail = $detail }
  }
  $linuxOwned = if ($null -eq $LinuxOwnershipAction) {
    Test-RimsStateOwnsLinuxProcess -State $TlsState
  } else { [bool](& $LinuxOwnershipAction $TlsState) }
  if (-not $linuxOwned) {
    return [pscustomobject]@{
      ok = $false
      detail = 'TLS Linux process identity or command marker does not match.'
    }
  }
  $processId = [int]$TlsState.windowsPid
  $portOwned = if ($null -eq $PortOwnershipAction) {
    Test-RimsTcpPortListening -Port ([int]$TlsState.port)
  } else { [bool](& $PortOwnershipAction ([int]$TlsState.port) $processId) }
  if (-not $portOwned) {
    return [pscustomobject]@{ ok = $false; detail = 'TLS loopback port is not reachable from Windows.' }
  }
  $linuxPortOwned = if ($null -eq $LinuxPortOwnershipAction) {
    Test-RimsLocalTlsLinuxPortOwnership `
      -TlsState $TlsState `
      -Port ([int]$TlsState.port)
  } else {
    [bool](& $LinuxPortOwnershipAction ([int]$TlsState.port) $TlsState)
  }
  if (-not $linuxPortOwned) {
    return [pscustomobject]@{
      ok = $false
      detail = 'TLS Linux listener is not owned by the recorded process identity.'
    }
  }
  $commandLine = if ($null -eq $CommandLineAction) {
    Get-RimsProcessCommandLine -ProcessId $processId
  } else { [string](& $CommandLineAction $processId) }
  $marker = "rims-local-tls-proxy:$($TlsPaths.workspaceId)"
  $proxyBinaryWslPath = [string](Get-RimsObjectPropertyValue `
      -Value $TlsState `
      -Name 'proxyBinaryWslPath' `
      -DefaultValue '')
  $commandOwned = $commandLine.Contains($marker) -and
    $commandLine.Contains('wsl') -and
    -not [string]::IsNullOrWhiteSpace($proxyBinaryWslPath) -and
    $commandLine.Contains($proxyBinaryWslPath)
  return [pscustomobject]@{
    ok = $commandOwned
    detail = if ($commandOwned) {
      'TLS Windows wrapper, Linux identity, loopback port, command line, and workspace marker match.'
    } else { 'TLS command line or workspace marker does not match.' }
  }
}

function New-RimsLocalTlsComponent {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][bool]$Required,
    [AllowNull()][scriptblock]$OwnershipAction,
    [AllowNull()][scriptblock]$CertificateAction
  )

  $tlsState = Get-RimsObjectPropertyValue -Value $State -Name 'localTls'
  if ($null -eq $tlsState) {
    return [pscustomobject][ordered]@{
      name = 'localTls'
      ok = -not $Required
      required = $Required
      detail = if ($Required) {
        'Local HTTPS was requested, but no owned TLS state exists.'
      } else { 'Local HTTPS is not enabled for this runtime.' }
      remediation = if ($Required) { 'Run up with -UseLocalTls.' } else { '' }
      enabled = $false
      workspaceId = $TlsPaths.workspaceId
      port = $null
      caFingerprintSha256 = $null
      serverFingerprintSha256 = $null
      serverSpkiSha256 = $null
      requiredSans = @()
      proxyOwned = $false
      certificateValid = $false
      cleanupPending = $false
    }
  }
  $proxyState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'proxy'
  $cleanupPending = [bool](Get-RimsObjectPropertyValue `
      -Value $tlsState `
      -Name 'cleanupPending' `
      -DefaultValue $false)
  $ownedResult = if ($null -eq $proxyState) {
    [pscustomobject]@{
      ok = $false
      detail = if ($cleanupPending) {
        'TLS proxy ownership state is incomplete while cleanup is pending.'
      } else { 'TLS proxy ownership state is missing.' }
    }
  } elseif ($null -eq $OwnershipAction) {
    Test-RimsLocalTlsProxyOwnership `
      -TlsState $proxyState `
      -TlsPaths $TlsPaths
  } else { & $OwnershipAction $proxyState $TlsPaths }
  $serverCertificatePath = [string](Get-RimsObjectPropertyValue `
      -Value $tlsState `
      -Name 'serverCertificatePath' `
      -DefaultValue '')
  $caCertificatePath = [string](Get-RimsObjectPropertyValue `
      -Value $tlsState `
      -Name 'caCertificatePath' `
      -DefaultValue '')
  $certificateResult = if ($null -ne $CertificateAction) {
    & $CertificateAction $tlsState
  } elseif ([string]::IsNullOrWhiteSpace($serverCertificatePath) -or
      [string]::IsNullOrWhiteSpace($caCertificatePath)) {
    [pscustomobject]@{
      ok = $false
      detail = 'TLS certificate state is incomplete.'
    }
  } else {
    Test-RimsLocalTlsCertificate `
      -CertificatePath $serverCertificatePath `
      -CaCertificatePath $caCertificatePath `
      -HostName 'localhost'
  }
  $ok = [bool]$ownedResult.ok -and [bool]$certificateResult.ok
  $recordedPort = Get-RimsObjectPropertyValue -Value $tlsState -Name 'port'
  return [pscustomobject][ordered]@{
    name = 'localTls'
    ok = $ok
    required = $Required
    detail = if ($ok) {
      'Owned local HTTPS proxy and certificate evidence are valid.'
    } else {
      "$($ownedResult.detail) $($certificateResult.detail)".Trim()
    }
    remediation = if ($ok) { '' } else {
      'Run down with the recorded runtime parameters, then retry up with -UseLocalTls.'
    }
    enabled = $true
    workspaceId = [string](Get-RimsObjectPropertyValue `
        -Value $tlsState `
        -Name 'workspaceId' `
        -DefaultValue $TlsPaths.workspaceId)
    port = if ($null -eq $recordedPort) { $null } else { [int]$recordedPort }
    caFingerprintSha256 = [string](Get-RimsObjectPropertyValue `
        -Value $tlsState `
        -Name 'caFingerprintSha256' `
        -DefaultValue '')
    serverFingerprintSha256 = [string](Get-RimsObjectPropertyValue `
        -Value $tlsState `
        -Name 'serverFingerprintSha256' `
        -DefaultValue '')
    serverSpkiSha256 = [string](Get-RimsObjectPropertyValue `
        -Value $tlsState `
        -Name 'serverSpkiSha256' `
        -DefaultValue '')
    requiredSans = @(Get-RimsObjectPropertyValue `
        -Value $tlsState `
        -Name 'requiredSans' `
        -DefaultValue @())
    proxyOwned = [bool]$ownedResult.ok
    certificateValid = [bool]$certificateResult.ok
    cleanupPending = $cleanupPending
  }
}

function Stop-RimsLocalTlsProxy {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsState,
    [AllowNull()][scriptblock]$StopAction
  )

  if ($null -ne $StopAction) {
    return & $StopAction $TlsState
  }
  try {
    $stopped = Stop-RimsOwnedBackendProcess -State $TlsState
    return [pscustomobject]@{
      ok = [bool]$stopped
      stopped = [bool]$stopped
      detail = if ($stopped) {
        'Stopped the exactly owned Windows WSL wrapper and Linux TLS process group.'
      } else {
        'Could not stop the exactly owned WSL Go TLS proxy.'
      }
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      stopped = $false
      detail = ConvertTo-RimsDiagnosticSummary `
        -StandardOutput '' `
        -StandardError $_.Exception.Message
    }
  }
}

function Invoke-RimsAdbCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $adb = Resolve-RimsAndroidTool `
    -CommandName 'adb.exe' `
    -SdkRelativePath 'platform-tools\adb.exe'
  $result = Invoke-RimsExternalCommand `
    -FilePath $adb `
    -Arguments (@('-s', $Serial) + $Arguments) `
    -TimeoutSeconds 30
  return [pscustomobject]@{
    exitCode = $result.ExitCode
    stdout = $result.StandardOutput
    stderr = $result.StandardError
  }
}

function Get-RimsAndroidCaRemotePath {
  param([Parameter(Mandatory = $true)][string]$SubjectHash)
  if ($SubjectHash -notmatch '\A[0-9a-fA-F]{8}\z') {
    throw 'Android CA subject hash must contain exactly eight hexadecimal characters.'
  }
  return "/data/misc/user/0/cacerts-added/$($SubjectHash.ToLowerInvariant()).0"
}

function Get-RimsAndroidCaTemporaryPath {
  param([Parameter(Mandatory = $true)][string]$WorkspaceId)
  if ($WorkspaceId -notmatch '\A[0-9a-fA-F]{16}\z') {
    throw 'TLS workspace ID must contain exactly sixteen hexadecimal characters.'
  }
  return "/data/local/tmp/rims-$($WorkspaceId.ToLowerInvariant())-ca.pem"
}

function Set-RimsLocalTlsCleanupPending {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][bool]$Value
  )

  $State | Add-Member `
    -MemberType NoteProperty `
    -Name cleanupPending `
    -Value $Value `
    -Force
}

function Test-RimsOwnedEmulatorState {
  param([Parameter(Mandatory = $true)][psobject]$EmulatorState)

  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $EmulatorState `
      -Name 'owned' `
      -DefaultValue $false)) {
    return $false
  }
  $container = [pscustomobject]@{ emulator = $EmulatorState }
  return Test-RimsNestedOwnedProcess -State $container -PropertyName 'emulator'
}

function Invoke-RimsAndroidPathPresenceQuery {
  param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][scriptblock]$AdbAction
  )

  $sentinelScript = 'if [ -f "$1" ]; then printf EXISTS; else printf ABSENT; fi'
  try {
    $result = & $AdbAction $Serial @(
      'shell', 'sh', '-c', $sentinelScript, 'rims-ca-query', $Path
    )
  } catch {
    return [pscustomobject]@{
      ok = $false
      present = $null
      detail = "Android path sentinel threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
    }
  }
  $exitCode = [int](Get-RimsObjectPropertyValue `
      -Value $result -Name 'exitCode' -DefaultValue -1)
  $stdout = [string](Get-RimsObjectPropertyValue `
      -Value $result -Name 'stdout' -DefaultValue '')
  $stderr = [string](Get-RimsObjectPropertyValue `
      -Value $result -Name 'stderr' -DefaultValue '')
  if ($exitCode -ne 0 -or $stderr.Length -ne 0 -or
      $stdout -notin @('EXISTS', 'ABSENT')) {
    return [pscustomobject]@{
      ok = $false
      present = $null
      detail = 'Android path sentinel returned indeterminate output.'
    }
  }
  return [pscustomobject]@{
    ok = $true
    present = $stdout -ceq 'EXISTS'
    detail = "Android path sentinel returned $stdout."
  }
}

function Install-RimsAndroidUserCa {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][psobject]$EmulatorState,
    [Parameter(Mandatory = $true)][string]$CaFingerprintSha256,
    [AllowNull()][AllowEmptyString()][string]$CaSubjectHash,
    [AllowNull()][scriptblock]$EmulatorOwnershipAction,
    [AllowNull()][scriptblock]$TrustQueryAction,
    [AllowNull()][scriptblock]$AdbAction
  )

  try {
    $owned = if ($null -eq $EmulatorOwnershipAction) {
      Test-RimsOwnedEmulatorState -EmulatorState $EmulatorState
    } else { [bool](& $EmulatorOwnershipAction $EmulatorState) }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "Could not verify exact emulator ownership: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  if (-not $owned) {
    return [pscustomobject]@{ ok = $false; detail = 'Android CA install requires an exactly owned emulator.' }
  }
  $serial = [string]$EmulatorState.serial
  try {
    $subjectHash = if ([string]::IsNullOrWhiteSpace($CaSubjectHash)) {
      $TlsPaths.workspaceId.Substring(0, 8)
    } else { $CaSubjectHash }
    $remotePath = Get-RimsAndroidCaRemotePath -SubjectHash $subjectHash
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "Android CA identity is invalid: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  $adb = if ($null -eq $AdbAction) {
    { param($device, $arguments) Invoke-RimsAdbCommand -Serial $device -Arguments $arguments }
  } else { $AdbAction }
  try {
    $alreadyTrusted = if ($null -eq $TrustQueryAction) {
      $rootResult = & $adb $serial @('root')
      if ([int]$rootResult.exitCode -ne 0) {
        return [pscustomobject]@{
          ok = $false
          detail = 'Could not inspect Android user trust without root on the owned emulator.'
          cleanupPending = $false
          state = $null
        }
      }
      $query = Invoke-RimsAndroidPathPresenceQuery `
        -Serial $serial `
        -Path $remotePath `
        -AdbAction $adb
      if (-not $query.ok) {
        return [pscustomobject]@{
          ok = $false
          detail = 'Android trust query was indeterminate; existing trust was left unchanged.'
          cleanupPending = $false
          state = $null
        }
      }
      if ($query.present) {
        $existingPath = Join-Path $TlsPaths.root 'android-existing-ca.pem'
        try {
          $pull = & $adb $serial @('pull', $remotePath, $existingPath)
          if ([int]$pull.exitCode -ne 0) {
            return [pscustomobject]@{
              ok = $false
              detail = 'Could not compare the pre-existing Android trust certificate.'
              cleanupPending = $false
              state = $null
            }
          }
          $existingFingerprint = Get-RimsLocalTlsCertificateFingerprint `
            -CertificatePath $existingPath
          if ($existingFingerprint -ne $CaFingerprintSha256) {
            return [pscustomobject]@{
              ok = $false
              detail = 'Android trust path is occupied by a different certificate; it was left untouched.'
              cleanupPending = $false
              state = $null
            }
          }
          $true
        } finally {
          Remove-Item -LiteralPath $existingPath -Force -ErrorAction SilentlyContinue
        }
      } else {
        $false
      }
    } else { [bool](& $TrustQueryAction $serial $CaFingerprintSha256) }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "Could not inspect Android trust safely: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  if ($alreadyTrusted) {
    return [pscustomobject]@{
      ok = $true
      detail = 'The workspace CA was already trusted and remains user-managed.'
      state = [pscustomobject][ordered]@{
        serial = $serial
        fingerprintSha256 = $CaFingerprintSha256
        subjectHash = $subjectHash
        remotePath = $remotePath
        preExisting = $true
        installedByController = $false
      }
    }
  }
  $temporaryPath = Get-RimsAndroidCaTemporaryPath `
    -WorkspaceId ([string]$TlsPaths.workspaceId)
  $trustState = [pscustomobject][ordered]@{
    serial = $serial
    fingerprintSha256 = $CaFingerprintSha256
    subjectHash = $subjectHash
    remotePath = $remotePath
    temporaryPath = $temporaryPath
    preExisting = $false
    installedByController = $true
    remoteMutationAttempted = $false
    cleanupPending = $true
  }
  $commands = @(
    @('root'),
    @('push', [string]$TlsPaths.caCertificate, $temporaryPath),
    @('shell', 'mkdir', '-p', '/data/misc/user/0/cacerts-added'),
    @('shell', 'cp', $temporaryPath, $remotePath),
    @('shell', 'chmod', '644', $remotePath),
    @('shell', 'chown', 'system:system', $remotePath),
    @('shell', 'restorecon', $remotePath),
    @('shell', 'rm', '-f', $temporaryPath)
  )
  foreach ($arguments in $commands) {
    if ($arguments[0] -eq 'shell' -and $arguments[1] -eq 'cp') {
      $trustState.remoteMutationAttempted = $true
    }
    $operationDetail = 'Failed to install the owned CA on the owned emulator.'
    try {
      $result = & $adb $serial $arguments
      $operationOk = [int](Get-RimsObjectPropertyValue `
          -Value $result `
          -Name 'exitCode' `
          -DefaultValue -1) -eq 0
    } catch {
      $operationOk = $false
      $operationDetail = "Android CA install action threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
    }
    if (-not $operationOk) {
      $compensationOk = $true
      if ($trustState.remoteMutationAttempted) {
        try {
          $removeRemote = & $adb $serial @('shell', 'rm', '-f', $remotePath)
          $remoteCleanupOk = [int](Get-RimsObjectPropertyValue `
              -Value $removeRemote `
              -Name 'exitCode' `
              -DefaultValue -1) -eq 0
        } catch {
          $remoteCleanupOk = $false
        }
        $compensationOk = $compensationOk -and $remoteCleanupOk
      }
      try {
        $removeTemporary = & $adb $serial @('shell', 'rm', '-f', $temporaryPath)
        $temporaryCleanupOk = [int](Get-RimsObjectPropertyValue `
            -Value $removeTemporary `
            -Name 'exitCode' `
            -DefaultValue -1) -eq 0
      } catch {
        $temporaryCleanupOk = $false
      }
      $compensationOk = $compensationOk -and $temporaryCleanupOk
      $trustState.cleanupPending = -not $compensationOk
      return [pscustomobject][ordered]@{
        ok = $false
        detail = if ($compensationOk) {
          "$operationDetail Partial Android mutations were removed."
        } else {
          "$operationDetail Android cleanup remains pending."
        }
        cleanupPending = -not $compensationOk
        state = if ($compensationOk) { $null } else { $trustState }
      }
    }
  }
  $trustState.cleanupPending = $false
  return [pscustomobject]@{
    ok = $true
    detail = 'Installed the workspace CA in the owned emulator user trust store.'
    cleanupPending = $false
    state = $trustState
  }
}

function Remove-RimsAndroidUserCa {
  param(
    [Parameter(Mandatory = $true)][psobject]$TrustState,
    [Parameter(Mandatory = $true)][psobject]$EmulatorState,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$EmulatorOwnershipAction,
    [AllowNull()][scriptblock]$AdbAction,
    [AllowNull()][scriptblock]$FingerprintAction,
    [AllowNull()][scriptblock]$SubjectHashAction
  )

  $cleanupScope = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'cleanupScope' `
      -DefaultValue '')
  if ($cleanupScope -eq 'temporaryOnly') {
    try {
      $fixedTemporaryPath = Get-RimsAndroidCaTemporaryPath `
        -WorkspaceId ([string]$TlsPaths.workspaceId)
    } catch {
      return [pscustomobject]@{
        ok = $false
        detail = 'Deterministic Android temp cleanup path is invalid; no ADB command was issued.'
        cleanupPending = $true
        state = $TrustState
      }
    }
    $recordedTemporaryPath = [string](Get-RimsObjectPropertyValue `
        -Value $TrustState `
        -Name 'temporaryPath' `
        -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($recordedTemporaryPath) -and
        $recordedTemporaryPath -cne $fixedTemporaryPath) {
      return [pscustomobject]@{
        ok = $false
        detail = 'Recorded Android temp cleanup path does not match this workspace; no ADB command was issued.'
        cleanupPending = $true
        state = $TrustState
      }
    }
    $TrustState | Add-Member `
      -MemberType NoteProperty `
      -Name temporaryPath `
      -Value $fixedTemporaryPath `
      -Force
    try {
      $owned = if ($null -eq $EmulatorOwnershipAction) {
        Test-RimsOwnedEmulatorState -EmulatorState $EmulatorState
      } else { [bool](& $EmulatorOwnershipAction $EmulatorState) }
    } catch {
      $owned = $false
    }
    $recordedSerial = [string](Get-RimsObjectPropertyValue `
        -Value $TrustState `
        -Name 'serial' `
        -DefaultValue '')
    $emulatorSerial = [string](Get-RimsObjectPropertyValue `
        -Value $EmulatorState `
        -Name 'serial' `
        -DefaultValue '')
    if (-not $owned -or [string]::IsNullOrWhiteSpace($recordedSerial) -or
        $recordedSerial -ne $emulatorSerial) {
      Set-RimsLocalTlsCleanupPending -State $TrustState -Value $true
      return [pscustomobject]@{
        ok = $false
        detail = 'Android temp cleanup requires the exact owned emulator and recorded serial.'
        cleanupPending = $true
        state = $TrustState
      }
    }
    $adb = if ($null -eq $AdbAction) {
      { param($device, $arguments) Invoke-RimsAdbCommand -Serial $device -Arguments $arguments }
    } else { $AdbAction }
    try {
      $rootResult = & $adb $recordedSerial @('root')
      $removeResult = if ([int](Get-RimsObjectPropertyValue `
          -Value $rootResult `
          -Name 'exitCode' `
          -DefaultValue -1) -eq 0) {
        & $adb $recordedSerial @('shell', 'rm', '-f', $fixedTemporaryPath)
      } else { $null }
      $removed = $null -ne $removeResult -and
        [int](Get-RimsObjectPropertyValue `
          -Value $removeResult `
          -Name 'exitCode' `
          -DefaultValue -1) -eq 0
    } catch {
      $removed = $false
    }
    if (-not $removed) {
      Set-RimsLocalTlsCleanupPending -State $TrustState -Value $true
      return [pscustomobject]@{
        ok = $false
        detail = 'Deterministic Android temp PEM cleanup remains pending.'
        cleanupPending = $true
        state = $TrustState
      }
    }
    return [pscustomobject]@{
      ok = $true
      detail = 'Removed the deterministic Android temp PEM without touching remote trust.'
      cleanupPending = $false
    }
  }

  if (-not [bool](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'installedByController' `
      -DefaultValue $false)) {
    return [pscustomobject]@{
      ok = $true
      detail = 'Pre-existing Android trust was preserved.'
    }
  }
  if (-not (Test-RimsLocalTlsRuntimePath `
      -Path ([string]$TlsPaths.caCertificate) `
      -TlsPaths $TlsPaths) -or
      -not (Test-Path -LiteralPath $TlsPaths.caCertificate -PathType Leaf)) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Workspace CA certificate is unavailable for Android trust ownership verification; no ADB command was issued.'
      cleanupPending = $true
      state = $TrustState
    }
  }
  try {
    $getLocalFingerprint = if ($null -eq $FingerprintAction) {
      { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
    } else { $FingerprintAction }
    $getLocalSubjectHash = if ($null -eq $SubjectHashAction) {
      { param($path) Get-RimsLocalTlsSubjectHash -CertificatePath $path }
    } else { $SubjectHashAction }
    $localCaFingerprint = [string](& $getLocalFingerprint $TlsPaths.caCertificate)
    $localCaSubjectHash = [string](& $getLocalSubjectHash $TlsPaths.caCertificate)
    $fixedRemotePath = Get-RimsAndroidCaRemotePath `
      -SubjectHash $localCaSubjectHash
    $fixedTemporaryPath = Get-RimsAndroidCaTemporaryPath `
      -WorkspaceId ([string]$TlsPaths.workspaceId)
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = 'Workspace CA identity could not be recomputed safely; no ADB command was issued.'
      cleanupPending = $true
      state = $TrustState
    }
  }
  $subjectHash = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'subjectHash' `
      -DefaultValue '')
  $recordedFingerprint = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'fingerprintSha256' `
      -DefaultValue '')
  if ($subjectHash -notmatch '\A[0-9a-fA-F]{8}\z' -or
      $recordedFingerprint -notmatch '\A[0-9a-fA-F]{64}\z' -or
      $subjectHash -ine $localCaSubjectHash -or
      $recordedFingerprint -ine $localCaFingerprint) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Recorded Android trust identity does not match the workspace CA; no ADB command was issued.'
      cleanupPending = $true
      state = $TrustState
    }
  }
  $recordedRemotePath = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'remotePath' `
      -DefaultValue '')
  $recordedTemporaryPath = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'temporaryPath' `
      -DefaultValue '')
  if ($recordedRemotePath -cne $fixedRemotePath -or
      (-not [string]::IsNullOrWhiteSpace($recordedTemporaryPath) -and
        $recordedTemporaryPath -cne $fixedTemporaryPath)) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Recorded Android trust paths do not match deterministic workspace paths; no ADB command was issued.'
      cleanupPending = $true
      state = $TrustState
    }
  }
  if ([string]::IsNullOrWhiteSpace($recordedTemporaryPath)) {
    $TrustState | Add-Member `
      -MemberType NoteProperty `
      -Name temporaryPath `
      -Value $fixedTemporaryPath `
      -Force
  }
  try {
    $owned = if ($null -eq $EmulatorOwnershipAction) {
      Test-RimsOwnedEmulatorState -EmulatorState $EmulatorState
    } else { [bool](& $EmulatorOwnershipAction $EmulatorState) }
  } catch {
    Set-RimsLocalTlsCleanupPending -State $TrustState -Value $true
    return [pscustomobject]@{
      ok = $false
      detail = "Could not verify exact emulator ownership: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $true
      state = $TrustState
    }
  }
  if (-not $owned) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Owned Android trust could not be removed because emulator ownership no longer matches.'
    }
  }
  $recordedSerial = [string](Get-RimsObjectPropertyValue `
      -Value $TrustState `
      -Name 'serial' `
      -DefaultValue '')
  $emulatorSerial = [string](Get-RimsObjectPropertyValue `
      -Value $EmulatorState `
      -Name 'serial' `
      -DefaultValue '')
  if ([string]::IsNullOrWhiteSpace($recordedSerial) -or
      $recordedSerial -ne $emulatorSerial) {
    return [pscustomobject]@{
      ok = $false
      detail = 'Owned Android trust cleanup requires the exact recorded emulator serial.'
      cleanupPending = $true
      state = $TrustState
    }
  }
  $adb = if ($null -eq $AdbAction) {
    { param($device, $arguments) Invoke-RimsAdbCommand -Serial $device -Arguments $arguments }
  } else { $AdbAction }
  $remotePath = $fixedRemotePath
  $temporaryPath = $fixedTemporaryPath
  $pending = {
    param($detail)
    Set-RimsLocalTlsCleanupPending -State $TrustState -Value $true
    return [pscustomobject]@{
      ok = $false
      detail = $detail
      cleanupPending = $true
      state = $TrustState
    }
  }
  try {
    $rootResult = & $adb $recordedSerial @('root')
  } catch {
    return & $pending "Android root action threw during trust cleanup: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
  }
  if ([int](Get-RimsObjectPropertyValue -Value $rootResult -Name 'exitCode' -DefaultValue -1) -ne 0) {
    return & $pending 'Could not verify Android trust cleanup with root on the exact owned emulator.'
  }
  $remoteFailure = $null
  try {
    $query = Invoke-RimsAndroidPathPresenceQuery `
      -Serial $recordedSerial `
      -Path $remotePath `
      -AdbAction $adb
  } catch {
    $query = [pscustomobject]@{ ok = $false; present = $null }
    $remoteFailure = "Android trust query threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
  }
  $pulledPath = Join-Path $TlsPaths.root 'android-remove-ca.pem'
  [void][IO.Directory]::CreateDirectory([string]$TlsPaths.root)
  try {
    if (-not $query.ok) {
      if ($null -eq $remoteFailure) {
        $remoteFailure = 'Could not query the recorded Android trust path.'
      }
    } elseif ($query.present) {
      try {
        $pull = & $adb $recordedSerial @('pull', $remotePath, $pulledPath)
        $pullOk = [int](Get-RimsObjectPropertyValue `
            -Value $pull `
            -Name 'exitCode' `
            -DefaultValue -1) -eq 0
      } catch {
        $pullOk = $false
      }
      if (-not $pullOk) {
        $remoteFailure = 'Could not pull the recorded Android CA for fingerprint verification.'
      } else {
        $getFingerprint = if ($null -eq $FingerprintAction) {
          { param($path) Get-RimsLocalTlsCertificateFingerprint -CertificatePath $path }
        } else { $FingerprintAction }
        try {
          $remoteFingerprint = [string](& $getFingerprint $pulledPath)
          $fingerprintOk = $remoteFingerprint -eq [string]$TrustState.fingerprintSha256
        } catch {
          $fingerprintOk = $false
          $remoteFailure = "Android CA fingerprint verification threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
        }
        if (-not $fingerprintOk -and $null -eq $remoteFailure) {
          $remoteFailure = 'The recorded Android trust path now contains a different certificate; it was left untouched.'
        } elseif ($fingerprintOk) {
          try {
            $remove = & $adb $recordedSerial @('shell', 'rm', '-f', $remotePath)
            $remoteRemoveOk = [int](Get-RimsObjectPropertyValue `
                -Value $remove `
                -Name 'exitCode' `
                -DefaultValue -1) -eq 0
          } catch {
            $remoteRemoveOk = $false
          }
          if (-not $remoteRemoveOk) {
            $remoteFailure = 'Failed to remove the verified controller-installed Android CA.'
          }
        }
      }
    }
    try {
      $removeTemporary = & $adb $recordedSerial @(
        'shell', 'rm', '-f', $temporaryPath
      )
      $temporaryOk = [int](Get-RimsObjectPropertyValue `
          -Value $removeTemporary `
          -Name 'exitCode' `
          -DefaultValue -1) -eq 0
    } catch {
      $temporaryOk = $false
    }
    if ($null -ne $remoteFailure -or -not $temporaryOk) {
      $detailParts = @()
      if ($null -ne $remoteFailure) { $detailParts += $remoteFailure }
      if (-not $temporaryOk) {
        $detailParts += 'Failed to remove the deterministic Android temp CA PEM.'
      }
      return & $pending ($detailParts -join ' ')
    }
    return [pscustomobject]@{
      ok = $true
      detail = 'Removed deterministic controller-owned Android CA and temp PEM state.'
      cleanupPending = $false
    }
  } finally {
    Remove-Item -LiteralPath $pulledPath -Force -ErrorAction SilentlyContinue
  }
}

function Remove-RimsLocalTlsCertificates {
  param([Parameter(Mandatory = $true)][psobject]$TlsPaths)

  try {
    if (Test-Path -LiteralPath $TlsPaths.root) {
      Remove-Item -LiteralPath $TlsPaths.root -Recurse -Force
    }
    return [pscustomobject]@{ ok = $true; detail = 'Removed owned local TLS material.' }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message
    }
  }
}

function Stop-RimsLocalTlsRuntime {
  param(
    [Parameter(Mandatory = $true)][psobject]$State,
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [AllowNull()][scriptblock]$TrustRemoveAction,
    [AllowNull()][scriptblock]$OwnershipAction,
    [AllowNull()][scriptblock]$PortListeningAction,
    [AllowNull()][scriptblock]$ProxyStopAction,
    [AllowNull()][scriptblock]$CertificateCleanupAction
  )

  $tlsState = Get-RimsObjectPropertyValue -Value $State -Name 'localTls'
  if ($null -eq $tlsState) {
    return [pscustomobject]@{
      ok = $true
      detail = 'No owned local TLS runtime requires cleanup.'
      cleanupPending = $false
    }
  }
  $trustState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'androidTrust'
  $preserveCertificateMaterial = $null -ne $trustState -and
    [bool](Get-RimsObjectPropertyValue `
      -Value $trustState `
      -Name 'preExisting' `
      -DefaultValue $false)
  if ($null -ne $trustState) {
    $removeTrust = if ($null -eq $TrustRemoveAction) {
      { param($trust, $emulator)
        Remove-RimsAndroidUserCa `
          -TrustState $trust `
          -EmulatorState $emulator `
          -TlsPaths $TlsPaths
      }
    } else { $TrustRemoveAction }
    try {
      $trustResult = & $removeTrust $trustState $State.emulator
    } catch {
      $trustResult = [pscustomobject]@{
        ok = $false
        detail = "Android trust cleanup threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      }
    }
    if (-not $trustResult.ok) {
      $tlsState.cleanupPending = $true
      return [pscustomobject]@{
        ok = $false
        detail = $trustResult.detail
        cleanupPending = $true
      }
    }
    $tlsState.androidTrust = $null
  }

  $proxyState = Get-RimsObjectPropertyValue -Value $tlsState -Name 'proxy'
  if ($null -ne $proxyState) {
    try {
      $ownership = if ($null -eq $OwnershipAction) {
        Test-RimsLocalTlsProxyOwnership `
          -TlsState $proxyState `
          -TlsPaths $TlsPaths
      } else { & $OwnershipAction $proxyState $TlsPaths }
    } catch {
      $ownership = [pscustomobject]@{
        ok = $false
        detail = "TLS proxy ownership inspection threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      }
    }
    if (-not $ownership.ok) {
      $testListening = if ($null -eq $PortListeningAction) {
        { param($port) Test-RimsTcpPortListening -Port $port }
      } else { $PortListeningAction }
      try {
        $listenerStillPresent = [bool](& $testListening ([int]$proxyState.port))
      } catch {
        $listenerStillPresent = $true
        $ownership.detail = "$($ownership.detail) Port inspection threw; ownership remains unverified."
      }
      if ($listenerStillPresent) {
        $tlsState.cleanupPending = $true
        return [pscustomobject]@{
          ok = $false
          detail = "Refused to stop a TLS listener without exact ownership: $($ownership.detail)"
          cleanupPending = $true
        }
      }
    } else {
      $stopProxy = if ($null -eq $ProxyStopAction) {
        { param($proxy) Stop-RimsLocalTlsProxy -TlsState $proxy }
      } else { $ProxyStopAction }
      try {
        $proxyResult = & $stopProxy $proxyState
      } catch {
        $proxyResult = [pscustomobject]@{
          ok = $false
          detail = "TLS proxy stop threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
        }
      }
      if (-not $proxyResult.ok) {
        $tlsState.cleanupPending = $true
        return [pscustomobject]@{
          ok = $false
          detail = $proxyResult.detail
          cleanupPending = $true
        }
      }
    }
    $tlsState.proxy = $null
  }
  try {
    $cleanup = if ($preserveCertificateMaterial) {
      [pscustomobject]@{
        ok = $true
        detail = 'Preserved workspace CA material required by pre-existing trust.'
      }
    } elseif ($null -eq $CertificateCleanupAction) {
      Remove-RimsLocalTlsCertificates -TlsPaths $TlsPaths
    } else { & $CertificateCleanupAction $TlsPaths }
  } catch {
    $cleanup = [pscustomobject]@{
      ok = $false
      detail = "TLS certificate cleanup threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
    }
  }
  if (-not $cleanup.ok) {
    $tlsState.cleanupPending = $true
    return [pscustomobject]@{
      ok = $false
      detail = $cleanup.detail
      cleanupPending = $true
    }
  }
  $State.localTls = $null
  return [pscustomobject]@{
    ok = $true
    detail = if ($preserveCertificateMaterial) {
      'Removed the owned HTTPS proxy and preserved pre-existing trust and its CA material.'
    } else { 'Removed owned Android trust, HTTPS proxy, and TLS material.' }
    cleanupPending = $false
  }
}

function Invoke-RimsLocalTlsUp {
  param(
    [Parameter(Mandatory = $true)][psobject]$TlsPaths,
    [Parameter(Mandatory = $true)][int]$BackendPort,
    [Parameter(Mandatory = $true)][int]$TlsPort,
    [Parameter(Mandatory = $true)][ValidateSet('none', 'web', 'android')][string]$Target,
    [AllowNull()][object]$EmulatorState,
    [AllowNull()][scriptblock]$CertificateAction,
    [AllowNull()][scriptblock]$ProxyStartAction,
    [AllowNull()][scriptblock]$TrustInstallAction,
    [AllowNull()][scriptblock]$ProxyStopAction,
    [AllowNull()][scriptblock]$CertificateCleanupAction
  )

  $createCertificates = if ($null -eq $CertificateAction) {
    { param($paths) New-RimsLocalTlsCertificates -TlsPaths $paths }
  } else { $CertificateAction }
  $startProxy = if ($null -eq $ProxyStartAction) {
    { param($paths, $backendPortValue, $tlsPortValue)
      Start-RimsLocalTlsProxy -TlsPaths $paths -BackendPort $backendPortValue -TlsPort $tlsPortValue
    }
  } else { $ProxyStartAction }
  $stopProxy = if ($null -eq $ProxyStopAction) {
    { param($state) Stop-RimsLocalTlsProxy -TlsState $state }
  } else { $ProxyStopAction }
  $cleanupCertificates = if ($null -eq $CertificateCleanupAction) {
    { param($paths) Remove-RimsLocalTlsCertificates -TlsPaths $paths }
  } else { $CertificateCleanupAction }

  $certificates = & $createCertificates $TlsPaths
  if (-not $certificates.ok) {
    return [pscustomobject][ordered]@{
      ok = $false
      detail = $certificates.detail
      cleanupPending = [bool](Get-RimsObjectPropertyValue `
          -Value $certificates `
          -Name 'cleanupPending' `
          -DefaultValue $false)
      state = Get-RimsObjectPropertyValue -Value $certificates -Name 'state'
    }
  }
  $certificatesCreated = [bool](Get-RimsObjectPropertyValue `
      -Value $certificates `
      -Name 'created' `
      -DefaultValue $true)
  try {
    $proxy = & $startProxy $TlsPaths $BackendPort $TlsPort
  } catch {
    $proxy = [pscustomobject]@{
      ok = $false
      detail = "TLS proxy start action threw before identity was returned: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
      cleanupPending = $false
      state = $null
    }
  }
  if (-not $proxy.ok) {
    $certificateCleanupOk = $true
    if ($certificatesCreated) {
      try {
        $certificateCleanup = & $cleanupCertificates $TlsPaths
      } catch {
        $certificateCleanup = [pscustomobject]@{
          ok = $false
          detail = "TLS certificate cleanup threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
        }
      }
      $certificateCleanupOk = [bool](Get-RimsObjectPropertyValue `
          -Value $certificateCleanup `
          -Name 'ok' `
          -DefaultValue $false)
    }
    $proxyPending = [bool](Get-RimsObjectPropertyValue `
        -Value $proxy `
        -Name 'cleanupPending' `
        -DefaultValue $false)
    $cleanupPending = $proxyPending -or -not $certificateCleanupOk
    return [pscustomobject][ordered]@{
      ok = $false
      detail = $proxy.detail
      cleanupPending = $cleanupPending
      state = if ($cleanupPending) {
        [pscustomobject][ordered]@{
          workspaceId = $TlsPaths.workspaceId
          root = $TlsPaths.root
          port = $TlsPort
          backendPort = $BackendPort
          caCertificatePath = $certificates.caCertificatePath
          serverCertificatePath = $certificates.serverCertificatePath
          caFingerprintSha256 = $certificates.caFingerprintSha256
          serverFingerprintSha256 = $certificates.serverFingerprintSha256
          serverSpkiSha256 = $certificates.serverSpkiSha256
          caSubjectHash = $certificates.caSubjectHash
          certificateCreated = $certificatesCreated -and -not $certificateCleanupOk
          requiredSans = @($certificates.requiredSans)
          proxy = Get-RimsObjectPropertyValue -Value $proxy -Name 'state'
          androidTrust = $null
          cleanupPending = $true
        }
      } else { $null }
    }
  }
  $trust = $null
  if ($Target -eq 'android') {
    $installTrust = if ($null -eq $TrustInstallAction) {
      { param($paths, $emulator, $fingerprint, $subjectHash)
        Install-RimsAndroidUserCa `
          -TlsPaths $paths `
          -EmulatorState $emulator `
          -CaFingerprintSha256 $fingerprint `
          -CaSubjectHash $subjectHash
      }
    } else { $TrustInstallAction }
    $caSubjectHash = [string](Get-RimsObjectPropertyValue `
        -Value $certificates `
        -Name 'caSubjectHash' `
        -DefaultValue $TlsPaths.workspaceId.Substring(0, 8))
    try {
      $trust = & $installTrust `
        $TlsPaths `
        $EmulatorState `
        $certificates.caFingerprintSha256 `
        $caSubjectHash
    } catch {
      $trust = [pscustomobject]@{
        ok = $false
        detail = "Android trust install threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
        cleanupPending = $true
        state = [pscustomobject][ordered]@{
          serial = [string](Get-RimsObjectPropertyValue `
              -Value $EmulatorState `
              -Name 'serial' `
              -DefaultValue '')
          temporaryPath = Get-RimsAndroidCaTemporaryPath `
            -WorkspaceId ([string]$TlsPaths.workspaceId)
          cleanupScope = 'temporaryOnly'
          preExisting = $false
          installedByController = $false
          remoteMutationAttempted = $false
          cleanupPending = $true
        }
      }
    }
    if (-not $trust.ok) {
      try {
        $proxyCleanup = & $stopProxy $proxy.state
      } catch {
        $proxyCleanup = [pscustomobject]@{
          ok = $false
          detail = "TLS proxy cleanup threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
        }
      }
      $proxyCleanupOk = [bool](Get-RimsObjectPropertyValue `
          -Value $proxyCleanup `
          -Name 'ok' `
          -DefaultValue $false)
      $trustPending = [bool](Get-RimsObjectPropertyValue `
          -Value $trust `
          -Name 'cleanupPending' `
          -DefaultValue $false)
      $certificateCleanupOk = $true
      if ($certificatesCreated -and -not $trustPending) {
        try {
          $certificateCleanup = & $cleanupCertificates $TlsPaths
        } catch {
          $certificateCleanup = [pscustomobject]@{
            ok = $false
            detail = "TLS certificate cleanup threw: $(ConvertTo-RimsDiagnosticSummary -StandardOutput '' -StandardError $_.Exception.Message)"
          }
        }
        $certificateCleanupOk = [bool](Get-RimsObjectPropertyValue `
            -Value $certificateCleanup `
            -Name 'ok' `
            -DefaultValue $false)
      }
      $cleanupPending = $trustPending -or -not $proxyCleanupOk -or
        -not $certificateCleanupOk
      return [pscustomobject][ordered]@{
        ok = $false
        detail = $trust.detail
        cleanupPending = $cleanupPending
        state = if ($cleanupPending) {
          [pscustomobject][ordered]@{
            workspaceId = $TlsPaths.workspaceId
            root = $TlsPaths.root
            port = $TlsPort
            backendPort = $BackendPort
            caCertificatePath = $certificates.caCertificatePath
            serverCertificatePath = $certificates.serverCertificatePath
            caFingerprintSha256 = $certificates.caFingerprintSha256
            serverFingerprintSha256 = $certificates.serverFingerprintSha256
            serverSpkiSha256 = $certificates.serverSpkiSha256
            caSubjectHash = $caSubjectHash
            certificateCreated = $certificatesCreated -and
              ($trustPending -or -not $certificateCleanupOk)
            requiredSans = @($certificates.requiredSans)
            proxy = if ($proxyCleanupOk) { $null } else { $proxy.state }
            androidTrust = Get-RimsObjectPropertyValue -Value $trust -Name 'state'
            cleanupPending = $true
          }
        } else { $null }
      }
    }
  }
  return [pscustomobject]@{
    ok = $true
    detail = 'Local HTTPS runtime is ready.'
    state = [pscustomobject][ordered]@{
      workspaceId = $TlsPaths.workspaceId
      port = $TlsPort
      backendPort = $BackendPort
      caCertificatePath = $certificates.caCertificatePath
      serverCertificatePath = $certificates.serverCertificatePath
      caFingerprintSha256 = $certificates.caFingerprintSha256
      serverFingerprintSha256 = $certificates.serverFingerprintSha256
      serverSpkiSha256 = $certificates.serverSpkiSha256
      caSubjectHash = [string](Get-RimsObjectPropertyValue `
          -Value $certificates `
          -Name 'caSubjectHash' `
          -DefaultValue $TlsPaths.workspaceId.Substring(0, 8))
      certificateCreated = $certificatesCreated
      requiredSans = @($certificates.requiredSans)
      proxy = $proxy.state
      androidTrust = if ($null -eq $trust) { $null } else { $trust.state }
      cleanupPending = $false
    }
  }
}
