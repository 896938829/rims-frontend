import '../config/environment_profile.dart';

abstract final class ApiUrlPolicy {
  static Uri validate({
    required AppEnvironment environment,
    required String rawUrl,
    required bool allowLocalHttp,
  }) {
    if (rawUrl.isEmpty || rawUrl.trim() != rawUrl || !_isAscii(rawUrl)) {
      throw const FormatException('API_BASE_URL must be non-empty ASCII.');
    }
    if (rawUrl.startsWith('//') || rawUrl.contains(r'\')) {
      throw const FormatException('API_BASE_URL must be an absolute URL.');
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException(
        'API_BASE_URL must be an absolute HTTP or HTTPS URL.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
        'API_BASE_URL must not contain userinfo, query, or fragment data.',
      );
    }
    if (uri.hasPort) {
      final port = uri.port;
      if (port < 1 || port > 65535) {
        throw const FormatException(
          'API_BASE_URL port must be within the TCP port range.',
        );
      }
    }
    if (uri.path != '/api/v1') {
      throw const FormatException('API_BASE_URL path must be /api/v1.');
    }
    if (!_isAscii(uri.host) ||
        uri.authority.contains('%') ||
        uri.host.split('.').any((label) => label.startsWith('xn--')) ||
        _isAmbiguousNumericHost(uri.host)) {
      throw const FormatException('API_BASE_URL host must be plain ASCII.');
    }

    final localTarget = _isAllowedLocalTarget(uri.host);
    if (!environment.isLocal && _isNonPublicTarget(uri.host)) {
      throw const FormatException(
        'Staging and production cannot target a local API host.',
      );
    }

    if (uri.scheme == 'http') {
      if (!environment.isLocal || !allowLocalHttp || !localTarget) {
        throw const FormatException(
          'HTTP is allowed only for explicit local development targets.',
        );
      }
      if (!uri.hasPort) {
        throw const FormatException(
          'Local HTTP API_BASE_URL must use an explicit port.',
        );
      }
      return uri;
    }

    final allowedHTTPSPort =
        !uri.hasPort ||
        uri.port == 443 ||
        (environment.isLocal && localTarget && uri.port == 8443);
    if (!allowedHTTPSPort) {
      throw const FormatException(
        'API_BASE_URL uses an unexpected HTTPS port.',
      );
    }
    return uri;
  }

  static bool _isAscii(String value) {
    return value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);
  }

  static bool _isAllowedLocalTarget(String host) {
    final normalized = _normalizeHost(host);
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final ipv6 = _parseIPv6(normalized);
    if (ipv6 != null) {
      return _isAllowedLocalIPv6(ipv6);
    }

    final octets = _parseIPv4(normalized);
    return _isAllowedLocalIPv4(octets);
  }

  static bool _isAllowedLocalIPv6(List<int> bytes) {
    if (_isIPv6Loopback(bytes) || (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    final mappedIPv4 = _mappedIPv4(bytes);
    return _isAllowedLocalIPv4(mappedIPv4);
  }

  static bool _isAllowedLocalIPv4(List<int>? octets) {
    if (octets == null) return false;
    final first = octets[0];
    final second = octets[1];
    return first == 127 ||
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  static bool _isNonPublicTarget(String host) {
    final normalized = _normalizeHost(host);
    if (_isAllowedLocalTarget(normalized)) {
      return true;
    }
    final ipv6 = _parseIPv6(normalized);
    if (ipv6 != null) {
      final mappedIPv4 = _mappedIPv4(ipv6);
      return (mappedIPv4 != null && _isNonPublicIPv4(mappedIPv4)) ||
          ipv6.every((byte) => byte == 0) ||
          (ipv6[0] == 0xfe && (ipv6[1] & 0xc0) == 0x80) ||
          (ipv6[0] == 0xfe && (ipv6[1] & 0xc0) == 0xc0) ||
          _hasIPv6Prefix(ipv6, const [0x00], 8) ||
          _hasIPv6Prefix(ipv6, const [
            0x00,
            0x64,
            0xff,
            0x9b,
            0x00,
            0x01,
          ], 48) ||
          _hasIPv6Prefix(ipv6, const [
            0x01,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
          ], 64) ||
          _hasIPv6Prefix(ipv6, const [0x20, 0x01, 0x0d, 0xb8], 32) ||
          _hasIPv6Prefix(ipv6, const [0x20, 0x02], 16) ||
          _hasIPv6Prefix(ipv6, const [0x3f, 0xff, 0x00], 20) ||
          ipv6[0] == 0xff;
    }
    final octets = _parseIPv4(normalized);
    return octets != null && _isNonPublicIPv4(octets);
  }

  static bool _isNonPublicIPv4(List<int> octets) {
    final first = octets[0];
    final second = octets[1];
    final third = octets[2];
    return _isAllowedLocalIPv4(octets) ||
        first == 0 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 192 && second == 0 && third == 0) ||
        (first == 192 && second == 0 && third == 2) ||
        (first == 192 && second == 88 && third == 99) ||
        (first == 198 && (second == 18 || second == 19)) ||
        (first == 198 && second == 51 && third == 100) ||
        (first == 203 && second == 0 && third == 113) ||
        first >= 224;
  }

  static String _normalizeHost(String host) {
    var normalized = host.toLowerCase();
    if (normalized.startsWith('[') && normalized.endsWith(']')) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static bool _isAmbiguousNumericHost(String host) {
    final normalized = _normalizeHost(host);
    if (RegExp(r'^\d+$').hasMatch(normalized) || normalized.startsWith('0x')) {
      return true;
    }
    return RegExp(r'^[0-9.]+$').hasMatch(normalized) &&
        _parseIPv4(normalized) == null;
  }

  static List<int>? _parseIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) {
      return null;
    }
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
        return null;
      }
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) {
        return null;
      }
      octets.add(octet);
    }
    return octets;
  }

  static List<int>? _parseIPv6(String host) {
    if (!host.contains(':')) return null;
    try {
      return Uri.parseIPv6Address(host);
    } on FormatException {
      return null;
    }
  }

  static bool _isIPv6Loopback(List<int> bytes) {
    return bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  }

  static List<int>? _mappedIPv4(List<int> bytes) {
    if (!bytes.take(10).every((byte) => byte == 0) ||
        bytes[10] != 0xff ||
        bytes[11] != 0xff) {
      return null;
    }
    return bytes.sublist(12);
  }

  static bool _hasIPv6Prefix(
    List<int> address,
    List<int> prefix,
    int prefixBits,
  ) {
    final wholeBytes = prefixBits ~/ 8;
    for (var index = 0; index < wholeBytes; index++) {
      if (address[index] != prefix[index]) return false;
    }
    final remainingBits = prefixBits % 8;
    if (remainingBits == 0) return true;
    final mask = 0xff << (8 - remainingBits) & 0xff;
    return address[wholeBytes] & mask == prefix[wholeBytes] & mask;
  }
}
