import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lancom/file_names.dart';

void main() {
  test('received names cannot escape the download directory', () {
    expect(safeFileName('../../folder/report.pdf'), 'report.pdf');
    expect(safeFileName(r'C:\folder\app.APK'), 'app.APK');
    for (final name in ['', '/', '.', '..', '...  ']) {
      expect(safeFileName(name), 'file');
    }
  });

  test('Windows reserved basenames remain usable on every platform', () {
    for (final name in ['CON', 'nul.txt', 'COM1.apk', 'LPT9.zip', 'COM¹.txt']) {
      expect(safeFileName(name), '_$name');
    }
    expect(safeFileName('console.txt'), 'console.txt');
    expect(safeFileName('COM10.txt'), 'COM10.txt');
    expect(safeFileName('report.pdf.  '), 'report.pdf');
    expect(safeFileName('bad:name?.txt'), 'bad_name_.txt');
  });

  test('Unicode filenames fit filesystem byte limits and retain extensions',
      () {
    final name = safeFileName('${'😀文' * 100}.apk');
    expect(utf8.encode(name).length, lessThanOrEqualTo(180));
    expect(name.endsWith('.apk'), isTrue);
    expect(utf8.decode(utf8.encode(name)), name);
    expect(name.contains('\uFFFD'), isFalse);
  });

  test('very long extensions cannot exceed the length limit', () {
    final name = safeFileName('file.${'x' * 300}');
    expect(utf8.encode(name).length, lessThanOrEqualTo(180));
  });
}
