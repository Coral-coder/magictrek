import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app also runs compiled to JavaScript, where a shift gives an unsigned 32-bit result:
/// `-1 << 30` is +3221225472 in the browser (the computer opponent once never cast a spell
/// because its "worst score" started there). Native tests can't see that, so forbid the pattern.
void main() {
  test('no shifts of negative numbers in the app code', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (RegExp(r'-\s*\d+\s*<<').hasMatch(code)) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty);
  });
}
