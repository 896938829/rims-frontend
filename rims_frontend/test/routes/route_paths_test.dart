import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/routes/route_paths.dart';

void main() {
  test('route paths expose root and sample routes', () {
    expect(RoutePaths.root, '/');
    expect(RoutePaths.sample, '/sample');
  });
}
