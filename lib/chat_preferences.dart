import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging.dart';

const _prefsChatPrefix = 'lancom.chat_settings';
const _prefsGlobalPrefix = 'lancom.chat_defaults';

class ChatFeatureSettings {
  final bool allowFileReceiving;
  final bool allowCanvasDrawing;
  final bool allowMessageNotifications;

  const ChatFeatureSettings({
    required this.allowFileReceiving,
    required this.allowCanvasDrawing,
    required this.allowMessageNotifications,
  });

  static const defaults = ChatFeatureSettings(
    allowFileReceiving: true,
    allowCanvasDrawing: true,
    allowMessageNotifications: true,
  );

  ChatFeatureSettings copyWith({
    bool? allowFileReceiving,
    bool? allowCanvasDrawing,
    bool? allowMessageNotifications,
  }) {
    return ChatFeatureSettings(
      allowFileReceiving: allowFileReceiving ?? this.allowFileReceiving,
      allowCanvasDrawing: allowCanvasDrawing ?? this.allowCanvasDrawing,
      allowMessageNotifications:
          allowMessageNotifications ?? this.allowMessageNotifications,
    );
  }
}

class ChatPreferencesRepository extends ChangeNotifier {
  Future<ChatFeatureSettings> loadGlobalDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    return ChatFeatureSettings(
      allowFileReceiving: prefs.getBool(_globalKey('allowFileReceiving')) ??
          ChatFeatureSettings.defaults.allowFileReceiving,
      allowCanvasDrawing: prefs.getBool(_globalKey('allowCanvasDrawing')) ??
          ChatFeatureSettings.defaults.allowCanvasDrawing,
      allowMessageNotifications:
          prefs.getBool(_globalKey('allowMessageNotifications')) ??
              ChatFeatureSettings.defaults.allowMessageNotifications,
    );
  }

  Future<void> saveGlobalDefaults(ChatFeatureSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeSettings(
      prefs,
      _prefsGlobalPrefix,
      settings,
      markInitialized: false,
    );
    notifyListeners();
  }

  Future<ChatFeatureSettings> loadChatSettings(
    ConversationKind kind,
    String conversationId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = _chatPrefix(kind, conversationId);
    final globalDefaults = await loadGlobalDefaults();

    return ChatFeatureSettings(
      allowFileReceiving: globalDefaults.allowFileReceiving &&
          (prefs.getBool('$prefix.allowFileReceiving') ?? true),
      allowCanvasDrawing: globalDefaults.allowCanvasDrawing &&
          (prefs.getBool('$prefix.allowCanvasDrawing') ?? true),
      allowMessageNotifications: globalDefaults.allowMessageNotifications &&
          (prefs.getBool('$prefix.allowMessageNotifications') ?? true),
    );
  }

  Future<void> saveChatSettings(
    ConversationKind kind,
    String conversationId,
    ChatFeatureSettings settings,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeSettings(
      prefs,
      _chatPrefix(kind, conversationId),
      settings,
      markInitialized: true,
    );
    notifyListeners();
  }

  Future<bool> allowFileReceiving(
    ConversationKind kind,
    String conversationId,
  ) async {
    return (await loadChatSettings(kind, conversationId)).allowFileReceiving;
  }

  Future<bool> allowCanvasDrawing(
    ConversationKind kind,
    String conversationId,
  ) async {
    return (await loadChatSettings(kind, conversationId)).allowCanvasDrawing;
  }

  Future<bool> allowMessageNotifications(
    ConversationKind kind,
    String conversationId,
  ) async {
    return (await loadChatSettings(kind, conversationId))
        .allowMessageNotifications;
  }

  String _globalKey(String setting) => '$_prefsGlobalPrefix.$setting';

  String _chatPrefix(ConversationKind kind, String conversationId) {
    return '$_prefsChatPrefix.${kind.name}.${Uri.encodeComponent(conversationId)}';
  }

  Future<void> _writeSettings(
    SharedPreferences prefs,
    String prefix,
    ChatFeatureSettings settings, {
    required bool markInitialized,
  }) async {
    if (markInitialized) {
      await prefs.setBool('$prefix.initialized', true);
    }
    await prefs.setBool(
      '$prefix.allowFileReceiving',
      settings.allowFileReceiving,
    );
    await prefs.setBool(
      '$prefix.allowCanvasDrawing',
      settings.allowCanvasDrawing,
    );
    await prefs.setBool(
      '$prefix.allowMessageNotifications',
      settings.allowMessageNotifications,
    );
  }
}
