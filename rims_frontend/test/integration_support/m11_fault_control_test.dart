import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/m11_fault_control.dart';

void main() {
  test('accepts connection loss caused by physical network fault controls', () {
    expect(
      isExpectedNetworkFaultDisconnect(
        'wifi-switch',
        const HttpException('connection aborted'),
      ),
      isTrue,
    );
    expect(
      isExpectedNetworkFaultDisconnect(
        'airplane-mode',
        const SocketException('network unreachable'),
      ),
      isTrue,
    );
  });

  test('does not hide disconnects from logical fault controls', () {
    expect(
      isExpectedNetworkFaultDisconnect(
        'unreachable',
        const HttpException('connection aborted'),
      ),
      isFalse,
    );
    expect(
      isExpectedNetworkFaultDisconnect('wifi-switch', StateError('bad JSON')),
      isFalse,
    );
  });
}
