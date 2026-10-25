import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'lan_platform_channel.dart';

enum LanSound {
  notification,
  openChat,
}

class LanSoundService {
  LanSoundService._();

  static const String notificationAsset = 'Items/fornotification.mp3';
  static const String openChatAsset = 'Items/foropenchat.mp3';

  static final Map<LanSound, DateTime> _lastPlayed = {};

  static Future<void> playOpenChatMessage() => _play(LanSound.openChat);

  static Future<void> playNotificationPreview() => _play(LanSound.notification);

  static Future<void> _play(LanSound sound) async {
    if (kIsWeb) return;
    final now = DateTime.now();
    final lastPlayed = _lastPlayed[sound];
    if (lastPlayed != null &&
        now.difference(lastPlayed) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastPlayed[sound] = now;

    if (Platform.isAndroid) {
      final played = await LanPlatformChannel.playAndroidSound(sound.name);
      if (played) return;
    }

    final path = await _materializeAsset(_assetFor(sound));
    if (path == null) {
      await SystemSound.play(SystemSoundType.click);
      return;
    }

    if (Platform.isLinux) {
      if (await _tryStart('paplay', [path])) return;
      if (await _tryStart('pw-play', [path])) return;
      if (await _tryStart('aplay', [path])) return;
    } else if (Platform.isMacOS) {
      if (await _tryStart('afplay', [path])) return;
    } else if (Platform.isWindows) {
      final uri = Uri.file(path).toString();
      if (await _tryStart('powershell.exe', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        '''
Add-Type -AssemblyName presentationCore;
\$player = New-Object System.Windows.Media.MediaPlayer;
\$player.Open([Uri]'$uri');
\$player.Play();
Start-Sleep -Milliseconds 1200;
\$player.Close();
''',
      ])) {
        return;
      }
    }

    await SystemSound.play(SystemSoundType.click);
  }

  static String _assetFor(LanSound sound) {
    return switch (sound) {
      LanSound.notification => notificationAsset,
      LanSound.openChat => openChatAsset,
    };
  }

  static Future<String?> _materializeAsset(String asset) async {
    final existing = await _existingDevelopmentPath(asset);
    if (existing != null) return existing;

    try {
      final data = await rootBundle.load(asset);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sharevialan_${asset.split('/').last}');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: false,
      );
      return file.path;
    } catch (error) {
      debugPrint('Could not prepare ShareViaLAN sound $asset: $error');
      return null;
    }
  }

  static Future<String?> _existingDevelopmentPath(String asset) async {
    final candidates = <String>[
      asset,
      '${Directory.current.path}/$asset',
      '${File(Platform.resolvedExecutable).parent.path}/$asset',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  static Future<bool> _tryStart(String executable, List<String> args) async {
    try {
      await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
