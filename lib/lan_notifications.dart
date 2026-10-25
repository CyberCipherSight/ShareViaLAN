import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'lan_sounds.dart';
import 'messaging.dart';

const String _decisionCategory = 'lancom_decision';
const String _acceptAction = 'accept';
const String _rejectAction = 'reject';
const String _notificationsChannelId = 'lancom_notifications';
const String _messageNotificationsChannelId = 'lancom_message_notifications_v2';
const String _notificationsChannelName = 'ShareViaLAN notifications';
const String _messageNotificationsChannelName = 'ShareViaLAN messages';
const String _notificationsChannelDescription =
    'Messages, connection requests, and transfer requests from ShareViaLAN peers.';

@pragma('vm:entry-point')
void lanComNotificationTapBackground(NotificationResponse response) {
  // Actionable ShareViaLAN notifications are handled by the foreground isolate.
}

typedef NotificationConversationHandler = Future<void> Function(
  ConversationKind kind,
  String conversationId,
);

class LanNotificationDecision {
  final String key;
  final int notificationId;
  final Future<bool> future;

  const LanNotificationDecision._({
    required this.key,
    required this.notificationId,
    required this.future,
  });
}

class LanNotificationService {
  LanNotificationService._();

  static final LanNotificationService instance = LanNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Map<String, _PendingDecision> _pendingDecisions = {};
  final Map<String, Set<int>> _conversationNotificationIds = {};

  MessagingService? _messaging;
  NotificationConversationHandler? _conversationOpenHandler;
  Map<String, dynamic>? _pendingConversationOpen;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final decisionActions = <DarwinNotificationAction>[
      DarwinNotificationAction.plain(
        _acceptAction,
        'Accept',
        options: <DarwinNotificationActionOption>{
          DarwinNotificationActionOption.foreground,
        },
      ),
      DarwinNotificationAction.plain(
        _rejectAction,
        'Reject',
        options: <DarwinNotificationActionOption>{
          DarwinNotificationActionOption.destructive,
          DarwinNotificationActionOption.foreground,
        },
      ),
    ];
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          _decisionCategory,
          actions: decisionActions,
        ),
      ],
    );
    const linux = LinuxInitializationSettings(
      defaultActionName: 'Open ShareViaLAN',
    );
    const windows = WindowsInitializationSettings(
      appName: 'ShareViaLAN',
      appUserModelId: 'ShareViaLAN.Desktop.App',
      guid: 'b0f5e0b6-0ee0-4f74-b6b7-3ed253c19d32',
    );
    final settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            lanComNotificationTapBackground,
      );
      _initialized = true;
      await _requestPermissions();
      await _captureLaunchNotification();
    } catch (error) {
      debugPrint('ShareViaLAN notifications unavailable: $error');
    }
  }

  void bindMessaging(MessagingService messaging) {
    _messaging = messaging;
  }

  void bindConversationOpenHandler(NotificationConversationHandler handler) {
    _conversationOpenHandler = handler;
    final pending = _pendingConversationOpen;
    if (pending != null) {
      _pendingConversationOpen = null;
      unawaited(_openConversationFromPayload(pending));
    }
  }

  void unbindConversationOpenHandler() {
    _conversationOpenHandler = null;
  }

  void unbindMessaging(MessagingService messaging) {
    if (identical(_messaging, messaging)) {
      _clearPendingDecisions();
      _messaging = null;
    }
  }

  LanNotificationDecision showPermissionRequest(
    PermissionRequest request,
  ) {
    final key =
        'permission:${request.peerId}:${request.timestamp.microsecondsSinceEpoch}';
    return _showDecisionNotification(
      key: key,
      title: 'Connection request',
      body: '${request.peerName} wants to connect.',
      type: 'permission',
      acceptLabel: 'Allow',
      rejectLabel: 'Deny',
      payload: <String, String>{
        'peerId': request.peerId,
      },
    );
  }

  LanNotificationDecision showGroupJoinRequest(
    GroupJoinRequest request,
  ) {
    final key =
        'group:${request.groupId}:${request.requesterId}:${request.timestamp.microsecondsSinceEpoch}';
    return _showDecisionNotification(
      key: key,
      title: 'Group join request',
      body: '${request.requesterName} wants to join "${request.groupName}".',
      type: 'group_join',
      acceptLabel: 'Approve',
      rejectLabel: 'Decline',
      payload: <String, String>{
        'groupId': request.groupId,
        'requesterId': request.requesterId,
      },
    );
  }

  Future<void> completeDecision(
    LanNotificationDecision decision,
    bool accepted,
  ) async {
    final pending = _pendingDecisions.remove(decision.key);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(accepted);
    }
    await _cancel(decision.notificationId);
  }

  Future<void> showIncomingMessage(ChatMessage message) async {
    if (!_canShowNotifications || message.isMe || message.isSystem) return;
    final conversationPrefix =
        message.conversationKind == ConversationKind.group ? 'Group' : null;
    final title = conversationPrefix == null
        ? message.fromName
        : '$conversationPrefix: ${message.fromName}';
    final id = _notificationIdFor(_conversationNotificationKey(
      message.conversationKind,
      message.conversationId,
    ));
    _trackConversationNotification(
      message.conversationKind,
      message.conversationId,
      id,
    );
    await _show(
      id: id,
      title: title,
      body: message.text,
      payload: _encodePayload(<String, String>{
        'type': 'message',
        'conversationKind': message.conversationKind.name,
        'conversationId': message.conversationId,
        'messageId': message.messageId,
      }),
      details: _details(category: _NotificationCategory.message),
    );
  }

  Future<void> showIncomingTransferOffer(ChatMessage message) async {
    if (!_canShowNotifications ||
        message.isMe ||
        message.transferId == null ||
        message.transferStatus != TransferStatus.pending) {
      return;
    }
    final isStream = message.isStream;
    final fileName = message.fileName ?? (isStream ? 'video' : 'file');
    final id = _notificationIdFor('transfer:${message.transferId}');
    _trackConversationNotification(
      message.conversationKind,
      message.conversationId,
      id,
    );
    await _show(
      id: id,
      title: isStream ? 'Video stream request' : 'File request',
      body: '${message.fromName} wants to send "$fileName".',
      payload: _encodePayload(<String, String>{
        'type': 'transfer',
        'transferId': message.transferId!,
        'conversationKind': message.conversationKind.name,
        'conversationId': message.conversationId,
      }),
      details: _details(
        actionable: true,
        acceptLabel: isStream ? 'Stream' : 'Accept',
        rejectLabel: isStream ? 'Dismiss' : 'Reject',
        category: _NotificationCategory.transfer,
        windowsBasePayload: <String, String>{
          'type': 'transfer',
          'transferId': message.transferId!,
        },
      ),
    );
  }

  bool get _canShowNotifications => _initialized && !kIsWeb;

  Future<void> clearConversationNotifications(
    ConversationKind kind,
    String conversationId,
  ) async {
    final key = _conversationNotificationKey(kind, conversationId);
    final ids = _conversationNotificationIds.remove(key) ?? <int>{};
    ids.add(_notificationIdFor(key));
    for (final id in ids) {
      await _cancel(id);
    }
  }

  LanNotificationDecision _showDecisionNotification({
    required String key,
    required String title,
    required String body,
    required String type,
    required String acceptLabel,
    required String rejectLabel,
    required Map<String, String> payload,
  }) {
    final notificationId = _notificationIdFor(key);
    final completer = Completer<bool>();
    _pendingDecisions[key] = _PendingDecision(
      notificationId: notificationId,
      completer: completer,
    );

    if (_canShowNotifications) {
      final fullPayload = <String, String>{
        'type': type,
        'decisionKey': key,
        ...payload,
      };
      unawaited(
        _show(
          id: notificationId,
          title: title,
          body: body,
          payload: _encodePayload(fullPayload),
          details: _details(
            actionable: true,
            acceptLabel: acceptLabel,
            rejectLabel: rejectLabel,
            category: _NotificationCategory.request,
            windowsBasePayload: fullPayload,
          ),
        ),
      );
    }

    return LanNotificationDecision._(
      key: key,
      notificationId: notificationId,
      future: completer.future,
    );
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
    String? payload,
  }) async {
    if (!_canShowNotifications) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } catch (error) {
      debugPrint('Could not show ShareViaLAN notification: $error');
    }
  }

  NotificationDetails _details({
    bool actionable = false,
    String acceptLabel = 'Accept',
    String rejectLabel = 'Reject',
    _NotificationCategory category = _NotificationCategory.message,
    Map<String, String>? windowsBasePayload,
  }) {
    final androidActions = actionable
        ? <AndroidNotificationAction>[
            AndroidNotificationAction(
              _acceptAction,
              acceptLabel,
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              _rejectAction,
              rejectLabel,
              showsUserInterface: true,
              semanticAction: SemanticAction.delete,
            ),
          ]
        : null;
    final linuxActions = actionable
        ? <LinuxNotificationAction>[
            LinuxNotificationAction(key: _acceptAction, label: acceptLabel),
            LinuxNotificationAction(key: _rejectAction, label: rejectLabel),
          ]
        : const <LinuxNotificationAction>[];
    final windowsActions = actionable
        ? <WindowsAction>[
            WindowsAction(
              content: acceptLabel,
              arguments: _encodePayload(<String, String>{
                ...?windowsBasePayload,
                'action': _acceptAction,
              }),
              buttonStyle: WindowsButtonStyle.success,
            ),
            WindowsAction(
              content: rejectLabel,
              arguments: _encodePayload(<String, String>{
                ...?windowsBasePayload,
                'action': _rejectAction,
              }),
              buttonStyle: WindowsButtonStyle.critical,
            ),
          ]
        : const <WindowsAction>[];

    final isMessage = category == _NotificationCategory.message;

    return NotificationDetails(
      android: AndroidNotificationDetails(
        isMessage ? _messageNotificationsChannelId : _notificationsChannelId,
        isMessage
            ? _messageNotificationsChannelName
            : _notificationsChannelName,
        channelDescription: _notificationsChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        sound: isMessage
            ? const RawResourceAndroidNotificationSound('fornotification')
            : null,
        category: switch (category) {
          _NotificationCategory.message => AndroidNotificationCategory.message,
          _NotificationCategory.request => AndroidNotificationCategory.call,
          _NotificationCategory.transfer =>
            AndroidNotificationCategory.progress,
        },
        actions: androidActions,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: true,
        sound: isMessage ? 'fornotification.mp3' : null,
        categoryIdentifier: actionable ? _decisionCategory : null,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: true,
        sound: isMessage ? 'fornotification.mp3' : null,
        categoryIdentifier: actionable ? _decisionCategory : null,
      ),
      linux: LinuxNotificationDetails(
        sound: isMessage
            ? AssetsLinuxSound(LanSoundService.notificationAsset)
            : null,
        category: switch (category) {
          _NotificationCategory.message => LinuxNotificationCategory.imReceived,
          _NotificationCategory.request =>
            LinuxNotificationCategory.networkConnected,
          _NotificationCategory.transfer => LinuxNotificationCategory.transfer,
        },
        urgency: actionable
            ? LinuxNotificationUrgency.critical
            : LinuxNotificationUrgency.normal,
        actions: linuxActions,
      ),
      windows: WindowsNotificationDetails(
        actions: windowsActions,
        audio: isMessage
            ? WindowsNotificationAudio.asset(
                LanSoundService.notificationAsset,
                fallback: WindowsNotificationSound.im,
              )
            : null,
        duration: actionable
            ? WindowsNotificationDuration.long
            : WindowsNotificationDuration.short,
      ),
    );
  }

  Future<void> _requestPermissions() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      } else if (Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      }
    } catch (error) {
      debugPrint('Could not request notification permission: $error');
    }
  }

  Future<void> _captureLaunchNotification() async {
    if (!_canShowNotifications || Platform.isLinux) return;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return;
      final response = details?.notificationResponse;
      if (response == null) return;
      final payload = _payloadFromResponse(response);
      if (payload == null) return;
      switch (payload['type']?.toString()) {
        case 'message':
        case 'transfer':
          _pendingConversationOpen = payload;
          break;
      }
    } catch (error) {
      debugPrint('Could not read launch notification: $error');
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    unawaited(_handleNotificationResponse(response));
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = _payloadFromResponse(response);
    if (payload == null) return;
    final action = _actionFromResponse(response, payload);
    if (action == null || action.isEmpty) {
      await _handleNotificationTap(response, payload);
      return;
    }

    switch (payload['type']?.toString()) {
      case 'permission':
      case 'group_join':
        _resolveDecision(payload['decisionKey']?.toString(), action);
        break;
      case 'transfer':
        await _handleTransferAction(payload, action);
        break;
    }

    final id = response.id;
    if (id != null) {
      await _cancel(id);
    }
  }

  Future<void> _handleNotificationTap(
    NotificationResponse response,
    Map<String, dynamic> payload,
  ) async {
    switch (payload['type']?.toString()) {
      case 'message':
      case 'transfer':
        final id = response.id;
        if (id != null) await _cancel(id);
        await _openConversationFromPayload(payload);
        break;
    }
  }

  Map<String, dynamic>? _payloadFromResponse(NotificationResponse response) {
    final actionPayload = _decodePayload(response.actionId);
    if (actionPayload != null && actionPayload['type'] != null) {
      return actionPayload;
    }
    return _decodePayload(response.payload);
  }

  String? _actionFromResponse(
    NotificationResponse response,
    Map<String, dynamic> payload,
  ) {
    final embeddedAction = payload['action']?.toString();
    if (embeddedAction != null && embeddedAction.isNotEmpty) {
      return embeddedAction;
    }
    final actionId = response.actionId;
    if (actionId == _acceptAction || actionId == _rejectAction) {
      return actionId;
    }
    return null;
  }

  Future<void> _openConversationFromPayload(
      Map<String, dynamic> payload) async {
    final rawKind = payload['conversationKind']?.toString();
    final conversationId = payload['conversationId']?.toString();
    if (rawKind == null || rawKind.isEmpty || conversationId == null) return;
    final kind = _conversationKindFromName(rawKind);
    final handler = _conversationOpenHandler;
    if (handler == null) {
      _pendingConversationOpen = payload;
      return;
    }
    await clearConversationNotifications(kind, conversationId);
    await handler(kind, conversationId);
  }

  void _resolveDecision(String? key, String action) {
    if (key == null || key.isEmpty) return;
    final pending = _pendingDecisions.remove(key);
    if (pending == null || pending.completer.isCompleted) return;
    pending.completer.complete(action == _acceptAction);
  }

  Future<void> _handleTransferAction(
    Map<String, dynamic> payload,
    String action,
  ) async {
    final transferId = payload['transferId']?.toString();
    if (transferId == null || transferId.isEmpty) return;
    final messaging = _messaging;
    if (messaging == null) return;
    if (action == _acceptAction) {
      await messaging.acceptIncomingFilesFromSender(transferId);
    } else if (action == _rejectAction) {
      await messaging.rejectIncomingFile(transferId);
    }
  }

  Future<void> _cancel(int notificationId) async {
    if (!_canShowNotifications) return;
    try {
      await _plugin.cancel(id: notificationId);
    } catch (_) {
      // Best effort.
    }
  }

  void _clearPendingDecisions() {
    _pendingDecisions.clear();
  }

  void _trackConversationNotification(
    ConversationKind kind,
    String conversationId,
    int notificationId,
  ) {
    final key = _conversationNotificationKey(kind, conversationId);
    _conversationNotificationIds
        .putIfAbsent(key, () => <int>{})
        .add(notificationId);
  }

  String _conversationNotificationKey(
    ConversationKind kind,
    String conversationId,
  ) {
    return 'message:${kind.name}:$conversationId';
  }

  String _encodePayload(Map<String, String> payload) => jsonEncode(payload);

  Map<String, dynamic>? _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  int _notificationIdFor(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x3fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}

ConversationKind _conversationKindFromName(String value) {
  for (final kind in ConversationKind.values) {
    if (kind.name == value) return kind;
  }
  return ConversationKind.peer;
}

class _PendingDecision {
  final int notificationId;
  final Completer<bool> completer;

  const _PendingDecision({
    required this.notificationId,
    required this.completer,
  });
}

enum _NotificationCategory {
  message,
  request,
  transfer,
}
