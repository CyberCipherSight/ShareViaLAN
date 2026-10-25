import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'battery_optimization_helper.dart';
import 'chat_history_store.dart';
import 'chat_preferences.dart';
import 'connection_readiness_screen.dart';
import 'discovery.dart';
import 'lan_notifications.dart';
import 'lan_platform_channel.dart';
import 'messaging.dart';
import 'lan_sounds.dart';
import 'permission_manager.dart';
import 'received_file_opener.dart';
import 'setup_screen.dart';
import 'stream_video_player.dart';

const _prefsNameKey = 'lancom.user_name';
const _prefsIdKey = 'lancom.user_id';
const _prefsOnlineModeKey = 'lancom.online_mode';
const _prefsRememberNameKey = 'lancom.remember_user_name';
const _prefsOnlyInitiatedConnectionsKey = 'lancom.only_initiated_connections';
const _appVersionLabel = '1.0.7+11';
const _shareViaLanGitHubUrl = 'https://github.com/CyberCipherSight/ShareViaLAN';
const _shareViaLanReleasesUrl =
    'https://github.com/CyberCipherSight/ShareViaLAN/releases';
const int _streamStartupBufferBytes = 4 * 1024 * 1024;
const double _streamStartupBufferFraction = 0.02;
const Duration _dashboardRefreshCooldown = Duration(seconds: 15);
const Duration _dashboardAutoRefreshInterval = Duration(seconds: 15);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Flutter error: ${details.exceptionAsString()}');
  };
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    debugPrint('Uncaught platform error: $error\n$stackTrace');
    return true;
  };
  await ChatHistoryStore.ensureHiveInitialized();
  await MessagingService.cleanupOldStreamCache();
  await LanNotificationService.instance.initialize();
  runApp(const LanComApp());
}

class LanComApp extends StatelessWidget {
  const LanComApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'ShareViaLAN',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFF05070A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.lightBlueAccent,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF071827),
          foregroundColor: Colors.white,
          centerTitle: true,
          // Edge-to-edge bars use the app's background. Only request icon
          // brightness, rather than the deprecated system-bar color setters.
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0C1622),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      home: const SetupWrapper(),
    );
  }
}

String createSessionId() {
  final random = Random.secure();
  return '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}';
}

Future<void> _waitForUiTransitionToSettle() async {
  await Future<void>.delayed(Duration.zero);
  await WidgetsBinding.instance.endOfFrame;
}

Widget _topIconButton({
  required BuildContext context,
  required String tooltip,
  required VoidCallback? onPressed,
  required Widget icon,
}) {
  final useAndroidTooltip =
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      tooltip.isNotEmpty;
  if (!useAndroidTooltip) {
    return IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
  }

  return Semantics(
    label: tooltip,
    button: true,
    enabled: onPressed != null,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger
          ?..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(tooltip),
              duration: const Duration(milliseconds: 1200),
            ),
          );
      },
      child: IconButton(onPressed: onPressed, icon: icon),
    ),
  );
}

class Device {
  final String id;
  final String name;
  final String ip;
  final DateTime lastSeen;
  final bool isApproved;
  final bool isReachable;
  final bool isDirect;
  final bool isOnline;
  final int hopCount;
  final String? nextHopId;
  final String? viaPeerName;
  final PeerRouteStatus routeStatus;

  const Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.lastSeen,
    this.isApproved = false,
    this.isReachable = true,
    this.isDirect = true,
    this.isOnline = true,
    this.hopCount = 1,
    this.nextHopId,
    this.viaPeerName,
    this.routeStatus = PeerRouteStatus.directOnline,
  });

  Device copyWith({
    String? name,
    String? ip,
    DateTime? lastSeen,
    bool? isApproved,
    bool? isReachable,
    bool? isDirect,
    bool? isOnline,
    int? hopCount,
    Object? nextHopId = _deviceUnset,
    Object? viaPeerName = _deviceUnset,
    PeerRouteStatus? routeStatus,
  }) {
    return Device(
      id: id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      lastSeen: lastSeen ?? this.lastSeen,
      isApproved: isApproved ?? this.isApproved,
      isReachable: isReachable ?? this.isReachable,
      isDirect: isDirect ?? this.isDirect,
      isOnline: isOnline ?? this.isOnline,
      hopCount: hopCount ?? this.hopCount,
      nextHopId: identical(nextHopId, _deviceUnset)
          ? this.nextHopId
          : nextHopId as String?,
      viaPeerName: identical(viaPeerName, _deviceUnset)
          ? this.viaPeerName
          : viaPeerName as String?,
      routeStatus: routeStatus ?? this.routeStatus,
    );
  }
}

const _deviceUnset = _DeviceUnset();

class SetupWrapper extends StatefulWidget {
  const SetupWrapper({super.key});

  @override
  State<SetupWrapper> createState() => _SetupWrapperState();
}

class _SetupWrapperState extends State<SetupWrapper> {
  String? _myName;
  String? _myId;
  bool _rememberName = true;
  bool _onlineMode = true;
  bool _onlyInitiatedConnections = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedIdentity());
  }

  Future<void> _loadSavedIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_prefsNameKey);
    final savedId = prefs.getString(_prefsIdKey) ?? createSessionId();
    final rememberName =
        prefs.getBool(_prefsRememberNameKey) ?? (savedName?.isNotEmpty == true);
    if (prefs.getString(_prefsIdKey) == null) {
      await prefs.setString(_prefsIdKey, savedId);
    }
    if (!mounted) return;
    setState(() {
      _myName = rememberName ? savedName : null;
      _myId = savedId;
      _rememberName = rememberName;
      _onlineMode = prefs.getBool(_prefsOnlineModeKey) ?? true;
      _onlyInitiatedConnections =
          prefs.getBool(_prefsOnlyInitiatedConnectionsKey) ?? false;
      _loading = false;
    });
  }

  Future<void> _persistIdentity(String name, bool rememberName) async {
    final prefs = await SharedPreferences.getInstance();
    final id = _myId ?? createSessionId();
    await prefs.setString(_prefsIdKey, id);
    await prefs.setBool(_prefsRememberNameKey, rememberName);
    if (rememberName) {
      await prefs.setString(_prefsNameKey, name);
    } else {
      await prefs.remove(_prefsNameKey);
    }
    if (!mounted) return;
    setState(() {
      _myName = name;
      _myId = id;
      _rememberName = rememberName;
    });
  }

  Future<void> _persistProfile({
    required String name,
    required bool rememberName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsRememberNameKey, rememberName);
    if (rememberName) {
      await prefs.setString(_prefsNameKey, name);
    } else {
      await prefs.remove(_prefsNameKey);
    }
    if (!mounted) return;
    setState(() {
      _myName = name;
      _rememberName = rememberName;
    });
  }

  Future<void> _persistOnlyInitiatedConnections(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsOnlyInitiatedConnectionsKey, value);
    if (!mounted) return;
    setState(() => _onlyInitiatedConnections = value);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.lightBlueAccent),
        ),
      );
    }

    if (_myName == null || _myId == null) {
      return SetupScreen(onNameSet: _persistIdentity);
    }

    return DashboardScreen(
      myName: _myName!,
      myId: _myId!,
      rememberName: _rememberName,
      initialOnlineMode: _onlineMode,
      initialOnlyInitiatedConnections: _onlyInitiatedConnections,
      onProfileChanged: _persistProfile,
      onOnlyInitiatedConnectionsChanged: _persistOnlyInitiatedConnections,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final String myName;
  final String myId;
  final bool rememberName;
  final bool initialOnlineMode;
  final bool initialOnlyInitiatedConnections;
  final Future<void> Function({
    required String name,
    required bool rememberName,
  })
  onProfileChanged;
  final Future<void> Function(bool value) onOnlyInitiatedConnectionsChanged;

  const DashboardScreen({
    super.key,
    required this.myName,
    required this.myId,
    required this.rememberName,
    required this.initialOnlineMode,
    required this.initialOnlyInitiatedConnections,
    required this.onProfileChanged,
    required this.onOnlyInitiatedConnectionsChanged,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final PermissionManager _permissionManager;
  late final LanNotificationService _notifications;
  final ChatPreferencesRepository _chatPreferences =
      ChatPreferencesRepository();
  MessagingService? _messaging;
  DiscoveryService? _discovery;
  late final AppLifecycleListener _appLifecycleListener;
  Timer? _pruneTimer;
  Timer? _autoRefreshTimer;
  bool _isStartingDiscovery = false;
  bool _isRefreshingDiscovery = false;
  bool _rememberName = true;
  bool _onlineMode = true;
  bool _onlyInitiatedConnections = false;
  String _myName = '';
  String? _discoveryError;
  DiscoveryDiagnostics? _diagnostics;
  DateTime? _lastRefreshAt;
  bool _isShuttingDown = false;
  bool _appInForeground = true;
  bool _activeTransferWakeLockHeld = false;
  bool _hadActiveTransferWhileBackgrounded = false;
  bool _showConnectionLostBatteryHint = false;
  String? _openConversationKey;

  @override
  void initState() {
    super.initState();
    _myName = widget.myName;
    _rememberName = widget.rememberName;
    _onlineMode = widget.initialOnlineMode;
    _onlyInitiatedConnections = widget.initialOnlyInitiatedConnections;
    _permissionManager = PermissionManager.forPlatform();
    _notifications = LanNotificationService.instance;
    _messaging = MessagingService(myId: widget.myId, myName: _myName);
    _notifications.bindMessaging(_messaging!);
    _notifications.bindConversationOpenHandler(
      _openConversationFromNotification,
    );
    _messaging!
      ..permissionRequestHandler = _handlePermissionRequest
      ..groupJoinRequestHandler = _handleGroupJoinRequest
      ..incomingMessageHandler = _handleIncomingMessage
      ..incomingTransferOfferHandler = _handleIncomingTransferOffer
      ..fileReceivingGuard = _chatPreferences.allowFileReceiving
      ..canvasDrawingGuard = _chatPreferences.allowCanvasDrawing
      ..addListener(_handleMessagingChanged)
      ..setOnlineMode(_onlineMode)
      ..setOnlyInitiatedConnections(_onlyInitiatedConnections);
    _appLifecycleListener = AppLifecycleListener(
      onStateChange: _handleAppLifecycleStateChange,
      onExitRequested: _handleExitRequested,
      onDetach: _forceShutdownForProcessExit,
    );
    unawaited(_messaging!.start());

    if (_onlineMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startDiscovery());
      });
    }

    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _autoRefreshTimer = Timer.periodic(_dashboardAutoRefreshInterval, (_) {
      unawaited(_refreshDiscovery());
    });
  }

  @override
  void dispose() {
    _appLifecycleListener.dispose();
    _pruneTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _discovery?.stop();
    _messaging?.removeListener(_handleMessagingChanged);
    _messaging?.permissionRequestHandler = null;
    _messaging?.groupJoinRequestHandler = null;
    _messaging?.incomingMessageHandler = null;
    _messaging?.incomingTransferOfferHandler = null;
    _messaging?.fileReceivingGuard = null;
    _messaging?.canvasDrawingGuard = null;
    if (_messaging != null) {
      _notifications.unbindMessaging(_messaging!);
    }
    _notifications.unbindConversationOpenHandler();
    if (_activeTransferWakeLockHeld) {
      unawaited(LanPlatformChannel.setAndroidActiveTransferWakeLock(false));
    }
    _messaging?.stop();
    super.dispose();
  }

  void _handleAppLifecycleStateChange(AppLifecycleState state) {
    final isForeground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!isForeground && (_messaging?.hasActiveTransfers ?? false)) {
      _hadActiveTransferWhileBackgrounded = true;
    }
    if (state == AppLifecycleState.resumed) {
      if (_hadActiveTransferWhileBackgrounded &&
          !(_messaging?.hasActiveTransfers ?? false)) {
        _showConnectionLostBatteryHint = true;
      }
      _hadActiveTransferWhileBackgrounded = false;
      unawaited(_refreshDiscovery());
    }
    _appInForeground = isForeground;
    if (mounted) setState(() {});
  }

  Future<ui.AppExitResponse> _handleExitRequested() async {
    if (_isShuttingDown) return ui.AppExitResponse.exit;
    final shouldExit = await _confirmActiveTransferDisconnect();
    if (!shouldExit) return ui.AppExitResponse.cancel;
    await _shutdownForExit();
    return ui.AppExitResponse.exit;
  }

  Future<bool> _confirmActiveTransferDisconnect() async {
    if (!(_messaging?.hasActiveTransfers ?? false)) return true;
    if (!mounted) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Disconnect'),
          content: const Text(
            'A transfer or stream is active. Are you sure you want to disconnect? This will cancel it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Disconnect'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _shutdownForExit() async {
    if (_isShuttingDown) return;
    _isShuttingDown = true;
    _stopDiscovery();
    await _messaging?.forceDisconnectAll();
    _messaging?.stop();
  }

  void _forceShutdownForProcessExit() {
    if (_isShuttingDown) return;
    _isShuttingDown = true;
    _discovery?.stop();
    final messaging = _messaging;
    if (messaging != null) {
      unawaited(messaging.forceDisconnectAll().whenComplete(messaging.stop));
    }
  }

  void _handleMessagingChanged() {
    if (!mounted) return;
    unawaited(_syncActiveTransferWakeLock());
    setState(() {});
  }

  Future<void> _syncActiveTransferWakeLock() async {
    final active = _messaging?.hasActiveTransfers ?? false;
    if (active == _activeTransferWakeLockHeld) return;
    _activeTransferWakeLockHeld = active;
    final ok = await LanPlatformChannel.setAndroidActiveTransferWakeLock(
      active,
    );
    if (active && !ok) {
      debugPrint('Android transfer wake lock could not be acquired.');
    }
  }

  Future<void> _startDiscovery() async {
    if (_isStartingDiscovery) return;
    setState(() {
      _isStartingDiscovery = true;
      _discoveryError = null;
    });

    _discovery?.stop();
    _discovery = DiscoveryService(
      myId: widget.myId,
      myName: _myName,
      tcpPort: messagingPort,
      onDeviceFound: _handleDiscoveryPacket,
      onDiagnosticsChanged: (diagnostics) {
        if (!mounted) return;
        setState(() => _diagnostics = diagnostics);
      },
    );

    try {
      await _discovery!.start();
      if (!mounted) return;
      setState(() => _isStartingDiscovery = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isStartingDiscovery = false;
        _discoveryError = error.toString();
      });
    }
  }

  void _stopDiscovery() {
    _discovery?.stop();
    _discovery = null;
    _diagnostics = null;
    _isStartingDiscovery = false;
    _isRefreshingDiscovery = false;
  }

  void _handleDiscoveryPacket(DiscoveryPacket packet) {
    if (!mounted) return;
    _messaging?.registerDiscoveredPeer(
      peerId: packet.deviceId,
      peerName: packet.deviceName,
      peerIp: packet.transportIp,
      tcpPort: packet.tcpPort,
      deviceType: packet.deviceType,
      appVersion: packet.appVersion,
      protocolVersion: packet.protocolVersion,
      timestamp: packet.timestamp,
    );
  }

  Future<void> _saveOnlineMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsOnlineModeKey, value);
  }

  Future<void> _setOnlineMode(bool value) async {
    if (_onlineMode == value) return;
    await _saveOnlineMode(value);
    _messaging?.setOnlineMode(value);
    if (!mounted) return;
    setState(() {
      _onlineMode = value;
      _discoveryError = null;
      if (!value) {
        _isStartingDiscovery = false;
        _isRefreshingDiscovery = false;
      }
    });

    if (value) {
      await _startDiscovery();
    } else {
      _stopDiscovery();
    }
  }

  Future<void> _setOnlyInitiatedConnections(bool value) async {
    await widget.onOnlyInitiatedConnectionsChanged(value);
    _messaging?.setOnlyInitiatedConnections(value);
    if (!mounted) return;
    setState(() => _onlyInitiatedConnections = value);
  }

  Future<void> _updateProfile({
    required String name,
    required bool rememberName,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    await widget.onProfileChanged(name: cleanName, rememberName: rememberName);
    _messaging?.updateIdentity(name: cleanName);
    _discovery?.updateIdentity(name: cleanName);
    if (!mounted) return;
    setState(() {
      _myName = cleanName;
      _rememberName = rememberName;
    });
  }

  List<Device> get _peers {
    final merged = <String, Device>{};
    for (final peer in _messaging?.knownPeers ?? const <PeerSummary>[]) {
      final existing = merged[peer.peerId];
      final base =
          existing ??
          Device(
            id: peer.peerId,
            name: peer.name,
            ip: peer.ip,
            lastSeen: peer.lastSeen,
          );
      merged[peer.peerId] = base.copyWith(
        name: peer.name,
        ip: peer.ip.isEmpty ? base.ip : peer.ip,
        lastSeen: peer.lastSeen,
        isApproved: peer.isApproved,
        isReachable: peer.isReachable,
        isDirect: peer.isDirect,
        isOnline: peer.isOnline,
        hopCount: peer.hopCount,
        nextHopId: peer.nextHopId,
        viaPeerName: peer.viaPeerName,
        routeStatus: peer.routeStatus,
      );
    }

    final devices = merged.values
        .where((device) => device.id != widget.myId)
        .toList();
    devices.sort((a, b) {
      final approvalWeight = (b.isApproved ? 1 : 0).compareTo(
        a.isApproved ? 1 : 0,
      );
      if (approvalWeight != 0) return approvalWeight;
      final onlineWeight = (b.isOnline ? 1 : 0).compareTo(a.isOnline ? 1 : 0);
      if (onlineWeight != 0) return onlineWeight;
      final directWeight = (b.isDirect ? 1 : 0).compareTo(a.isDirect ? 1 : 0);
      if (directWeight != 0) return directWeight;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return devices;
  }

  Future<void> _refreshDiscovery() async {
    if (!_onlineMode || _discovery == null || _isRefreshingDiscovery) return;

    final now = DateTime.now();
    final lastRefreshAt = _lastRefreshAt;
    if (lastRefreshAt != null &&
        now.difference(lastRefreshAt) < _dashboardRefreshCooldown) {
      return;
    }
    _lastRefreshAt = now;

    final currentPeers = _peers;
    setState(() {
      _isRefreshingDiscovery = true;
      _discoveryError = null;
    });

    try {
      await _discovery!.refresh();
      final alivePeerIds =
          await _messaging?.probeAlive(
            currentPeers
                .where((device) => device.isDirect && device.isReachable)
                .map((device) => device.id),
          ) ??
          const <String>{};
      if (!mounted) return;
      if (alivePeerIds.isEmpty && currentPeers.isNotEmpty) {
        setState(() {});
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _discoveryError = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isRefreshingDiscovery = false);
      }
    }
  }

  Future<bool> _handlePermissionRequest(PermissionRequest request) async {
    if (!mounted) {
      throw StateError('Dashboard is not available for permission prompts.');
    }

    if (_onlyInitiatedConnections &&
        _messaging?.permissionStateFor(request.peerId) !=
            PeerPermissionState.requesting &&
        !(_messaging?.canMessage(request.peerId) ?? false)) {
      return false;
    }

    final decision = _notifications.showPermissionRequest(request);
    return _resolveDecisionWithDialog(
      decision: decision,
      dialog: showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0C1622),
            title: const Text('Connection request'),
            content: Text('${request.peerName} wants to connect. Allow?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Deny'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Allow'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _handleGroupJoinRequest(GroupJoinRequest request) async {
    if (!mounted) return false;
    final decision = _notifications.showGroupJoinRequest(request);
    return _resolveDecisionWithDialog(
      decision: decision,
      dialog: showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0C1622),
            title: const Text('Group join request'),
            content: Text(
              '${request.requesterName} wants to join "${request.groupName}".',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Decline'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Approve'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _resolveDecisionWithDialog({
    required LanNotificationDecision decision,
    required Future<bool?> dialog,
  }) async {
    var dialogFinished = false;
    final dialogFuture = dialog.then((value) {
      dialogFinished = true;
      return value;
    });
    final notificationFuture = decision.future.then((value) {
      if (!dialogFinished && mounted) {
        Navigator.of(context, rootNavigator: true).maybePop(value);
      }
      return value;
    });

    final result = await Future.any<bool?>([dialogFuture, notificationFuture]);
    final accepted = result ?? false;
    await _notifications.completeDecision(decision, accepted);
    return accepted;
  }

  void _handleIncomingMessage(ChatMessage message) {
    unawaited(_notifyIncomingMessage(message));
  }

  Future<void> _notifyIncomingMessage(ChatMessage message) async {
    if (_isConversationOpen(message.conversationKind, message.conversationId) &&
        _appInForeground) {
      unawaited(LanSoundService.playOpenChatMessage());
      await _notifications.clearConversationNotifications(
        message.conversationKind,
        message.conversationId,
      );
      return;
    }

    final allowed = await _chatPreferences.allowMessageNotifications(
      message.conversationKind,
      message.conversationId,
    );
    if (!allowed) return;
    try {
      await _notifications.showIncomingMessage(message);
    } catch (error) {
      debugPrint('Incoming message notification failed: $error');
    }
  }

  void _handleIncomingTransferOffer(ChatMessage message) {
    unawaited(_notifyIncomingTransferOffer(message));
  }

  Future<void> _notifyIncomingTransferOffer(ChatMessage message) async {
    final allowed = await _chatPreferences.allowMessageNotifications(
      message.conversationKind,
      message.conversationId,
    );
    if (!allowed) return;
    try {
      await _notifications.showIncomingTransferOffer(message);
    } catch (error) {
      debugPrint('Incoming transfer notification failed: $error');
    }
  }

  bool _isConversationOpen(ConversationKind kind, String conversationId) {
    return _openConversationKey == _conversationKey(kind, conversationId);
  }

  Future<void> _openConversationFromNotification(
    ConversationKind kind,
    String conversationId,
  ) async {
    if (_isConversationOpen(kind, conversationId)) {
      await _notifications.clearConversationNotifications(kind, conversationId);
      return;
    }

    if (kind == ConversationKind.peer) {
      final device = _deviceForPeerId(conversationId);
      if (device != null) _openPeerChat(device);
    } else {
      final room = _messaging?.groupById(conversationId);
      if (room != null) _openGroupChat(room);
    }
  }

  Device? _deviceForPeerId(String peerId) {
    for (final device in _peers) {
      if (device.id == peerId) return device;
    }
    final peer = _messaging?.peerSummaryFor(peerId);
    if (peer == null) return null;
    return Device(
      id: peer.peerId,
      name: peer.name,
      ip: peer.ip,
      lastSeen: peer.lastSeen,
      isApproved: peer.isApproved,
      isReachable: peer.isReachable,
      isDirect: peer.isDirect,
      isOnline: peer.isOnline,
      hopCount: peer.hopCount,
      nextHopId: peer.nextHopId,
      viaPeerName: peer.viaPeerName,
      routeStatus: peer.routeStatus,
    );
  }

  String _conversationKey(ConversationKind kind, String conversationId) {
    return '${kind.name}:$conversationId';
  }

  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final groupName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Create Group'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Group name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    await _waitForUiTransitionToSettle();
    controller.dispose();

    if (!mounted ||
        groupName == null ||
        groupName.isEmpty ||
        _messaging == null) {
      return;
    }
    final room = _messaging!.createGroup(name: groupName);
    await Clipboard.setData(ClipboardData(text: room.code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Group created and code copied to clipboard.'),
      ),
    );
    _openGroupChat(room);
  }

  Future<void> _joinGroup() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Join Group'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Paste group code'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Request access'),
            ),
          ],
        );
      },
    );
    await _waitForUiTransitionToSettle();
    controller.dispose();

    if (!mounted || code == null || code.isEmpty || _messaging == null) return;
    final success = await _messaging!.requestJoinGroup(code);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Join request sent to the group owner.'
              : 'Could not send the join request.',
        ),
      ),
    );
  }

  Future<void> _handleDeviceTap(Device device) async {
    if (_messaging == null) return;
    if (_messaging!.canMessage(device.id)) {
      _openPeerChat(device);
      return;
    }

    final granted = await _messaging!.requestPermission(
      peerIp: device.ip,
      peerId: device.id,
      peerName: device.name,
    );
    if (!mounted) return;

    if (granted) {
      _openPeerChat(device);
      return;
    }

    final reason = _messaging!.permissionFailureMessageFor(device.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reason ?? '${device.name} did not allow the connection.'),
      ),
    );
  }

  void _openPeerChat(Device device) {
    if (_messaging == null) return;
    final conversationKey = _conversationKey(ConversationKind.peer, device.id);
    _openConversationKey = conversationKey;
    unawaited(
      _notifications.clearConversationNotifications(
        ConversationKind.peer,
        device.id,
      ),
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationScreen.peer(
          device: device,
          messaging: _messaging!,
          chatPreferences: _chatPreferences,
          myName: _myName,
          myId: widget.myId,
        ),
      ),
    ).whenComplete(() {
      if (_openConversationKey == conversationKey) {
        _openConversationKey = null;
      }
      unawaited(
        _notifications.clearConversationNotifications(
          ConversationKind.peer,
          device.id,
        ),
      );
    });
  }

  void _openGroupChat(GroupRoom room) {
    if (_messaging == null) return;
    final conversationKey = _conversationKey(
      ConversationKind.group,
      room.groupId,
    );
    _openConversationKey = conversationKey;
    unawaited(
      _notifications.clearConversationNotifications(
        ConversationKind.group,
        room.groupId,
      ),
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationScreen.group(
          room: room,
          messaging: _messaging!,
          chatPreferences: _chatPreferences,
          myName: _myName,
          myId: widget.myId,
        ),
      ),
    ).whenComplete(() {
      if (_openConversationKey == conversationKey) {
        _openConversationKey = null;
      }
      unawaited(
        _notifications.clearConversationNotifications(
          ConversationKind.group,
          room.groupId,
        ),
      );
    });
  }

  void _openSettings() {
    if (_messaging == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          messaging: _messaging!,
          myName: _myName,
          myId: widget.myId,
          rememberName: _rememberName,
          onlineMode: _onlineMode,
          onlyInitiatedConnections: _onlyInitiatedConnections,
          chatPreferences: _chatPreferences,
          onProfileChanged: _updateProfile,
          onOnlineModeChanged: _setOnlineMode,
          onOnlyInitiatedConnectionsChanged: _setOnlyInitiatedConnections,
        ),
      ),
    );
  }

  void _openConnectionReadiness() {
    if (_messaging == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConnectionReadinessScreen(
          permissionManager: _permissionManager,
          discoveryDiagnostics: _diagnostics,
          connectionDiagnostics: _messaging!.diagnostics,
          peers: _messaging!.knownPeers,
          onStartDiscovery: _startDiscovery,
          onManualConnect: _manualConnect,
        ),
      ),
    );
  }

  Future<bool> _manualConnect(String endpoint) async {
    final success =
        await _messaging?.connectToManualEndpoint(endpoint) ?? false;
    if (!mounted) return success;
    setState(() {});
    return success;
  }

  String _permissionLabel(String peerId) {
    if (_messaging == null) return 'not connected';
    switch (_messaging!.permissionStateFor(peerId)) {
      case PeerPermissionState.requesting:
        return 'waiting for approval';
      case PeerPermissionState.incoming:
        return 'request pending';
      case PeerPermissionState.granted:
        return 'connected';
      case PeerPermissionState.denied:
        return 'permission denied';
      case PeerPermissionState.none:
        return 'not connected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _messaging?.groups ?? const <GroupRoom>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Share files locally'),
        actions: [
          _topIconButton(
            context: context,
            tooltip: 'Connection readiness',
            onPressed: _openConnectionReadiness,
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
          _topIconButton(
            context: context,
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          _topIconButton(
            context: context,
            tooltip: 'Refresh devices',
            onPressed: (!_onlineMode || _isRefreshingDiscovery)
                ? null
                : _refreshDiscovery,
            icon: _isRefreshingDiscovery
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_showConnectionLostBatteryHint) ...[
              BatteryOptimizationBanner(
                reason: BatteryOptimizationPromptReason.connectionLost,
                onDismissed: () {
                  if (mounted) {
                    setState(() => _showConnectionLostBatteryHint = false);
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
            _buildDiscoveryStatusCard(),
            const SizedBox(height: 16),
            _buildQuickActions(),
            const SizedBox(height: 20),
            _buildPeerSection(),
            const SizedBox(height: 20),
            _buildGroupSection(groups),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _createGroup,
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('Create Group'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.lightBlueAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _joinGroup,
            icon: const Icon(Icons.key_outlined),
            label: const Text('Join Group'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDiscoveryStatusCard() {
    final diagnostics = _diagnostics;
    if (!_onlineMode) {
      return const _StatusCard(
        color: Colors.orangeAccent,
        icon: Icons.visibility_off_outlined,
        title: 'Offline Mode',
        subtitle:
            'Discovery is paused and ShareViaLAN rejects new connection requests. Existing approved peers and groups still work.',
        details:
            'Approved direct peers can still chat and share while reachable.',
      );
    }

    final hasError = _discoveryError != null;
    final color = hasError
        ? Colors.redAccent
        : _isStartingDiscovery
        ? Colors.amberAccent
        : Colors.greenAccent;
    final icon = hasError
        ? Icons.wifi_off
        : _isStartingDiscovery
        ? Icons.radar
        : Icons.wifi_tethering;
    final title = hasError
        ? 'Discovery Offline'
        : _isStartingDiscovery
        ? 'Starting Discovery'
        : 'Discovery Running';
    final subtitle = hasError
        ? 'ShareViaLAN could not bind local discovery on this machine.'
        : _isStartingDiscovery
        ? 'Preparing sockets and checking local interfaces...'
        : _peers.isEmpty
        ? 'Scanning continues in the background. Waiting for other devices to reply.'
        : '${_peers.length} peer${_peers.length == 1 ? '' : 's'} visible on the network.';
    final details = diagnostics == null
        ? null
        : diagnostics.interfaces.isEmpty
        ? 'No viable IPv4 interface detected yet.'
        : 'Local endpoint ${diagnostics.myIp}:$discoveryPort on ${diagnostics.primaryInterfaceName} • ${diagnostics.broadcastsSent} broadcasts • ${diagnostics.inboundPackets} inbound packets';

    return _StatusCard(
      color: color,
      icon: icon,
      title: title,
      subtitle: subtitle,
      details: details,
      footer: _shouldShowLinuxFirewallHint ? _buildLinuxFirewallHint() : null,
    );
  }

  Widget _buildPeerSection() {
    final peers = _peers;
    return _SectionCard(
      title: 'Peers',
      children: [
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _onlineMode
                  ? 'No peers visible yet. Discovery is still running.'
                  : 'Offline mode hides you from new peers. Approved direct peers appear here when reachable.',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ...peers.map(_buildPeerTile),
      ],
    );
  }

  Widget _buildPeerTile(Device device) {
    final state =
        _messaging?.permissionStateFor(device.id) ?? PeerPermissionState.none;
    final isBusy =
        state == PeerPermissionState.requesting ||
        state == PeerPermissionState.incoming;
    final isGranted = state == PeerPermissionState.granted;

    final subtitleParts = <String>[
      _routeStatusLabel(device),
      if (device.ip.isNotEmpty) device.ip else 'Direct peer',
      _permissionLabel(device.id),
      if (!device.isDirect && device.viaPeerName != null)
        'via ${device.viaPeerName}',
      if (!device.isDirect) '${device.hopCount} hops',
      'last seen ${_formatRelativeAge(device.lastSeen)}',
    ];
    final actionLabel = isGranted
        ? 'Chat'
        : isBusy
        ? 'Pending'
        : 'Connect';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: device.isReachable && !isBusy
          ? () => _handleDeviceTap(device)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: device.isOnline
                  ? Colors.greenAccent
                  : Colors.grey.shade700,
              child: Icon(
                device.isDirect ? Icons.devices : Icons.hub_outlined,
                color: Colors.black,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: (!device.isReachable || isBusy)
                          ? null
                          : () => _handleDeviceTap(device),
                      icon: Icon(
                        isGranted ? Icons.chat_bubble_outline : Icons.link,
                        size: 16,
                      ),
                      label: Text(actionLabel),
                      style: TextButton.styleFrom(
                        foregroundColor: isGranted
                            ? Colors.greenAccent
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<_PeerTileAction>(
              tooltip: 'Peer actions',
              onSelected: (action) {
                switch (action) {
                  case _PeerTileAction.open:
                    _handleDeviceTap(device);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _PeerTileAction.open,
                  enabled: device.isReachable && !isBusy,
                  child: Text(actionLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _routeStatusLabel(Device device) {
    switch (device.routeStatus) {
      case PeerRouteStatus.directOnline:
        return 'Direct / Online';
      case PeerRouteStatus.stale:
        return 'Stale';
      case PeerRouteStatus.offline:
        return 'Offline';
    }
  }

  Widget _buildGroupSection(List<GroupRoom> groups) {
    return _SectionCard(
      title: 'Groups',
      children: [
        if (groups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Create a group to invite peers with owner approval.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ...groups.map((group) {
          final onlineCount = group.members.where((member) {
            if (member.peerId == widget.myId) return true;
            return _messaging?.peerSummaryFor(member.peerId)?.isOnline ?? false;
          }).length;
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            leading: const CircleAvatar(
              backgroundColor: Colors.lightBlueAccent,
              child: Icon(Icons.group_outlined, color: Colors.black),
            ),
            title: Text(group.name),
            subtitle: Text(
              '${group.members.length} members • $onlineCount online${group.isOwner ? ' • owner' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openGroupChat(group),
          );
        }),
      ],
    );
  }

  bool get _shouldShowLinuxFirewallHint {
    final diagnostics = _diagnostics;
    if (!_onlineMode ||
        defaultTargetPlatform != TargetPlatform.linux ||
        _isStartingDiscovery ||
        _discoveryError != null ||
        diagnostics == null) {
      return false;
    }
    if (_peers.isNotEmpty ||
        diagnostics.interfaces.isEmpty ||
        !diagnostics.isListening) {
      return false;
    }
    if (diagnostics.inboundPackets > 0 || diagnostics.broadcastsSent < 3) {
      return false;
    }
    return DateTime.now().difference(diagnostics.startedAt) >=
        const Duration(seconds: 8);
  }

  Widget _buildLinuxFirewallHint() {
    const temporaryRule =
        'sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp';
    const permanentRule =
        'sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp --permanent\nsudo firewall-cmd --reload';

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.admin_panel_settings, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Linux firewall may be blocking discovery replies',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'ShareViaLAN needs UDP 9001 and TCP 9002 open.',
            style: TextStyle(color: Colors.white70),
          ),
          SizedBox(height: 12),
          Text(
            'Temporary test rule',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          _CommandBlock(command: temporaryRule),
          SizedBox(height: 10),
          Text(
            'Keep it after reboot',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          _CommandBlock(command: permanentRule),
        ],
      ),
    );
  }
}

class ConversationScreen extends StatefulWidget {
  final ConversationKind kind;
  final String conversationId;
  final String title;
  final String subtitle;
  final String? peerIp;
  final MessagingService messaging;
  final ChatPreferencesRepository chatPreferences;
  final String myName;
  final String myId;

  const ConversationScreen._({
    required this.kind,
    required this.conversationId,
    required this.title,
    required this.subtitle,
    required this.messaging,
    required this.chatPreferences,
    required this.myName,
    required this.myId,
    this.peerIp,
  });

  factory ConversationScreen.peer({
    required Device device,
    required MessagingService messaging,
    required ChatPreferencesRepository chatPreferences,
    required String myName,
    required String myId,
  }) {
    final subtitle = device.ip.isEmpty
        ? (device.viaPeerName == null
              ? 'Direct peer'
              : 'via ${device.viaPeerName}')
        : device.ip;
    return ConversationScreen._(
      kind: ConversationKind.peer,
      conversationId: device.id,
      title: device.name,
      subtitle: subtitle,
      peerIp: device.ip,
      messaging: messaging,
      chatPreferences: chatPreferences,
      myName: myName,
      myId: myId,
    );
  }

  factory ConversationScreen.group({
    required GroupRoom room,
    required MessagingService messaging,
    required ChatPreferencesRepository chatPreferences,
    required String myName,
    required String myId,
  }) {
    return ConversationScreen._(
      kind: ConversationKind.group,
      conversationId: room.groupId,
      title: room.name,
      subtitle: '${room.members.length} members',
      messaging: messaging,
      chatPreferences: chatPreferences,
      myName: myName,
      myId: myId,
    );
  }

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  bool _isSendingText = false;
  bool _isPickingFile = false;
  bool _isDraggingFile = false;
  bool _chatPersistent = false;
  ChatFeatureSettings _chatSettings = ChatFeatureSettings.defaults;
  ChatFeatureSettings _globalSettings = ChatFeatureSettings.defaults;
  bool _chatSettingsLoaded = false;

  @override
  void initState() {
    super.initState();
    _chatPersistent = widget.messaging.isChatPersistent(
      widget.kind,
      widget.conversationId,
    );
    _reloadMessages();
    unawaited(_loadChatSettings());
    widget.chatPreferences.addListener(_handleChatPreferencesChanged);
    widget.messaging.addListener(_handleMessagingChanged);
  }

  @override
  void dispose() {
    widget.messaging.removeListener(_handleMessagingChanged);
    widget.chatPreferences.removeListener(_handleChatPreferencesChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _supportsDesktopDrop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isWindows;
  }

  bool get _canChat {
    if (widget.kind == ConversationKind.peer) {
      return widget.messaging.canMessage(widget.conversationId);
    }
    return true;
  }

  bool get _canTransferFiles => _canChat && _chatSettings.allowFileReceiving;

  bool get _canUseCanvas => _canChat && _chatSettings.allowCanvasDrawing;

  bool get _canChangeChatPersistence => widget.messaging
      .canChangeChatPersistence(widget.kind, widget.conversationId);

  bool get _showFileButton =>
      _chatSettingsLoaded &&
      _globalSettings.allowFileReceiving &&
      _chatSettings.allowFileReceiving;

  bool get _showCanvasButton =>
      _chatSettingsLoaded &&
      _globalSettings.allowCanvasDrawing &&
      _chatSettings.allowCanvasDrawing;

  List<GroupMember> get _members {
    switch (widget.kind) {
      case ConversationKind.peer:
        return const <GroupMember>[];
      case ConversationKind.group:
        return widget.messaging.groupById(widget.conversationId)?.members ??
            const <GroupMember>[];
    }
  }

  void _handleMessagingChanged() {
    if (!mounted) return;
    final previousLength = _messages.length;
    final previousLastMessageId = _messages.isEmpty
        ? null
        : _messages.last.messageId;
    _reloadMessages();
    setState(() {
      _chatPersistent = widget.messaging.isChatPersistent(
        widget.kind,
        widget.conversationId,
      );
    });
    final nextLastMessageId = _messages.isEmpty
        ? null
        : _messages.last.messageId;
    if (_messages.length != previousLength ||
        nextLastMessageId != previousLastMessageId) {
      _scrollToBottom();
    }
  }

  void _handleChatPreferencesChanged() {
    unawaited(_loadChatSettings());
  }

  void _reloadMessages() {
    _messages
      ..clear()
      ..addAll(_currentHistory());
  }

  List<ChatMessage> _currentHistory() {
    switch (widget.kind) {
      case ConversationKind.peer:
        return widget.messaging.getHistory(widget.conversationId);
      case ConversationKind.group:
        return widget.messaging.getGroupHistory(widget.conversationId);
    }
  }

  Future<void> _loadChatSettings() async {
    final globalSettings = await widget.chatPreferences.loadGlobalDefaults();
    final settings = await widget.chatPreferences.loadChatSettings(
      widget.kind,
      widget.conversationId,
    );
    if (!mounted) return;
    setState(() {
      _globalSettings = globalSettings;
      _chatSettings = settings;
      _chatSettingsLoaded = true;
    });
  }

  Future<void> _saveChatSettings(ChatFeatureSettings settings) async {
    setState(() => _chatSettings = settings);
    await widget.chatPreferences.saveChatSettings(
      widget.kind,
      widget.conversationId,
      settings,
    );
    if (!mounted) return;
    setState(() => _chatSettings = settings);
  }

  Future<void> _toggleChatPersistence([bool? value]) async {
    final next = value ?? !_chatPersistent;
    if (!_canChangeChatPersistence) {
      _showSnack('Only the group owner can change persistence.');
      return;
    }
    final previous = _chatPersistent;
    setState(() => _chatPersistent = next);
    final changed = await widget.messaging.setChatPersistence(
      kind: widget.kind,
      conversationId: widget.conversationId,
      enabled: next,
    );
    if (!mounted) return;
    if (!changed) {
      setState(() => _chatPersistent = previous);
      _showSnack('Could not update chat persistence.', isError: true);
      return;
    }
    _reloadMessages();
    setState(() {});
  }

  String get _subtitle {
    switch (widget.kind) {
      case ConversationKind.peer:
        final peer = widget.messaging.peerSummaryFor(widget.conversationId);
        if (peer == null) return widget.subtitle;
        final parts = <String>[
          if (peer.ip.isNotEmpty) peer.ip else 'Direct peer',
          if (!peer.isDirect && peer.viaPeerName != null)
            'via ${peer.viaPeerName}',
          if (!peer.isDirect) '${peer.hopCount} hops',
        ];
        return parts.join(' • ');
      case ConversationKind.group:
        final room = widget.messaging.groupById(widget.conversationId);
        if (room == null) return widget.subtitle;
        final onlineCount = room.members.where(_isMemberOnline).length;
        return '${room.members.length} members • $onlineCount online';
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSendingText) return;
    if (!_canChat) {
      _showSnack('Connect before sending messages.');
      return;
    }

    setState(() => _isSendingText = true);
    _controller.clear();

    bool success;
    try {
      switch (widget.kind) {
        case ConversationKind.peer:
          success = await widget.messaging.sendMessage(
            peerIp: widget.peerIp,
            peerId: widget.conversationId,
            text: text,
          );
        case ConversationKind.group:
          success = await widget.messaging.sendGroupMessage(
            groupId: widget.conversationId,
            text: text,
          );
      }
    } catch (error) {
      debugPrint('Send message failed: $error');
      success = false;
    }

    if (!mounted) return;
    setState(() => _isSendingText = false);
    if (!success) {
      _showSnack(
        widget.messaging.diagnostics.lastTransportError ??
            'Failed to deliver the message. Check that both devices are on the same Wi-Fi or hotspot and ShareViaLAN is open.',
        isError: true,
      );
    }
  }

  Future<void> _sendFile() async {
    if (!_canChat) {
      _showSnack('Connect before sending files.');
      return;
    }
    if (!_chatSettings.allowFileReceiving) {
      _showSnack('File transfer is disabled for this chat.');
      return;
    }

    if (Platform.isAndroid) {
      await _sendAndroidPickedFiles();
      return;
    }

    setState(() => _isPickingFile = true);
    List<PlatformFile> files = const [];
    try {
      files = await FilePicker.pickFiles(type: FileType.any);
    } catch (error) {
      debugPrint('File picker failed: $error');
      if (mounted) _showSnack('Could not open the file picker.', isError: true);
    }
    if (!mounted) return;
    setState(() => _isPickingFile = false);

    if (files.isEmpty) return;
    final singleVideo =
        files.length == 1 && _isVideoFileName(files.single.name);
    final containsVideo = files.any((file) => _isVideoFileName(file.name));
    _VideoSendAction? videoAction;
    if (singleVideo) {
      videoAction = await _chooseVideoAction(files.single.name);
      if (!mounted || videoAction == null) return;
    } else if (containsVideo) {
      await _showSingleVideoStreamWarning();
    }

    for (final file in files) {
      if (file.path == null) {
        _showSnack('Could not access ${file.name}.', isError: true);
        continue;
      }
      if (singleVideo &&
          videoAction != null &&
          videoAction != _VideoSendAction.sendFile) {
        await _shareVideoStreamPath(
          file.path!,
          file.name,
          streamMode: videoAction.streamMode,
        );
        continue;
      }
      await _sendFilePath(file.path!, file.name);
    }
  }

  Future<void> _sendAndroidPickedFiles() async {
    setState(() => _isPickingFile = true);
    List<AndroidPickedFile>? picked;
    try {
      picked = await LanPlatformChannel.pickAndroidFiles(allowMultiple: true);
    } catch (error) {
      debugPrint('Android file picker failed: $error');
      if (mounted) _showSnack('Could not open the file picker.', isError: true);
    }
    if (!mounted) return;
    setState(() => _isPickingFile = false);

    if (picked == null || picked.isEmpty) return;
    final singleVideo =
        picked.length == 1 && _isVideoFileName(picked.single.name);
    final containsVideo = picked.any((file) => _isVideoFileName(file.name));
    _VideoSendAction? videoAction;
    if (singleVideo) {
      videoAction = await _chooseVideoAction(picked.single.name);
      if (!mounted || videoAction == null) return;
    } else if (containsVideo) {
      await _showSingleVideoStreamWarning();
    }

    for (final file in picked) {
      final cached = await LanPlatformChannel.cacheAndroidPickedFile(
        identifier: file.identifier,
        fileName: file.name,
      );
      if (!mounted) return;
      if (cached == null || cached.path.isEmpty) {
        _showSnack('Could not access ${file.name}.', isError: true);
        continue;
      }

      if (singleVideo &&
          videoAction != null &&
          videoAction != _VideoSendAction.sendFile) {
        final shared = await _shareVideoStreamPath(
          cached.path,
          cached.name,
          streamMode: videoAction.streamMode,
          deleteSourceOnComplete: true,
        );
        if (!shared) {
          await _deleteTemporaryAndroidPickedFile(cached.path);
        }
        continue;
      }

      try {
        await _sendFilePath(cached.path, cached.name);
      } finally {
        await _deleteTemporaryAndroidPickedFile(cached.path);
      }
    }
  }

  Future<void> _deleteTemporaryAndroidPickedFile(String path) async {
    if (!Platform.isAndroid || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
      final parent = file.parent;
      if (parent.path.contains(
        '${Platform.pathSeparator}lancom_picked'
        '${Platform.pathSeparator}',
      )) {
        await parent.delete();
      }
    } catch (error) {
      debugPrint('Could not remove temporary picked file $path: $error');
    }
  }

  Future<_VideoSendAction?> _chooseVideoAction(String fileName) async {
    return showDialog<_VideoSendAction>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Video selected'),
          content: Text('Choose how to send "$fileName".'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_VideoSendAction.sendFile),
              icon: const Icon(Icons.attach_file, size: 16),
              label: const Text('Send File'),
            ),
            ElevatedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_VideoSendAction.streamVideo),
              icon: const Icon(Icons.movie_outlined, size: 16),
              label: const Text('Stream Video'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.lightBlueAccent,
                foregroundColor: Colors.black,
              ),
            ),
            ElevatedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_VideoSendAction.streamAndSend),
              icon: const Icon(Icons.playlist_add_check, size: 16),
              label: const Text('Stream + Send'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.lightBlueAccent,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSingleVideoStreamWarning() {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('One video at a time'),
          content: const Text(
            'Streaming supports one video at a time. Please select only one video to stream.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendFilePath(String filePath, String fileName) async {
    if (!_chatSettings.allowFileReceiving) {
      _showSnack('File transfer is disabled for this chat.');
      return;
    }

    bool success;
    try {
      final type = await FileSystemEntity.type(filePath);
      if (type != FileSystemEntityType.file) {
        _showSnack('Only files can be sent.');
        return;
      }

      switch (widget.kind) {
        case ConversationKind.peer:
          success = await widget.messaging.sendFile(
            peerIp: widget.peerIp,
            peerId: widget.conversationId,
            filePath: filePath,
            fileName: fileName,
          );
        case ConversationKind.group:
          success = await widget.messaging.sendGroupFile(
            groupId: widget.conversationId,
            filePath: filePath,
            fileName: fileName,
          );
      }
    } catch (error) {
      debugPrint('Send file failed: $error');
      success = false;
    }

    if (!mounted) return;
    if (!success) {
      _showSnack(
        widget.messaging.diagnostics.lastTransportError ??
            'Failed to send $fileName. Check the direct connection and try again.',
        isError: true,
      );
    }
  }

  Future<bool> _shareVideoStreamPath(
    String filePath,
    String fileName, {
    required StreamTransferMode streamMode,
    bool deleteSourceOnComplete = false,
  }) async {
    if (!_chatSettings.allowFileReceiving) {
      _showSnack('File transfer is disabled for this chat.');
      return false;
    }

    bool success;
    try {
      final type = await FileSystemEntity.type(filePath);
      if (type != FileSystemEntityType.file) {
        _showSnack('Only files can be shared for streaming.');
        return false;
      }

      switch (widget.kind) {
        case ConversationKind.peer:
          success = await widget.messaging.shareVideoStream(
            peerIp: widget.peerIp,
            peerId: widget.conversationId,
            filePath: filePath,
            fileName: fileName,
            streamMode: streamMode,
            deleteSourceOnComplete: deleteSourceOnComplete,
          );
        case ConversationKind.group:
          success = await widget.messaging.shareGroupVideoStream(
            groupId: widget.conversationId,
            filePath: filePath,
            fileName: fileName,
            streamMode: streamMode,
            deleteSourceOnComplete: deleteSourceOnComplete,
          );
      }
    } catch (error) {
      debugPrint('Stream share failed: $error');
      success = false;
    }

    if (!mounted) return false;
    if (!success) {
      _showSnack(
        widget.messaging.diagnostics.lastTransportError ??
            'Failed to share $fileName. Check the direct connection and try again.',
        isError: true,
      );
    }
    return success;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _requestPermissionFromChat() async {
    final granted = await widget.messaging.requestPermission(
      peerIp: widget.peerIp,
      peerId: widget.conversationId,
      peerName: widget.title,
    );
    if (!mounted) return;
    if (!granted) {
      final reason = widget.messaging.permissionFailureMessageFor(
        widget.conversationId,
      );
      _showSnack(reason ?? '${widget.title} did not allow the connection.');
    }
  }

  Future<void> _openCanvas() async {
    if (!_chatSettings.allowCanvasDrawing) {
      _showSnack('Canvas drawing is disabled for this chat.');
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CanvasScreen(
          conversationKind: widget.kind,
          conversationId: widget.conversationId,
          title: widget.title,
          messaging: widget.messaging,
          myId: widget.myId,
          myName: widget.myName,
          peerIp: widget.peerIp,
          chatPreferences: widget.chatPreferences,
        ),
      ),
    );
  }

  Future<void> _showChatSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C1622),
      builder: (context) {
        var draft = _chatSettings;
        var persistentDraft = _chatPersistent;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> update(ChatFeatureSettings next) async {
              setSheetState(() => draft = next);
              await _saveChatSettings(next);
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Chat Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: persistentDraft,
                      onChanged: !_canChangeChatPersistence
                          ? null
                          : (value) {
                              setSheetState(() => persistentDraft = value);
                              unawaited(_toggleChatPersistence(value));
                            },
                      title: const Text('Keep Chat Persistent'),
                      subtitle: Text(
                        !_canChangeChatPersistence
                            ? 'Only the group owner can change this.'
                            : persistentDraft
                            ? 'Messages stay saved locally after disconnect.'
                            : 'Messages clear on disconnect.',
                      ),
                    ),
                    const Divider(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: draft.allowFileReceiving,
                      onChanged: !_globalSettings.allowFileReceiving
                          ? null
                          : (value) => unawaited(
                              update(draft.copyWith(allowFileReceiving: value)),
                            ),
                      title: const Text('File Receive'),
                      subtitle: Text(
                        !_globalSettings.allowFileReceiving
                            ? 'Disabled globally.'
                            : 'Hide or show file controls in this chat.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: draft.allowCanvasDrawing,
                      onChanged: !_globalSettings.allowCanvasDrawing
                          ? null
                          : (value) => unawaited(
                              update(draft.copyWith(allowCanvasDrawing: value)),
                            ),
                      title: const Text('Canvas'),
                      subtitle: Text(
                        !_globalSettings.allowCanvasDrawing
                            ? 'Disabled globally.'
                            : 'Hide or show the canvas button in this chat.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: draft.allowMessageNotifications,
                      onChanged: (value) => unawaited(
                        update(
                          draft.copyWith(allowMessageNotifications: value),
                        ),
                      ),
                      title: const Text('Allow Message Notifications'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Clear Conversation'),
          content: Text('Clear local messages in "${widget.title}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    switch (widget.kind) {
      case ConversationKind.peer:
        widget.messaging.clearChat(widget.conversationId);
      case ConversationKind.group:
        widget.messaging.clearGroupChat(widget.conversationId);
    }
    if (!mounted) return;
    setState(() => _messages.clear());
  }

  Future<void> _confirmDisconnect() async {
    final hasActiveTransfer = widget.messaging
        .hasActiveTransfersForConversation(widget.kind, widget.conversationId);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: !hasActiveTransfer,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Disconnect'),
          content: Text(
            hasActiveTransfer
                ? 'A transfer or stream is active. Are you sure you want to disconnect? This will cancel it.'
                : 'Disconnect from ${widget.title}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Disconnect'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.messaging.disconnectConversation(
      kind: widget.kind,
      conversationId: widget.conversationId,
    );
    if (!mounted) return;
    _showSnack('Disconnected from ${widget.title}.');
  }

  Future<void> _showMembersSheet() async {
    if (_members.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C1622),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Group members',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              ..._members.map((member) {
                final online = _isMemberOnline(member);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 8,
                    backgroundColor: online
                        ? Colors.greenAccent
                        : Colors.grey.shade700,
                  ),
                  title: Text(member.name),
                  subtitle: Text(member.isOwner ? 'Owner' : 'Member'),
                  trailing: Text(
                    online ? 'Online' : 'Offline',
                    style: TextStyle(
                      color: online ? Colors.greenAccent : Colors.white54,
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  bool _isMemberOnline(GroupMember member) {
    if (member.peerId == widget.myId) return true;
    return widget.messaging.peerSummaryFor(member.peerId)?.isOnline ?? false;
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showSnack('Copied to clipboard');
  }

  Future<void> _showSavedPath(ChatMessage message) async {
    final path = message.localPath;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    _showSnack('Saved to $path');
  }

  Future<void> _openFile(ChatMessage message) async {
    final path = message.localPath;
    if (path == null || path.isEmpty) return;
    final result = await ReceivedFileOpener.open(path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      _showSnack(result.message, isError: true);
    }
  }

  Future<void> _openVideoStream(ChatMessage message) async {
    if (!message.isStream || message.transferId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StreamVideoPlayerScreen(
          messaging: widget.messaging,
          conversationKind: widget.kind,
          conversationId: widget.conversationId,
          initialMessage: message,
        ),
      ),
    );
  }

  Future<void> _acceptFile(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    if (!message.isStream && !message.isMe) {
      final choice = await _chooseIncomingFileAcceptMode(message);
      if (!mounted || choice == null) return;
      if (choice == _IncomingFileAcceptChoice.thisFile) {
        await widget.messaging.acceptIncomingFile(transferId);
      } else {
        final accepted = await widget.messaging.acceptIncomingFilesFromSender(
          transferId,
        );
        if (mounted && accepted > 0) {
          _showSnack(
            'Accepting upcoming files from ${message.fromName} automatically.',
          );
        }
      }
      return;
    }
    await widget.messaging.acceptIncomingFile(transferId);
  }

  Future<_IncomingFileAcceptChoice?> _chooseIncomingFileAcceptMode(
    ChatMessage message,
  ) {
    final fileName = message.fileName ?? 'this file';
    return showDialog<_IncomingFileAcceptChoice>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: const Text('Accept file?'),
          content: Text(
            'Accept "$fileName" only, or automatically accept more files from ${message.fromName} in this chat for a short time?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_IncomingFileAcceptChoice.thisFile),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Only this file'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.lightBlueAccent,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.of(
                context,
              ).pop(_IncomingFileAcceptChoice.allFromSender),
              icon: const Icon(Icons.done_all, size: 16),
              label: const Text('Accept all'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _requestStream(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    try {
      await widget.messaging.requestIncomingStream(transferId);
    } catch (error) {
      debugPrint('Stream start failed: $error');
      if (mounted) {
        _showSnack('Could not start the video stream.', isError: true);
      }
      return;
    }
    if (!mounted) return;
    _reloadMessages();
    final next = _messageForTransfer(transferId) ?? message;
    await _openVideoStream(next);
  }

  ChatMessage? _messageForTransfer(String transferId) {
    for (final message in _messages) {
      if (message.transferId == transferId) return message;
    }
    return null;
  }

  Future<void> _rejectFile(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    await widget.messaging.rejectIncomingFile(transferId);
  }

  Future<void> _pauseFile(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    await widget.messaging.pauseTransfer(transferId);
  }

  Future<void> _resumeFile(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    await widget.messaging.resumeTransfer(transferId);
  }

  Future<void> _cancelFile(ChatMessage message) async {
    final transferId = message.transferId;
    if (transferId == null) return;
    await widget.messaging.cancelTransfer(transferId);
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : null,
      ),
    );
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    if (!_supportsDesktopDrop) return;
    setState(() => _isDraggingFile = false);
    if (!_chatSettings.allowFileReceiving) {
      _showSnack('File transfer is disabled for this chat.');
      return;
    }
    final files = details.files;
    final singleVideo =
        files.length == 1 && _isVideoFileName(files.single.name);
    final containsVideo = files.any((file) => _isVideoFileName(file.name));
    _VideoSendAction? videoAction;
    if (singleVideo) {
      videoAction = await _chooseVideoAction(files.single.name);
      if (!mounted || videoAction == null) return;
    } else if (containsVideo) {
      await _showSingleVideoStreamWarning();
    }

    for (final droppedFile in files) {
      if (singleVideo &&
          videoAction != null &&
          videoAction != _VideoSendAction.sendFile) {
        await _shareVideoStreamPath(
          droppedFile.path,
          droppedFile.name,
          streamMode: videoAction.streamMode,
        );
      } else {
        await _sendFilePath(droppedFile.path, droppedFile.name);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(widget.title),
            Text(
              _subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          if (widget.kind != ConversationKind.peer)
            _topIconButton(
              context: context,
              tooltip: 'Members',
              onPressed: _members.isEmpty ? null : _showMembersSheet,
              icon: const Icon(Icons.groups_outlined),
            ),
          _topIconButton(
            context: context,
            tooltip: _chatPersistent
                ? 'Persistent chat on'
                : 'Persistent chat off',
            onPressed: _canChangeChatPersistence
                ? () => _toggleChatPersistence()
                : null,
            icon: Icon(
              _chatPersistent ? Icons.push_pin : Icons.push_pin_outlined,
            ),
          ),
          if (_showCanvasButton)
            _topIconButton(
              context: context,
              tooltip: 'Canvas',
              onPressed: _canUseCanvas ? _openCanvas : null,
              icon: const Icon(Icons.draw_outlined),
            ),
          _topIconButton(
            context: context,
            tooltip: 'Disconnect',
            onPressed: _canChat ? _confirmDisconnect : null,
            icon: const Icon(Icons.link_off_outlined),
          ),
          _topIconButton(
            context: context,
            tooltip: 'Clear chat',
            onPressed: _messages.isEmpty ? null : _confirmClearChat,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          _topIconButton(
            context: context,
            tooltip: 'Chat settings',
            onPressed: _chatSettingsLoaded ? _showChatSettingsSheet : null,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _buildDropWrapper(
          Column(
            children: [
              if (widget.kind == ConversationKind.peer)
                _buildPermissionBanner(),
              Expanded(child: _buildMessageList()),
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropWrapper(Widget child) {
    if (!_supportsDesktopDrop) return child;

    return DropTarget(
      onDragDone: _handleDrop,
      onDragEntered: (_) => setState(() => _isDraggingFile = true),
      onDragExited: (_) => setState(() => _isDraggingFile = false),
      child: Stack(
        children: [
          child,
          if (_isDraggingFile)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.56),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1622),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.lightBlueAccent),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          color: Colors.lightBlueAccent,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Drop files to send',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    if (_canChat || widget.kind != ConversationKind.peer) {
      return const SizedBox.shrink();
    }

    final state = widget.messaging.permissionStateFor(widget.conversationId);
    final isWaiting =
        state == PeerPermissionState.requesting ||
        state == PeerPermissionState.incoming;
    final text = switch (state) {
      PeerPermissionState.requesting =>
        'Waiting for ${widget.title} to allow this connection.',
      PeerPermissionState.incoming =>
        'Respond to the pending connection request to start chatting.',
      PeerPermissionState.denied =>
        'Connection permission was denied. You can try again.',
      PeerPermissionState.none =>
        'Connect before messaging, drawing, or sharing files.',
      PeerPermissionState.granted => '',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF0C1622),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: Colors.amberAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70)),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: isWaiting ? null : _requestPermissionFromChat,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.lightBlueAccent,
              foregroundColor: Colors.black,
            ),
            child: Text(isWaiting ? 'Pending' : 'Connect'),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      final text = switch (widget.kind) {
        ConversationKind.peer =>
          _canChat
              ? 'No messages yet.\nSay hello!'
              : 'Connect to start chatting.',
        ConversationKind.group =>
          'No group messages yet.\nSay hello to the room!',
      };
      return Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildBubble(_messages[index]),
    );
  }

  Widget _buildBubble(ChatMessage msg) {
    if (msg.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            msg.text,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final isMe = msg.isMe;
    return GestureDetector(
      onLongPress: () {
        if (!msg.isFile) {
          _copyToClipboard(msg.text);
        }
      },
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.76,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isMe
                ? Colors.lightBlueAccent.shade700
                : Colors.grey.shade900,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
          ),
          child: msg.isFile
              ? _buildFileBubbleContent(msg)
              : Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMe &&
                        (widget.kind != ConversationKind.peer ||
                            msg.viaPeerName != null)) ...[
                      Text(
                        msg.fromName,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.lightBlueAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (msg.viaPeerName != null)
                        Text(
                          'via ${msg.viaPeerName}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white60,
                          ),
                        ),
                      const SizedBox(height: 2),
                    ],
                    if (isMe && msg.viaPeerName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'via ${msg.viaPeerName}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    Text(msg.text, style: const TextStyle(fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(msg.timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        color: isMe ? Colors.black54 : Colors.white60,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildFileBubbleContent(ChatMessage msg) {
    final progress = msg.transferProgress.clamp(0, 1).toDouble();
    final isActive = msg.isTransferActive;
    final isMe = msg.isMe;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isMe) ...[
          Text(
            msg.fromName,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (msg.viaPeerName != null)
            Text(
              'via ${msg.viaPeerName}',
              style: const TextStyle(fontSize: 10, color: Colors.white60),
            ),
          const SizedBox(height: 6),
        ],
        if (isMe && msg.viaPeerName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'via ${msg.viaPeerName}',
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
          ),
        Row(
          children: [
            Icon(
              msg.isStream ? Icons.movie_outlined : Icons.attach_file,
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                msg.fileName ?? 'File',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (msg.fileSize != null)
          Text(
            _formatBytes(msg.fileSize!),
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        if (isActive) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: Colors.black26,
            color: Colors.lightBlueAccent,
          ),
        ],
        const SizedBox(height: 8),
        Text(
          _fileStatusText(msg),
          style: TextStyle(
            fontSize: 11,
            color:
                msg.transferStatus == TransferStatus.failed ||
                    msg.transferStatus == TransferStatus.canceled ||
                    msg.transferStatus == TransferStatus.rejected
                ? Colors.redAccent.shade100
                : Colors.white70,
          ),
        ),
        const SizedBox(height: 8),
        if (!isMe && msg.transferStatus == TransferStatus.pending) ...[
          Text(
            msg.isStream
                ? 'Video available from ${msg.fromName}'
                : 'Accept file from ${msg.fromName}?',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: msg.isStream
                    ? () => _requestStream(msg)
                    : () => _acceptFile(msg),
                icon: Icon(
                  msg.isStream ? Icons.play_circle_outline : Icons.check,
                  size: 16,
                ),
                label: Text(msg.isStream ? 'Stream now' : 'Accept'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _rejectFile(msg),
                icon: const Icon(Icons.close, size: 16),
                label: Text(msg.isStream ? 'Dismiss' : 'Reject'),
              ),
            ],
          ),
        ] else if (isMe &&
            msg.isStream &&
            msg.transferStatus == TransferStatus.pending) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _cancelFile(msg),
                icon: const Icon(Icons.cancel_outlined, size: 16),
                label: const Text('Stop sharing'),
              ),
            ],
          ),
        ] else if (isActive) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: msg.isStream && isMe
                ? [
                    OutlinedButton.icon(
                      onPressed: () => _cancelFile(msg),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Stop sharing'),
                    ),
                  ]
                : [
                    if (msg.isStream)
                      ElevatedButton.icon(
                        onPressed: () => _openVideoStream(msg),
                        icon: const Icon(Icons.play_circle_outline, size: 16),
                        label: Text(
                          _canPlayStream(msg) ? 'Watch' : 'Open Player',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.lightBlueAccent,
                          foregroundColor: Colors.black,
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: msg.transferStatus == TransferStatus.paused
                          ? () => _resumeFile(msg)
                          : () => _pauseFile(msg),
                      icon: Icon(
                        msg.transferStatus == TransferStatus.paused
                            ? Icons.play_arrow
                            : Icons.pause,
                        size: 16,
                      ),
                      label: Text(
                        msg.transferStatus == TransferStatus.paused
                            ? 'Resume'
                            : 'Pause',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _cancelFile(msg),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Cancel'),
                    ),
                  ],
          ),
        ] else if (msg.transferStatus == TransferStatus.saved)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!msg.isStreamOnly)
                ElevatedButton.icon(
                  onPressed: msg.localPath != null
                      ? () => _showSavedPath(msg)
                      : null,
                  icon: Icon(
                    msg.isStream
                        ? Icons.movie_creation_outlined
                        : Icons.download_done,
                    size: 16,
                  ),
                  label: Text(msg.isStream ? 'Video Saved' : 'Saved'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black26,
                    foregroundColor: Colors.white,
                  ),
                ),
              OutlinedButton.icon(
                onPressed: msg.localPath != null
                    ? () =>
                          msg.isStream ? _openVideoStream(msg) : _openFile(msg)
                    : null,
                icon: Icon(
                  msg.isStream ? Icons.play_arrow : Icons.open_in_new,
                  size: 16,
                ),
                label: Text(msg.isStream ? 'Play Video' : 'Open'),
              ),
            ],
          ),
        const SizedBox(height: 4),
        Text(
          _formatTime(msg.timestamp),
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
      ],
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: const Color(0xFF0C1622),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.messaging.hasActiveTransfersForConversation(
              widget.kind,
              widget.conversationId,
            )) ...[
              const BatteryOptimizationBanner(
                reason: BatteryOptimizationPromptReason.activeTransfer,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (_showFileButton)
                  IconButton(
                    tooltip: 'Attach file',
                    icon: const Icon(
                      Icons.attach_file,
                      color: Colors.lightBlueAccent,
                    ),
                    onPressed: _canTransferFiles && !_isPickingFile
                        ? _sendFile
                        : null,
                  ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: _canChat,
                    decoration: InputDecoration(
                      hintText: _canChat
                          ? 'Type a message...'
                          : 'Connect to chat...',
                      filled: true,
                      fillColor: Colors.grey.shade900,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: _canChat
                      ? Colors.lightBlueAccent
                      : Colors.grey.shade700,
                  child: _isSendingText
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            Icons.send,
                            color: _canChat ? Colors.black : Colors.white38,
                          ),
                          onPressed: _canChat ? _sendMessage : null,
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fileStatusText(ChatMessage msg) {
    final percent = (msg.transferProgress.clamp(0, 1) * 100).toStringAsFixed(0);
    final speed = msg.transferSpeedBytesPerSecond > 0
        ? ' • ${_formatBytes(msg.transferSpeedBytesPerSecond.round())}/s'
        : '';
    final noun = msg.isStream ? 'stream' : 'transfer';

    switch (msg.transferStatus) {
      case TransferStatus.pending:
        if (msg.isStream) {
          if (msg.isStreamOnly) {
            return msg.isMe ? 'Ready for receiver playback' : 'Ready to stream';
          }
          return msg.isMe
              ? 'Ready to stream and send'
              : 'Ready to stream and save';
        }
        return msg.isMe ? 'Waiting for receiver...' : 'Waiting for you';
      case TransferStatus.sending:
        return msg.isStream
            ? 'Streaming to receiver... $percent%$speed'
            : 'Sending... $percent%$speed';
      case TransferStatus.paused:
        return 'Paused at $percent%';
      case TransferStatus.sent:
        return msg.isStream ? 'Stream finished' : 'Sent';
      case TransferStatus.receiving:
        if (msg.isStream) {
          return _canPlayStream(msg)
              ? 'Playing while buffering... $percent%$speed'
              : 'Buffering... $percent%$speed';
        }
        return 'Downloading... $percent%$speed';
      case TransferStatus.saved:
        if (msg.isStreamOnly) return 'Stream complete';
        return msg.isStream ? 'Video saved locally' : 'Saved locally';
      case TransferStatus.canceled:
        return msg.error ?? '$noun canceled';
      case TransferStatus.rejected:
        return msg.error ??
            (msg.isStream ? 'Stream rejected' : 'File rejected');
      case TransferStatus.failed:
        return msg.error ?? '$noun failed';
      case TransferStatus.none:
        return msg.isMe
            ? (msg.isStream ? 'Ready to share' : 'Ready to send')
            : (msg.isStream ? 'Ready to stream' : 'Ready to download');
    }
  }

  bool _canPlayStream(ChatMessage msg) {
    if (!msg.isStream || msg.isMe || msg.localPath == null) return false;
    if (msg.transferStatus == TransferStatus.saved) return true;
    final fileSize = msg.fileSize ?? 0;
    if (fileSize <= 0) return msg.transferProgress > 0;
    final bufferedBytes = (fileSize * msg.transferProgress).floor();
    final onePercentBytes = max(
      1,
      (fileSize * _streamStartupBufferFraction).ceil(),
    );
    final requiredBytes = min(
      fileSize,
      min(_streamStartupBufferBytes, onePercentBytes),
    );
    return bufferedBytes >= requiredBytes;
  }
}

class CanvasScreen extends StatefulWidget {
  final ConversationKind conversationKind;
  final String conversationId;
  final String title;
  final MessagingService messaging;
  final String myId;
  final String myName;
  final String? peerIp;
  final ChatPreferencesRepository chatPreferences;

  const CanvasScreen({
    super.key,
    required this.conversationKind,
    required this.conversationId,
    required this.title,
    required this.messaging,
    required this.myId,
    required this.myName,
    required this.chatPreferences,
    this.peerIp,
  });

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  static const double _minCanvasScale = 0.25;
  static const double _maxCanvasScale = 6;

  final GlobalKey _boundaryKey = GlobalKey();
  final Map<int, Offset> _canvasPointers = {};

  List<CanvasEvent> _events = const [];
  final List<Offset> _activePoints = [];
  Color _currentColor = Colors.lightBlueAccent;
  double _brushSize = 4;
  bool _isEraser = false;
  Offset _canvasOffset = Offset.zero;
  double _canvasScale = 1;
  int? _drawingPointer;
  bool _transformGestureActive = false;
  Offset _gestureStartFocal = Offset.zero;
  Offset _gestureStartOffset = Offset.zero;
  double _gestureStartSpan = 1;
  double _gestureStartScale = 1;

  @override
  void initState() {
    super.initState();
    _reloadEvents();
    widget.messaging.addListener(_handleMessagingChanged);
  }

  @override
  void dispose() {
    widget.messaging.removeListener(_handleMessagingChanged);
    super.dispose();
  }

  void _handleMessagingChanged() {
    if (!mounted) return;
    setState(_reloadEvents);
  }

  void _reloadEvents() {
    switch (widget.conversationKind) {
      case ConversationKind.peer:
        _events = widget.messaging.getPeerCanvasHistory(widget.conversationId);
      case ConversationKind.group:
        _events = widget.messaging.getGroupCanvasHistory(widget.conversationId);
    }
  }

  List<CanvasStroke> get _strokes {
    final strokes = <CanvasStroke>[];
    for (final event in _events) {
      if (event.type == 'clear') {
        strokes.clear();
      } else if (event.stroke != null) {
        strokes.add(event.stroke!);
      }
    }
    return strokes;
  }

  Future<bool> _canvasAllowed() async {
    final allowed = await widget.chatPreferences.allowCanvasDrawing(
      widget.conversationKind,
      widget.conversationId,
    );
    if (!mounted || allowed) return allowed;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Canvas drawing is disabled for this chat.'),
      ),
    );
    return false;
  }

  Future<void> _commitStroke() async {
    if (_activePoints.isEmpty) return;
    if (!await _canvasAllowed()) {
      _activePoints.clear();
      if (mounted) setState(() {});
      return;
    }
    if (_activePoints.length == 1) {
      _activePoints.add(_activePoints.first);
    }

    final stroke = CanvasStroke(
      strokeId:
          '${widget.myId}-${DateTime.now().microsecondsSinceEpoch}-${_activePoints.length}',
      fromId: widget.myId,
      fromName: widget.myName,
      timestamp: DateTime.now(),
      colorValue: _currentColor.toARGB32(),
      size: _brushSize,
      isEraser: _isEraser,
      points: _activePoints
          .map((point) => CanvasPoint(x: point.dx, y: point.dy))
          .toList(growable: false),
    );

    bool success;
    switch (widget.conversationKind) {
      case ConversationKind.peer:
        success = await widget.messaging.sendPeerCanvasStroke(
          peerIp: widget.peerIp,
          peerId: widget.conversationId,
          stroke: stroke,
        );
      case ConversationKind.group:
        success = await widget.messaging.sendGroupCanvasStroke(
          groupId: widget.conversationId,
          stroke: stroke,
        );
    }

    if (!mounted) return;
    _activePoints.clear();
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sync the stroke.')),
      );
      setState(() {});
      return;
    }
    setState(() {});
  }

  Future<void> _clearCanvas() async {
    if (!await _canvasAllowed()) return;

    bool success;
    switch (widget.conversationKind) {
      case ConversationKind.peer:
        success = await widget.messaging.clearPeerCanvas(
          peerIp: widget.peerIp,
          peerId: widget.conversationId,
        );
      case ConversationKind.group:
        success = await widget.messaging.clearGroupCanvas(
          groupId: widget.conversationId,
        );
    }

    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not clear the shared canvas.')),
      );
    }
  }

  Future<void> _saveAndSendCanvas() async {
    if (!await _canvasAllowed()) return;

    if (_activePoints.isNotEmpty) {
      await _commitStroke();
    }

    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;

    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return;

    final fileName =
        'canvas-${DateTime.now().millisecondsSinceEpoch.toString()}.png';
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );

    bool success;
    switch (widget.conversationKind) {
      case ConversationKind.peer:
        success = await widget.messaging.sendFile(
          peerIp: widget.peerIp,
          peerId: widget.conversationId,
          filePath: file.path,
          fileName: fileName,
        );
      case ConversationKind.group:
        success = await widget.messaging.sendGroupFile(
          groupId: widget.conversationId,
          filePath: file.path,
          fileName: fileName,
        );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Canvas sent as an image.'
              : 'Failed to send the canvas image.',
        ),
      ),
    );
  }

  Offset _toCanvasPoint(Offset viewportPoint) {
    return (viewportPoint - _canvasOffset) / _canvasScale;
  }

  Offset _focalPoint(Iterable<Offset> points) {
    final list = points.toList(growable: false);
    if (list.isEmpty) return Offset.zero;
    final total = list.fold<Offset>(Offset.zero, (sum, point) => sum + point);
    return total / list.length.toDouble();
  }

  double _averageSpan(Iterable<Offset> points, Offset focalPoint) {
    final list = points.toList(growable: false);
    if (list.length < 2) return 1;
    final total = list.fold<double>(
      0,
      (sum, point) => sum + (point - focalPoint).distance,
    );
    return max(1, total / list.length);
  }

  void _startTransformGesture() {
    _transformGestureActive = true;
    _drawingPointer = null;
    _gestureStartFocal = _focalPoint(_canvasPointers.values);
    _gestureStartSpan = _averageSpan(
      _canvasPointers.values,
      _gestureStartFocal,
    );
    _gestureStartOffset = _canvasOffset;
    _gestureStartScale = _canvasScale;
  }

  void _zoomCanvasAt(Offset viewportPoint, double factor) {
    final nextScale = (_canvasScale * factor).clamp(
      _minCanvasScale,
      _maxCanvasScale,
    );
    if (nextScale == _canvasScale) return;
    final canvasPoint = _toCanvasPoint(viewportPoint);
    setState(() {
      _canvasScale = nextScale;
      _canvasOffset = viewportPoint - canvasPoint * _canvasScale;
    });
  }

  void _handleCanvasPointerDown(PointerDownEvent event) {
    _canvasPointers[event.pointer] = event.localPosition;
    if (_canvasPointers.length == 1 && !_transformGestureActive) {
      _drawingPointer = event.pointer;
      setState(() {
        _activePoints
          ..clear()
          ..add(_toCanvasPoint(event.localPosition));
      });
      return;
    }

    if (_activePoints.isNotEmpty) {
      unawaited(_commitStroke());
    }
    _startTransformGesture();
  }

  void _handleCanvasPointerMove(PointerMoveEvent event) {
    if (!_canvasPointers.containsKey(event.pointer)) return;
    _canvasPointers[event.pointer] = event.localPosition;

    if (_canvasPointers.length >= 2) {
      final focalPoint = _focalPoint(_canvasPointers.values);
      final span = _averageSpan(_canvasPointers.values, focalPoint);
      final nextScale = (_gestureStartScale * (span / _gestureStartSpan)).clamp(
        _minCanvasScale,
        _maxCanvasScale,
      );
      final focalCanvasPoint =
          (_gestureStartFocal - _gestureStartOffset) / _gestureStartScale;
      setState(() {
        _canvasScale = nextScale;
        _canvasOffset = focalPoint - focalCanvasPoint * _canvasScale;
      });
      return;
    }

    if (!_transformGestureActive && event.pointer == _drawingPointer) {
      setState(() => _activePoints.add(_toCanvasPoint(event.localPosition)));
    }
  }

  void _handleCanvasPointerUp(PointerEvent event) {
    _canvasPointers.remove(event.pointer);
    if (event.pointer == _drawingPointer) {
      _drawingPointer = null;
      if (_canvasPointers.isEmpty) {
        unawaited(_commitStroke());
      }
    }

    if (_canvasPointers.length >= 2) {
      _startTransformGesture();
    } else if (_canvasPointers.isEmpty) {
      _transformGestureActive = false;
    }
  }

  void _handleCanvasPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final pressedKeys = HardwareKeyboard.instance.logicalKeysPressed;
    final isControlPressed =
        pressedKeys.contains(LogicalKeyboardKey.controlLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.controlRight) ||
        pressedKeys.contains(LogicalKeyboardKey.metaLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.metaRight);

    if (isControlPressed) {
      final factor = exp(-event.scrollDelta.dy / 500);
      _zoomCanvasAt(event.localPosition, factor);
      return;
    }

    setState(() {
      _canvasOffset -= event.scrollDelta;
    });
  }

  void _handleCanvasPanZoomStart(PointerPanZoomStartEvent event) {
    _canvasPointers.clear();
    _drawingPointer = null;
    if (_activePoints.isNotEmpty) {
      unawaited(_commitStroke());
    }
    _transformGestureActive = true;
    _gestureStartFocal = event.localPosition;
    _gestureStartOffset = _canvasOffset;
    _gestureStartScale = _canvasScale;
  }

  void _handleCanvasPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final focalPoint = event.localPosition + event.localPan;
    final nextScale = (_gestureStartScale * event.scale).clamp(
      _minCanvasScale,
      _maxCanvasScale,
    );
    final focalCanvasPoint =
        (_gestureStartFocal - _gestureStartOffset) / _gestureStartScale;
    setState(() {
      _canvasScale = nextScale;
      _canvasOffset = focalPoint - focalCanvasPoint * _canvasScale;
    });
  }

  void _handleCanvasPanZoomEnd(PointerPanZoomEndEvent event) {
    _transformGestureActive = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.title} Canvas'),
        actions: [
          _topIconButton(
            context: context,
            tooltip: 'Clear canvas',
            onPressed: _clearCanvas,
            icon: const Icon(Icons.layers_clear_outlined),
          ),
          _topIconButton(
            context: context,
            tooltip: 'Save & send',
            onPressed: _saveAndSendCanvas,
            icon: const Icon(Icons.image_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: Container(
                    color: const Color(0xFF030609),
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _handleCanvasPointerDown,
                      onPointerMove: _handleCanvasPointerMove,
                      onPointerUp: _handleCanvasPointerUp,
                      onPointerCancel: _handleCanvasPointerUp,
                      onPointerSignal: _handleCanvasPointerSignal,
                      onPointerPanZoomStart: _handleCanvasPanZoomStart,
                      onPointerPanZoomUpdate: _handleCanvasPanZoomUpdate,
                      onPointerPanZoomEnd: _handleCanvasPanZoomEnd,
                      child: CustomPaint(
                        painter: _CanvasPainter(
                          strokes: _strokes,
                          activePoints: List<Offset>.from(_activePoints),
                          activeColor: _currentColor,
                          activeSize: _brushSize,
                          activeEraser: _isEraser,
                          backgroundColor: const Color(0xFF030609),
                          canvasOffset: _canvasOffset,
                          canvasScale: _canvasScale,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _buildCanvasControls(),
        ],
      ),
    );
  }

  Widget _buildCanvasControls() {
    final colors = <Color>[
      Colors.lightBlueAccent,
      Colors.white,
      Colors.greenAccent,
      Colors.orangeAccent,
      Colors.pinkAccent,
      Colors.amber,
    ];

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: const BoxDecoration(
          color: Color(0xFF0C1622),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilterChip(
                  selected: !_isEraser,
                  onSelected: (_) => setState(() => _isEraser = false),
                  label: const Text('Brush'),
                ),
                const SizedBox(width: 10),
                FilterChip(
                  selected: _isEraser,
                  onSelected: (_) => setState(() => _isEraser = true),
                  label: const Text('Eraser'),
                ),
                const Spacer(),
                Text(
                  '${_brushSize.toStringAsFixed(1)} px',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: colors
                  .map((color) {
                    final selected =
                        _currentColor.toARGB32() == color.toARGB32() &&
                        !_isEraser;
                    return GestureDetector(
                      onTap: () => setState(() {
                        _currentColor = color;
                        _isEraser = false;
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: selected ? 36 : 30,
                        height: selected ? 36 : 30,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
            const SizedBox(height: 12),
            Slider(
              value: _brushSize,
              min: 1,
              max: 18,
              label: _brushSize.toStringAsFixed(1),
              onChanged: (value) => setState(() => _brushSize = value),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final MessagingService messaging;
  final String myName;
  final String myId;
  final bool rememberName;
  final bool onlineMode;
  final bool onlyInitiatedConnections;
  final ChatPreferencesRepository chatPreferences;
  final Future<void> Function({
    required String name,
    required bool rememberName,
  })
  onProfileChanged;
  final Future<void> Function(bool value) onOnlineModeChanged;
  final Future<void> Function(bool value) onOnlyInitiatedConnectionsChanged;

  const SettingsScreen({
    super.key,
    required this.messaging,
    required this.myName,
    required this.myId,
    required this.rememberName,
    required this.onlineMode,
    required this.onlyInitiatedConnections,
    required this.chatPreferences,
    required this.onProfileChanged,
    required this.onOnlineModeChanged,
    required this.onOnlyInitiatedConnectionsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController;
  late bool _rememberName;
  late bool _onlineMode;
  late bool _onlyInitiatedConnections;
  ChatFeatureSettings _globalDefaults = ChatFeatureSettings.defaults;
  bool _globalDefaultsLoaded = false;
  bool _isSavingProfile = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.myName);
    _rememberName = widget.rememberName;
    _onlineMode = widget.onlineMode;
    _onlyInitiatedConnections = widget.onlyInitiatedConnections;
    unawaited(_loadGlobalDefaults());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _toggleOnlineMode(bool value) async {
    await widget.onOnlineModeChanged(value);
    if (!mounted) return;
    setState(() => _onlineMode = value);
  }

  Future<void> _toggleOnlyInitiatedConnections(bool value) async {
    await widget.onOnlyInitiatedConnectionsChanged(value);
    if (!mounted) return;
    setState(() => _onlyInitiatedConnections = value);
  }

  Future<void> _loadGlobalDefaults() async {
    final settings = await widget.chatPreferences.loadGlobalDefaults();
    if (!mounted) return;
    setState(() {
      _globalDefaults = settings;
      _globalDefaultsLoaded = true;
    });
  }

  Future<void> _saveGlobalDefaults(ChatFeatureSettings settings) async {
    setState(() => _globalDefaults = settings);
    await widget.chatPreferences.saveGlobalDefaults(settings);
    if (!mounted) return;
    setState(() => _globalDefaults = settings);
  }

  Future<void> _saveProfile({bool showSnack = true}) async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _isSavingProfile) return;
    setState(() => _isSavingProfile = true);
    await widget.onProfileChanged(name: name, rememberName: _rememberName);
    if (!mounted) return;
    setState(() => _isSavingProfile = false);
    if (showSnack) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    }
  }

  void _openAboutPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AboutShareViaLanScreen()),
    );
  }

  Widget _buildProfileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Profile',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _saveProfile(),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _rememberName,
              onChanged: (value) {
                setState(() => _rememberName = value);
                unawaited(_saveProfile(showSnack: false));
              },
              title: const Text('Remember username'),
              subtitle: const Text(
                'Turn this off to show the name screen on next launch.',
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSavingProfile ? null : _saveProfile,
                icon: _isSavingProfile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Save Profile'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalDefaultsCard() {
    final settings = _globalDefaults;
    return Card(
      child: Column(
        children: [
          const ListTile(
            title: Text(
              'Global Feature Toggles',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('Disabled features disappear from every chat.'),
          ),
          const Divider(height: 1),
          SwitchListTile(
            value: settings.allowFileReceiving,
            onChanged: !_globalDefaultsLoaded
                ? null
                : (value) => unawaited(
                    _saveGlobalDefaults(
                      settings.copyWith(allowFileReceiving: value),
                    ),
                  ),
            title: const Text('File Receive'),
            subtitle: const Text('Shows file send and receive controls.'),
          ),
          SwitchListTile(
            value: settings.allowCanvasDrawing,
            onChanged: !_globalDefaultsLoaded
                ? null
                : (value) => unawaited(
                    _saveGlobalDefaults(
                      settings.copyWith(allowCanvasDrawing: value),
                    ),
                  ),
            title: const Text('Canvas'),
            subtitle: const Text('Shows the shared canvas button.'),
          ),
          SwitchListTile(
            value: settings.allowMessageNotifications,
            onChanged: !_globalDefaultsLoaded
                ? null
                : (value) => unawaited(
                    _saveGlobalDefaults(
                      settings.copyWith(allowMessageNotifications: value),
                    ),
                  ),
            title: const Text('Message Notifications'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildProfileCard(),
            const SizedBox(height: 16),
            _buildGlobalDefaultsCard(),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _onlineMode,
                    onChanged: _toggleOnlineMode,
                    title: const Text('Online / Offline'),
                    subtitle: Text(
                      _onlineMode
                          ? 'Discovery is broadcasting and ShareViaLAN accepts new connections.'
                          : 'Discovery is paused. Approved peers and groups still work.',
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _onlyInitiatedConnections,
                    onChanged: _toggleOnlyInitiatedConnections,
                    title: const Text('Only I can request connections'),
                    subtitle: const Text(
                      'Reject new incoming permission requests unless you started the request first.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About ShareViaLAN'),
                subtitle: const Text('Desktop downloads and setup steps.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openAboutPage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AboutShareViaLanScreen extends StatelessWidget {
  const AboutShareViaLanScreen({super.key});

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!context.mounted || opened) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied to clipboard.')));
  }

  Widget _sectionCard({
    required String title,
    required List<Widget> children,
    IconData? icon,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.lightBlueAccent),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _downloadCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String text,
    required String buttonLabel,
    required String url,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.lightBlueAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(text, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_openLink(context, url)),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(buttonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Colors.lightBlueAccent,
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About ShareViaLAN')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionCard(
              title: 'What is ShareViaLAN?',
              icon: Icons.lan_outlined,
              children: const [
                Text(
                  'ShareViaLAN lets you send files, messages, and media between devices on the same local network without internet.',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _sectionCard(
              title: 'How to connect phone and PC',
              icon: Icons.devices_outlined,
              children: [
                const Text(
                  'Install ShareViaLAN on your Windows or Linux computer, keep both devices on the same Wi-Fi/LAN, and they will be able to discover each other.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                _step('1', 'Install ShareViaLAN on your phone.'),
                _step('2', 'Install ShareViaLAN on your Windows/Linux PC.'),
                _step('3', 'Connect both devices to the same Wi-Fi or LAN.'),
                _step('4', 'Open the app on both devices.'),
                _step('5', 'Select the device and start sending files.'),
              ],
            ),
            const SizedBox(height: 16),
            _sectionCard(
              title: 'Download for Desktop',
              icon: Icons.download_outlined,
              children: [
                _downloadCard(
                  context: context,
                  icon: Icons.desktop_windows_outlined,
                  title: 'Windows',
                  text: 'Download the Windows EXE from GitHub Releases.',
                  buttonLabel: 'Open Windows Download Page',
                  url: _shareViaLanReleasesUrl,
                ),
                const SizedBox(height: 12),
                _downloadCard(
                  context: context,
                  icon: Icons.computer_outlined,
                  title: 'Linux',
                  text:
                      'Download the Linux files and follow the installation steps from GitHub.',
                  buttonLabel: 'Open Linux Download Page',
                  url: _shareViaLanGitHubUrl,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: const Text('GitHub / Releases'),
                    subtitle: const Text(_shareViaLanGitHubUrl),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () =>
                        unawaited(_openLink(context, _shareViaLanGitHubUrl)),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('App version'),
                    subtitle: Text(_appVersionLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final List<CanvasStroke> strokes;
  final List<Offset> activePoints;
  final Color activeColor;
  final double activeSize;
  final bool activeEraser;
  final Color backgroundColor;
  final Offset canvasOffset;
  final double canvasScale;

  const _CanvasPainter({
    required this.strokes,
    required this.activePoints,
    required this.activeColor,
    required this.activeSize,
    required this.activeEraser,
    required this.backgroundColor,
    required this.canvasOffset,
    required this.canvasScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = backgroundColor;
    canvas.drawRect(Offset.zero & size, backgroundPaint);
    canvas.save();
    canvas.translate(canvasOffset.dx, canvasOffset.dy);
    canvas.scale(canvasScale);

    for (final stroke in strokes) {
      _drawStroke(
        canvas,
        stroke.points.map((point) => Offset(point.x, point.y)).toList(),
        stroke.isEraser ? backgroundColor : Color(stroke.colorValue),
        stroke.size,
      );
    }

    if (activePoints.isNotEmpty) {
      _drawStroke(
        canvas,
        activePoints,
        activeEraser ? backgroundColor : activeColor,
        activeSize,
      );
    }
    canvas.restore();
  }

  void _drawStroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
  ) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.activePoints != activePoints ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.activeSize != activeSize ||
        oldDelegate.activeEraser != activeEraser ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.canvasOffset != canvasOffset ||
        oldDelegate.canvasScale != canvasScale;
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? details;
  final Widget? footer;

  const _StatusCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.details,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.18),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (details != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          details!,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  final String command;

  const _CommandBlock({required this.command});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        command,
        style: const TextStyle(
          fontFamily: 'monospace',
          color: Colors.white,
          height: 1.45,
        ),
      ),
    );
  }
}

enum _VideoSendAction { sendFile, streamVideo, streamAndSend }

extension _VideoSendActionMode on _VideoSendAction {
  StreamTransferMode get streamMode {
    return switch (this) {
      _VideoSendAction.sendFile => StreamTransferMode.streamAndSend,
      _VideoSendAction.streamVideo => StreamTransferMode.streamOnly,
      _VideoSendAction.streamAndSend => StreamTransferMode.streamAndSend,
    };
  }
}

enum _IncomingFileAcceptChoice { thisFile, allFromSender }

enum _PeerTileAction { open }

bool _isVideoFileName(String fileName) {
  final lower = fileName.toLowerCase();
  const extensions = [
    '.mp4',
    '.m4v',
    '.mov',
    '.mkv',
    '.webm',
    '.avi',
    '.wmv',
    '.flv',
    '.3gp',
  ];
  return extensions.any(lower.endsWith);
}

String _formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final precision = unitIndex == 0 || value >= 10 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _formatRelativeAge(DateTime dt) {
  final elapsed = DateTime.now().difference(dt);
  if (elapsed.inSeconds < 5) return 'now';
  if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}s ago';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  return '${elapsed.inHours}h ago';
}

class _DeviceUnset {
  const _DeviceUnset();
}
