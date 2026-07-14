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
    if (normalized == '::1') return true;
    if (normalized.startsWith('fc') || normalized.startsWith('fd')) return true;
    if (normalized.startsWith('::ffff:')) {
      return _isAllowedLocalIPv4(_parseIPv4(normalized.substring(7)));
    }

    final octets = _parseIPv4(normalized);
    return _isAllowedLocalIPv4(octets);
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
    if (normalized.contains(':')) {
      return true;
    }
    if (_isAllowedLocalTarget(normalized) ||
        normalized == '::' ||
        normalized.startsWith('fe8') ||
        normalized.startsWith('fe9') ||
        normalized.startsWith('fea') ||
        normalized.startsWith('feb')) {
      return true;
    }
    final octets = _parseIPv4(normalized);
    if (octets == null) return false;
    return octets[0] == 0 ||
        (octets[0] == 169 && octets[1] == 254) ||
        octets[0] >= 224;
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
}
