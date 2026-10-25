import 'package:flutter_test/flutter_test.dart';
import 'package:lancom/chat_preferences.dart';
import 'package:lancom/messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('file and canvas features default to on', () async {
    final repository = ChatPreferencesRepository();

    final global = await repository.loadGlobalDefaults();
    final chat = await repository.loadChatSettings(ConversationKind.peer, 'B');

    expect(global.allowFileReceiving, isTrue);
    expect(global.allowCanvasDrawing, isTrue);
    expect(chat.allowFileReceiving, isTrue);
    expect(chat.allowCanvasDrawing, isTrue);
  });

  test('global off hides file receiving even when chat override is on',
      () async {
    final repository = ChatPreferencesRepository();

    await repository.saveChatSettings(
      ConversationKind.peer,
      'B',
      ChatFeatureSettings.defaults.copyWith(allowFileReceiving: true),
    );

    var chat = await repository.loadChatSettings(ConversationKind.peer, 'B');
    expect(chat.allowFileReceiving, isTrue);

    await repository.saveGlobalDefaults(
      ChatFeatureSettings.defaults.copyWith(allowFileReceiving: false),
    );
    chat = await repository.loadChatSettings(ConversationKind.peer, 'B');
    expect(chat.allowFileReceiving, isFalse);

    await repository.saveChatSettings(
      ConversationKind.peer,
      'B',
      ChatFeatureSettings.defaults.copyWith(allowFileReceiving: false),
    );
    await repository.saveGlobalDefaults(ChatFeatureSettings.defaults);
    chat = await repository.loadChatSettings(ConversationKind.peer, 'B');
    expect(chat.allowFileReceiving, isFalse);
  });
}
