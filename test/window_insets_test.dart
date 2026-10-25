import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lancom/chat_preferences.dart';
import 'package:lancom/main.dart';
import 'package:lancom/messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void configureInsets(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(440, 900);
    tester.view.viewPadding = const FakeViewPadding(
      top: 40,
      bottom: 32,
      left: 16,
      right: 12,
    );
    tester.view.padding = tester.view.viewPadding;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'setup controls stay inside display cutout and navigation insets',
    (tester) async {
      configureInsets(tester);
      await tester.pumpWidget(const LanComApp());
      await tester.pumpAndSettle();
      final field = tester.getRect(find.byType(TextField));
      final button = tester.getRect(find.text('Let me in'));
      expect(field.left, greaterThanOrEqualTo(16));
      expect(field.right, lessThanOrEqualTo(428));
      expect(field.top, greaterThanOrEqualTo(40));
      expect(button.bottom, lessThanOrEqualTo(868));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat composer clears navigation buttons and the keyboard', (
    tester,
  ) async {
    configureInsets(tester);
    final messaging = MessagingService(myId: 'local', myName: 'Local');
    final preferences = ChatPreferencesRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ConversationScreen.peer(
          device: Device(
            id: 'remote',
            name: 'Remote',
            ip: '192.168.1.2',
            lastSeen: DateTime.now(),
          ),
          messaging: messaging,
          chatPreferences: preferences,
          myName: 'Local',
          myId: 'local',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(tester.getRect(field).bottom, lessThanOrEqualTo(868));
    expect(tester.getRect(field).left, greaterThanOrEqualTo(16));
    expect(tester.getRect(field).right, lessThanOrEqualTo(428));

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    tester.view.padding = const FakeViewPadding(top: 40, left: 16, right: 12);
    await tester.pumpAndSettle();
    expect(tester.getRect(field).bottom, lessThanOrEqualTo(580));
    expect(tester.getRect(field).height, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    preferences.dispose();
    messaging.dispose();
  });

  testWidgets('app bars request icon brightness without legacy bar colors', (
    tester,
  ) async {
    final styles = <Map<Object?, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
        styles.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(const LanComApp());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const AboutShareViaLanScreen()),
    );
    await tester.pumpAndSettle();
    expect(styles, isNotEmpty);
    final style = styles.last;
    expect(style['statusBarIconBrightness'], 'Brightness.light');
    expect(style['statusBarColor'], isNull);
    expect(style['systemNavigationBarColor'], isNull);
    expect(style['systemNavigationBarDividerColor'], isNull);
  });
}
