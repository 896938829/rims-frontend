abstract final class DeviceSessionDisplaySanitizer {
  static final RegExp _ipv4Address = RegExp(
    r'(?:^|[^0-9])(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    r'(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}'
    r'(?:$|[^0-9])',
  );
  static final RegExp _bracketedIpv6Address = RegExp(
    r'\[[0-9A-Fa-f]*:[0-9A-Fa-f:.]*\](?::[0-9]+)?',
  );
  static final RegExp _ipv6Address = RegExp(
    r'(?:^|[^0-9A-Fa-f])(?:[0-9A-Fa-f]{0,4}:){2,}'
    r'[0-9A-Fa-f]{0,4}(?:$|[^0-9A-Fa-f:])',
  );

  static String deviceLabel(String value) {
    final label = value.trim();
    if (label.isEmpty ||
        label.toLowerCase() == 'unknown device' ||
        _containsNetworkAddress(label)) {
      return '未知设备';
    }
    return label;
  }

  static String platformLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      'android' => 'Android',
      'ios' || 'iphone' || 'ipad' => 'iOS',
      'windows' => 'Windows',
      'macos' || 'macintosh' => 'macOS',
      'linux' => 'Linux',
      'web' => 'Web',
      _ => '未知平台',
    };
  }

  static String userAgentLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      'rims android' => 'RIMS Android 客户端',
      'rims ios' => 'RIMS iOS 客户端',
      'flutter' || 'rims' => 'RIMS 客户端',
      'chrome' => 'Chrome 浏览器',
      'edge' || 'microsoft edge' => 'Edge 浏览器',
      'firefox' => 'Firefox 浏览器',
      'safari' => 'Safari 浏览器',
      _ => '未知客户端',
    };
  }

  static bool _containsNetworkAddress(String value) {
    return _ipv4Address.hasMatch(value) ||
        _bracketedIpv6Address.hasMatch(value) ||
        _ipv6Address.hasMatch(value);
  }
}
