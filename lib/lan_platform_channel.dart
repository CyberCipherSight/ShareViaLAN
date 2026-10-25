import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LanPlatformChannel {
  static const MethodChannel _channel = MethodChannel('lancom/platform');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  static Future<int> androidSdkInt() async {
    if (!_isAndroid) return 0;
    final value = await _invoke<int>('androidSdkInt');
    return value ?? 0;
  }

  static Future<bool> checkAndroidLocalNetworkPermission() async {
    if (!_isAndroid) return true;
    return await _invoke<bool>('checkLocalNetworkPermission') ?? true;
  }

  static Future<bool> requestAndroidLocalNetworkPermission() async {
    if (!_isAndroid) return true;
    return await _invoke<bool>('requestLocalNetworkPermission') ?? true;
  }

  static Future<bool> acquireAndroidMulticastLock() async {
    if (!_isAndroid) return false;
    return await _invoke<bool>('acquireMulticastLock') ?? false;
  }

  static Future<bool> releaseAndroidMulticastLock() async {
    if (!_isAndroid) return true;
    return await _invoke<bool>('releaseMulticastLock') ?? true;
  }

  static Future<bool> isAndroidMulticastLockHeld() async {
    if (!_isAndroid) return false;
    return await _invoke<bool>('isMulticastLockHeld') ?? false;
  }

  static Future<bool> isIgnoringAndroidBatteryOptimizations() async {
    if (!_isAndroid) return true;
    return await _invoke<bool>('isIgnoringBatteryOptimizations') ?? true;
  }

  static Future<bool> openAndroidBatteryOptimizationSettings() async {
    if (!_isAndroid) return false;
    return await _invoke<bool>('openBatteryOptimizationSettings') ?? false;
  }

  static Future<bool> setAndroidActiveTransferWakeLock(bool enabled) async {
    if (!_isAndroid) return false;
    return await _invoke<bool>(
          enabled ? 'acquireTransferWakeLock' : 'releaseTransferWakeLock',
        ) ??
        false;
  }

  static Future<void> openAndroidAppSettings() async {
    if (!_isAndroid) return;
    await _invoke<void>('openAppSettings');
  }

  static Future<bool> openAndroidExternalVideo(String source) async {
    if (!_isAndroid || source.isEmpty) return false;
    return await _invoke<bool>('openExternalVideo', <String, String>{
          'source': source,
        }) ??
        false;
  }

  // The file opener selects the platform before calling this method.
  static Future<Map<String, dynamic>?> openAndroidFile(String path) async {
    return _invoke<Map<dynamic, dynamic>>('openFile', <String, String>{
      'path': path,
    }).then((value) => value == null ? null : Map<String, dynamic>.from(value));
  }

  static Future<bool> playAndroidSound(String sound) async {
    if (!_isAndroid) return false;
    return await _invoke<bool>('playSound', <String, String>{'sound': sound}) ??
        false;
  }

  static Future<String?> androidPublicDownloadPath(String fileName) async {
    if (!_isAndroid) return null;
    return _invoke<String>('publicDownloadPath', <String, String>{
      'fileName': fileName,
    });
  }

  static Future<String?> publishAndroidDownload({
    required String sourcePath,
    required String fileName,
  }) async {
    if (!_isAndroid) return null;
    return _invoke<String>('publishDownload', <String, String>{
      'sourcePath': sourcePath,
      'fileName': fileName,
    });
  }

  static Future<List<AndroidPickedFile>?> pickAndroidFiles({
    bool allowMultiple = true,
  }) async {
    if (!_isAndroid) return null;
    final value = await _invoke<Object?>('pickFiles', <String, Object>{
      'allowMultiple': allowMultiple,
    });
    if (value == null) return null;
    if (value is! List) return const <AndroidPickedFile>[];

    return value
        .whereType<Map>()
        .map(
          (entry) =>
              AndroidPickedFile.fromMap(Map<String, dynamic>.from(entry)),
        )
        .where((file) => file.identifier.isNotEmpty)
        .toList(growable: false);
  }

  static Future<AndroidCachedPickedFile?> cacheAndroidPickedFile({
    required String identifier,
    required String fileName,
  }) async {
    if (!_isAndroid) return null;
    final value = await _invoke<Object?>('cachePickedFile', <String, String>{
      'identifier': identifier,
      'fileName': fileName,
    });
    if (value is! Map) return null;
    return AndroidCachedPickedFile.fromMap(Map<String, dynamic>.from(value));
  }

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Lan platform channel $method failed: ${error.message}');
      return null;
    }
  }
}

class AndroidPickedFile {
  final String identifier;
  final String name;
  final int size;

  const AndroidPickedFile({
    required this.identifier,
    required this.name,
    required this.size,
  });

  factory AndroidPickedFile.fromMap(Map<String, dynamic> map) {
    return AndroidPickedFile(
      identifier: (map['identifier'] ?? '').toString(),
      name: (map['name'] ?? 'file').toString(),
      size: _intFrom(map['size']),
    );
  }
}

class AndroidCachedPickedFile {
  final String path;
  final String name;
  final int size;

  const AndroidCachedPickedFile({
    required this.path,
    required this.name,
    required this.size,
  });

  factory AndroidCachedPickedFile.fromMap(Map<String, dynamic> map) {
    return AndroidCachedPickedFile(
      path: (map['path'] ?? '').toString(),
      name: (map['name'] ?? 'file').toString(),
      size: _intFrom(map['size']),
    );
  }
}

int _intFrom(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse((value ?? '').toString()) ?? 0;
}
