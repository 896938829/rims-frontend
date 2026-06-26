import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_envelope.dart';

void main() {
  group('ApiEnvelope', () {
    test('parses successful RIMS envelope', () {
      final envelope = ApiEnvelope.fromJson({
        'code': 0,
        'message': 'success',
        'data': {'token': 'abc'},
        'traceId': 'trace-1',
      });

      expect(envelope.code, 0);
      expect(envelope.message, 'success');
      expect(envelope.data, {'token': 'abc'});
      expect(envelope.traceId, 'trace-1');
      expect(envelope.isSuccess, isTrue);
    });

    test('parses business failure envelope', () {
      final envelope = ApiEnvelope.fromJson({
        'code': 20001,
        'message': '库存不足',
        'data': null,
        'traceId': 'trace-2',
      });

      expect(envelope.code, 20001);
      expect(envelope.message, '库存不足');
      expect(envelope.data, isNull);
      expect(envelope.traceId, 'trace-2');
      expect(envelope.isSuccess, isFalse);
    });
  });
}
