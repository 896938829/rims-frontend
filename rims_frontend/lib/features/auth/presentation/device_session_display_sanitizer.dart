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
        _containsUnsafeTextControl(label) ||
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
      if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) return true;
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 1 >= units.length ||
            units[index + 1] < 0xdc00 ||
            units[index + 1] > 0xdfff) {
          return true;
        }
        index += 1;
        continue;
      }
      if (unit >= 0xdc00 && unit <= 0xdfff) return true;
      if (unit == 0x061c ||
          unit == 0x200b ||
          unit == 0x200c ||
          unit == 0x200d ||
          unit == 0x200e ||
          unit == 0x200f ||
          (unit >= 0x202a && unit <= 0x202e) ||
          (unit >= 0x2066 && unit <= 0x2069) ||
          unit == 0xfeff) {
        return true;
      }
    }
    return false;
  }
}
