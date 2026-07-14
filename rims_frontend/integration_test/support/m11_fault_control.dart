import 'dart:io';

const _selfInterruptingActions = {'airplane-mode', 'wifi-switch'};

bool isExpectedNetworkFaultDisconnect(String action, Object error) {
  return _selfInterruptingActions.contains(action) &&
      (error is HttpException || error is SocketException);
}
