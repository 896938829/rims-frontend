final class ApiEnvelope {
  const ApiEnvelope({
    required this.code,
    required this.message,
    required this.data,
    required this.traceId,
  });

  factory ApiEnvelope.fromJson(Map<dynamic, dynamic> json) {
    return ApiEnvelope(
      code: json['code'] is int ? json['code'] as int : -1,
      message: json['message'] is String
          ? json['message'] as String
          : 'Request failed',
      data: json['data'],
      traceId: json['traceId'] is String ? json['traceId'] as String : null,
    );
  }

  final int code;
  final String message;
  final Object? data;
  final String? traceId;

  bool get isSuccess => code == 0;
}
