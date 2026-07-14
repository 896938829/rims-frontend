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
    if (!_isAscii(uri.host) || uri.authority.contains('%')) {
      throw const FormatException('API_BASE_URL host must be plain ASCII.');
    }

    final localTarget = _isLocalTarget(uri.host);
    if (!environment.isLocal && localTarget) {
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
      if (!uri.hasPort || uri.port != 8080) {
        throw const FormatException(
          'Local HTTP API_BASE_URL must use port 8080.',
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

  static bool _isLocalTarget(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    if (normalized == '::1') return true;

    final octets = _parseIPv4(normalized);
    if (octets == null) return false;
    final first = octets[0];
    final second = octets[1];
    return first == 127 ||
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
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
