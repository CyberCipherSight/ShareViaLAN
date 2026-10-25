import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lancom/received_file_opener.dart';
import 'package:open_file/open_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const androidChannel = MethodChannel('lancom/platform');
  const desktopChannel = MethodChannel('open_file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lancom_open_test_');
    file =
        await File('${directory.path}/received file.APK').writeAsString('test');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(androidChannel, null);
    messenger.setMockMethodCallHandler(desktopChannel, null);
    await directory.delete(recursive: true);
  });

  test('missing files do not launch a viewer or permission request', () async {
    var called = false;
    messenger.setMockMethodCallHandler(androidChannel, (call) async {
      called = true;
      return {'type': 0, 'message': 'Opened'};
    });
    await file.delete();
    final result = await ReceivedFileOpener.open(file.path,
        platform: TargetPlatform.android);
    expect(result.type, ResultType.fileNotFound);
    expect(called, isFalse);
  });

  test('Android uses the native read grant and installation flow', () async {
    messenger.setMockMethodCallHandler(androidChannel, (call) async {
      expect(call.method, 'openFile');
      expect(call.arguments, {'path': file.path});
      return {'type': 0, 'message': 'Opened'};
    });
    final result = await ReceivedFileOpener.open(file.path,
        platform: TargetPlatform.android);
    expect(result.type, ResultType.done);
  });

  test('Android permission denial and missing viewers reach the user',
      () async {
    for (final code in [-3, -1]) {
      messenger.setMockMethodCallHandler(androidChannel, (call) async {
        return {'type': code, 'message': 'Action needed'};
      });
      final result = await ReceivedFileOpener.open(file.path,
          platform: TargetPlatform.android);
      expect(result.type,
          code == -3 ? ResultType.permissionDenied : ResultType.noAppToOpen);
      expect(result.message, 'Action needed');
    }
  });

  test('platform errors produce a readable failure', () async {
    messenger.setMockMethodCallHandler(androidChannel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    final result = await ReceivedFileOpener.open(file.path,
        platform: TargetPlatform.android);
    expect(result.type, ResultType.error);
    expect(result.message, contains('try again'));
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    test('$platform opens paths with spaces through the desktop plugin',
        () async {
      messenger.setMockMethodCallHandler(desktopChannel, (call) async {
        expect(call.arguments['file_path'], file.path);
        return jsonEncode({'type': 0, 'message': 'Opened'});
      });
      final result =
          await ReceivedFileOpener.open(file.path, platform: platform);
      expect(result.type, ResultType.done);
    });

    test('$platform explains missing file associations', () async {
      messenger.setMockMethodCallHandler(desktopChannel, (call) async {
        return jsonEncode({'type': -1, 'message': 'opaque platform error'});
      });
      final result =
          await ReceivedFileOpener.open(file.path, platform: platform);
      expect(result.type, ResultType.noAppToOpen);
      expect(result.message, contains('app for this file type'));
    });
  }
}
