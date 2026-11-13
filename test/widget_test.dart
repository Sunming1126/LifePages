import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/main.dart';

void main() {
  test('error messages omit the generic exception prefix', () {
    expect(errorText(Exception('暂时不可用')), '暂时不可用');
  });
}
