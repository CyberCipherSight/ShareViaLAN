import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_file/open_file.dart';

import 'lan_platform_channel.dart';

/// Opens files only after an explicit tap. Android grants the viewer temporary
/// read access and requests installation permission only when opening an APK.
class ReceivedFileOpener {
  static Future<OpenResult> open(
    String path, {
    TargetPlatform? platform,
  }) async {
    try {
      if (path.isEmpty || !await File(path).exists()) {
        return OpenResult(
          type: ResultType.fileNotFound,
          message:
              'This file was moved or deleted. Receive it again to open it.',
        );
      }
      final target = platform ?? defaultTargetPlatform;
      final OpenResult result;
      if (target == TargetPlatform.android) {
        final response = await LanPlatformChannel.openAndroidFile(path);
        if (response == null) {
          return OpenResult(
            type: ResultType.error,
            message: 'Could not open this file. Please try again.',
          );
        }
        result = OpenResult.fromJson(response);
      } else {
        result = await OpenFile.open(path);
      }
      if (result.type == ResultType.done) return result;
      if (target == TargetPlatform.android) return result;
      return OpenResult(
        type: result.type,
        message:
            'Could not open this file. Check that an app for this file type '
            'is installed, or open it from your Downloads/ShareViaLAN folder.',
      );
    } on FileSystemException {
      return OpenResult(
        type: ResultType.permissionDenied,
        message: 'Cannot access this file. Check the folder permissions or '
            'receive it again.',
      );
    } catch (error) {
      debugPrint('Open file failed: $error');
      return OpenResult(
        type: ResultType.error,
        message: 'Could not open this file. Open it from your '
            'Downloads/ShareViaLAN folder or check your default app settings.',
      );
    }
  }
}
