import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_platform_channel.dart';

const _preferredVideoPlayerKey = 'lancom.preferred_desktop_video_player';

class ExternalVideoLaunchResult {
  final bool success;
  final String message;

  const ExternalVideoLaunchResult._(this.success, this.message);

  factory ExternalVideoLaunchResult.success(String message) =>
      ExternalVideoLaunchResult._(true, message);

  factory ExternalVideoLaunchResult.failure(String message) =>
      ExternalVideoLaunchResult._(false, message);
}

class ExternalVideoLauncher {
  const ExternalVideoLauncher._();

  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isWindows || Platform.isLinux;
  }

  static bool get isSupportedDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux;
  }

  static bool get usesAndroidIntent {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  static Future<ExternalVideoLaunchResult> openDefault(String source) async {
    if (usesAndroidIntent) {
      return _openAndroidIntent(source);
    }

    if (!isSupportedDesktop) {
      return ExternalVideoLaunchResult.failure(
        'External video players are available on Android, Windows, and Linux.',
      );
    }

    if (Platform.isWindows) {
      return _startProcess('rundll32.exe', <String>[
        'url.dll,FileProtocolHandler',
        source,
      ], successMessage: 'Opened with the default app.');
    }

    final result = await _startProcess('xdg-open', <String>[
      source,
    ], successMessage: 'Opened with the default app.');
    if (result.success) return result;

    return _startProcess('gio', <String>[
      'open',
      source,
    ], successMessage: 'Opened with the default app.');
  }

  static Future<ExternalVideoLaunchResult> chooseAndOpen(String source) async {
    if (usesAndroidIntent) {
      return _openAndroidIntent(source);
    }

    if (!isSupportedDesktop) {
      return ExternalVideoLaunchResult.failure(
        'External video players are available on Android, Windows, and Linux.',
      );
    }

    final picked = await FilePicker.pickFile(
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? const <String>['exe'] : null,
      dialogTitle: 'Choose a video player',
    );
    final path = picked?.path;
    if (path == null || path.isEmpty) {
      return ExternalVideoLaunchResult.failure('No player selected.');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferredVideoPlayerKey, path);
    return _openWithPlayer(path, source);
  }

  static Future<ExternalVideoLaunchResult> openPreferred(String source) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_preferredVideoPlayerKey);
    if (path == null || path.isEmpty) {
      return ExternalVideoLaunchResult.failure('No video player selected yet.');
    }
    return _openWithPlayer(path, source);
  }

  static Future<bool> hasPreferredPlayer() async {
    if (!isSupportedDesktop) return false;
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_preferredVideoPlayerKey);
    return path != null && path.isNotEmpty;
  }

  static Future<ExternalVideoLaunchResult> _openAndroidIntent(
    String source,
  ) async {
    final opened = await LanPlatformChannel.openAndroidExternalVideo(source);
    return opened
        ? ExternalVideoLaunchResult.success('Opened with installed player.')
        : ExternalVideoLaunchResult.failure(
            'No installed video player could open this video.',
          );
  }

  static Future<ExternalVideoLaunchResult> _openWithPlayer(
    String playerPath,
    String source,
  ) async {
    if (!await File(playerPath).exists()) {
      return ExternalVideoLaunchResult.failure(
        'The selected player is no longer available.',
      );
    }
    return _startProcess(playerPath, <String>[
      source,
    ], successMessage: 'Opened with the selected player.');
  }

  static Future<ExternalVideoLaunchResult> _startProcess(
    String executable,
    List<String> arguments, {
    required String successMessage,
  }) async {
    try {
      await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return ExternalVideoLaunchResult.success(successMessage);
    } on ProcessException catch (error) {
      return ExternalVideoLaunchResult.failure(error.message);
    } catch (error) {
      return ExternalVideoLaunchResult.failure(error.toString());
    }
  }
}
