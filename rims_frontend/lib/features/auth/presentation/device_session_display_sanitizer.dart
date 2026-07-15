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
    if (_containsUnsafeTextControl(value) ||
        label.isEmpty ||
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

  static bool _containsUnsafeTextControl(String value) {
    final units = value.codeUnits;
    for (var index = 0; index < units.length; index += 1) {
      final unit = units[index];
      final int codePoint;
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 1 >= units.length ||
            units[index + 1] < 0xdc00 ||
            units[index + 1] > 0xdfff) {
          return true;
        }
        final low = units[index + 1];
        codePoint = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
        index += 1;
      } else {
        if (unit >= 0xdc00 && unit <= 0xdfff) return true;
        codePoint = unit;
      }
      if (_isControlOrFormatCodePoint(codePoint)) return true;
    }
    return false;
  }

  static bool _isControlOrFormatCodePoint(int codePoint) {
    if (codePoint <= 0x1f || _inRange(codePoint, 0x7f, 0x9f)) return true;

    // Complete Unicode 16.0 General_Category=Cf ranges.
    return codePoint == 0x00ad ||
        _inRange(codePoint, 0x0600, 0x0605) ||
        codePoint == 0x061c ||
        codePoint == 0x06dd ||
        codePoint == 0x070f ||
        _inRange(codePoint, 0x0890, 0x0891) ||
        codePoint == 0x08e2 ||
        codePoint == 0x180e ||
        _inRange(codePoint, 0x200b, 0x200f) ||
        _inRange(codePoint, 0x202a, 0x202e) ||
        _inRange(codePoint, 0x2060, 0x2064) ||
        _inRange(codePoint, 0x2066, 0x206f) ||
        codePoint == 0xfeff ||
        _inRange(codePoint, 0xfff9, 0xfffb) ||
        codePoint == 0x110bd ||
        codePoint == 0x110cd ||
        _inRange(codePoint, 0x13430, 0x1343f) ||
        _inRange(codePoint, 0x1bca0, 0x1bca3) ||
        _inRange(codePoint, 0x1d173, 0x1d17a) ||
        codePoint == 0xe0001 ||
        _inRange(codePoint, 0xe0020, 0xe007f);
  }

  static bool _inRange(int value, int start, int end) =>
      value >= start && value <= end;
}
