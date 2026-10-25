import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'chat_history_store.dart';
import 'file_names.dart';
import 'lan_platform_channel.dart';
import 'lan_protocol.dart';

const int messagingPort = 9002;

const int _socketTimeoutSeconds = 8;
const int _permissionTimeoutSeconds = 45;
const int _headerLimitBytes = 1024 * 1024;
const int _fileChunkBytes = 128 * 1024;
const int _streamChunkBytes = 256 * 1024;
const int _streamStartupMetadataBytes = 4 * 1024 * 1024;
const int _streamAckWindowChunks = 2;
const int _streamServerReadChunkBytes = 64 * 1024;
const int _progressIntervalMs = 250;
const Duration _fileAcceptTimeout = Duration(seconds: 60);
const Duration _bulkFileAcceptDuration = Duration(minutes: 10);
const Duration _fileAckTimeout = Duration(seconds: 75);
const Duration _streamReceiverJoinDelay = Duration(milliseconds: 250);
const Duration _streamSinkFlushInterval = Duration(milliseconds: 350);
const Duration _streamServerWaitInterval = Duration(milliseconds: 250);
const Duration _streamServerCompleteGrace = Duration(hours: 2);
const Duration _directDisconnectFlushTimeout = Duration(milliseconds: 150);
const Duration _directMaintenanceInterval = Duration(seconds: 4);
const Duration _directPeerStaleDuration = Duration(seconds: 90);
const Duration _peerForgetDuration = Duration(minutes: 5);
const Duration _seenMessageCacheDuration = Duration(minutes: 10);
const Duration _aliveProbeTimeout = Duration(seconds: 2);
const Duration _sendFlushTimeout = Duration(seconds: 6);
const Duration _sendRetryDelay = Duration(milliseconds: 250);
const int _packetSendAttempts = 3;
const _unset = _Unset();

const String _protocolChatMessage = 'CHAT_MESSAGE';
const String _protocolFileOffer = 'FILE_OFFER';
const String _protocolFileChunk = 'FILE_CHUNK';
const String _protocolFileAck = 'FILE_ACK';
const String _protocolStreamOffer = 'STREAM_OFFER';
const String _protocolStreamChunk = 'STREAM_CHUNK';
const String _protocolStreamAck = 'STREAM_ACK';

typedef MessageHandler = void Function(ChatMessage message);
typedef IncomingMessageHandler = void Function(ChatMessage message);
typedef IncomingTransferOfferHandler = void Function(ChatMessage message);
typedef PermissionRequestHandler = Future<bool> Function(
  PermissionRequest request,
);
typedef GroupJoinRequestHandler = Future<bool> Function(
  GroupJoinRequest request,
);
typedef CanvasEventHandler = void Function(CanvasEvent event);
typedef ChatFeatureGuard = Future<bool> Function(
  ConversationKind kind,
  String conversationId,
);

enum PeerPermissionState {
  none,
  requesting,
  incoming,
  granted,
  denied,
}

enum TransferStatus {
  none,
  pending,
  sending,
  paused,
  sent,
  receiving,
  saved,
  canceled,
  rejected,
  failed,
}

enum StreamTransferMode {
  streamOnly,
  streamAndSend,
}

enum ConversationKind {
  peer,
  group,
}

enum PeerRouteStatus {
  directOnline,
  stale,
  offline,
}

class PermissionRequest {
  final String peerId;
  final String peerName;
  final String peerIp;
  final DateTime timestamp;

  const PermissionRequest({
    required this.peerId,
    required this.peerName,
    required this.peerIp,
    required this.timestamp,
  });
}

class GroupJoinRequest {
  final String groupId;
  final String groupName;
  final String groupCode;
  final String requesterId;
  final String requesterName;
  final DateTime timestamp;

  const GroupJoinRequest({
    required this.groupId,
    required this.groupName,
    required this.groupCode,
    required this.requesterId,
    required this.requesterName,
    required this.timestamp,
  });
}

class ChatMessage {
  final String messageId;
  final String conversationId;
  final ConversationKind conversationKind;
  final String text;
  final String fromName;
  final String fromId;
  final DateTime timestamp;
  final bool isMe;
  final bool isFile;
  final bool isStream;
  final bool streamSavesFile;
  final bool isSystem;
  final String? viaPeerName;
  final String? transferId;
  final String? fileName;
  final String? localPath;
  final int? fileSize;
  final TransferStatus transferStatus;
  final double transferProgress;
  final double transferSpeedBytesPerSecond;
  final String? error;

  const ChatMessage({
    required this.messageId,
    required this.conversationId,
    required this.conversationKind,
    required this.text,
    required this.fromName,
    required this.fromId,
    required this.timestamp,
    required this.isMe,
    this.isFile = false,
    this.isStream = false,
    this.streamSavesFile = true,
    this.isSystem = false,
    this.viaPeerName,
    this.transferId,
    this.fileName,
    this.localPath,
    this.fileSize,
    this.transferStatus = TransferStatus.none,
    this.transferProgress = 0,
    this.transferSpeedBytesPerSecond = 0,
    this.error,
  });

  bool get isTransferActive =>
      transferStatus == TransferStatus.sending ||
      transferStatus == TransferStatus.paused ||
      transferStatus == TransferStatus.receiving;

  bool get isStreamOnly => isStream && !streamSavesFile;

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'conversationId': conversationId,
        'conversationKind': conversationKind.name,
        'text': text,
        'fromName': fromName,
        'fromId': fromId,
        'timestamp': timestamp.toIso8601String(),
        'isMe': isMe,
        'isFile': isFile,
        'isStream': isStream,
        'streamSavesFile': streamSavesFile,
        'isSystem': isSystem,
        if (viaPeerName != null) 'viaPeerName': viaPeerName,
        if (transferId != null) 'transferId': transferId,
        if (fileName != null) 'fileName': fileName,
        if (localPath != null) 'localPath': localPath,
        if (fileSize != null) 'fileSize': fileSize,
        'transferStatus': transferStatus.name,
        'transferProgress': transferProgress,
        'transferSpeedBytesPerSecond': transferSpeedBytesPerSecond,
        if (error != null) 'error': error,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      messageId: (json['messageId'] ?? '').toString(),
      conversationId: (json['conversationId'] ?? '').toString(),
      conversationKind: _conversationKindFromName(
          (json['conversationKind'] ?? '').toString()),
      text: (json['text'] ?? '').toString(),
      fromName: (json['fromName'] ?? '').toString(),
      fromId: (json['fromId'] ?? '').toString(),
      timestamp: MessagingService._parseStaticTimestamp(json['timestamp']),
      isMe: json['isMe'] == true,
      isFile: json['isFile'] == true,
      isStream: json['isStream'] == true,
      streamSavesFile: json['streamSavesFile'] != false,
      isSystem: json['isSystem'] == true,
      viaPeerName: json['viaPeerName']?.toString(),
      transferId: json['transferId']?.toString(),
      fileName: json['fileName']?.toString(),
      localPath: json['localPath']?.toString(),
      fileSize: json['fileSize'] == null ? null : _intFrom(json['fileSize']),
      transferStatus:
          _transferStatusFromName((json['transferStatus'] ?? '').toString()),
      transferProgress: _doubleFrom(json['transferProgress']),
      transferSpeedBytesPerSecond:
          _doubleFrom(json['transferSpeedBytesPerSecond']),
      error: json['error']?.toString(),
    );
  }

  ChatMessage copyWith({
    String? messageId,
    String? conversationId,
    ConversationKind? conversationKind,
    String? text,
    String? fromName,
    String? fromId,
    DateTime? timestamp,
    bool? isMe,
    bool? isFile,
    bool? isStream,
    bool? streamSavesFile,
    bool? isSystem,
    Object? viaPeerName = _unset,
    Object? transferId = _unset,
    Object? fileName = _unset,
    Object? localPath = _unset,
    Object? fileSize = _unset,
    TransferStatus? transferStatus,
    double? transferProgress,
    double? transferSpeedBytesPerSecond,
    Object? error = _unset,
  }) {
    return ChatMessage(
      messageId: messageId ?? this.messageId,
      conversationId: conversationId ?? this.conversationId,
      conversationKind: conversationKind ?? this.conversationKind,
      text: text ?? this.text,
      fromName: fromName ?? this.fromName,
      fromId: fromId ?? this.fromId,
      timestamp: timestamp ?? this.timestamp,
      isMe: isMe ?? this.isMe,
      isFile: isFile ?? this.isFile,
      isStream: isStream ?? this.isStream,
      streamSavesFile: streamSavesFile ?? this.streamSavesFile,
      isSystem: isSystem ?? this.isSystem,
      viaPeerName: identical(viaPeerName, _unset)
          ? this.viaPeerName
          : viaPeerName as String?,
      transferId: identical(transferId, _unset)
          ? this.transferId
          : transferId as String?,
      fileName:
          identical(fileName, _unset) ? this.fileName : fileName as String?,
      localPath:
          identical(localPath, _unset) ? this.localPath : localPath as String?,
      fileSize: identical(fileSize, _unset) ? this.fileSize : fileSize as int?,
      transferStatus: transferStatus ?? this.transferStatus,
      transferProgress: transferProgress ?? this.transferProgress,
      transferSpeedBytesPerSecond:
          transferSpeedBytesPerSecond ?? this.transferSpeedBytesPerSecond,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }
}

class PeerSummary {
  final String peerId;
  final String name;
  final String ip;
  final bool isApproved;
  final bool isReachable;
  final bool isDirect;
  final bool isOnline;
  final int hopCount;
  final String? nextHopId;
  final String? viaPeerId;
  final String? viaPeerName;
  final DateTime lastSeen;
  final PeerRouteStatus routeStatus;

  const PeerSummary({
    required this.peerId,
    required this.name,
    required this.ip,
    required this.isApproved,
    required this.isReachable,
    required this.isDirect,
    required this.isOnline,
    required this.hopCount,
    required this.lastSeen,
    required this.routeStatus,
    this.nextHopId,
    this.viaPeerId,
    this.viaPeerName,
  });
}

class ConnectionDiagnostics {
  final bool serverListening;
  final int directPeerCount;
  final int knownPeerCount;
  final DateTime? lastDirectPeerSeenAt;
  final String? lastDirectPeerId;
  final String? lastDirectPeerName;
  final String? lastTransportError;

  const ConnectionDiagnostics({
    required this.serverListening,
    required this.directPeerCount,
    required this.knownPeerCount,
    this.lastDirectPeerSeenAt,
    this.lastDirectPeerId,
    this.lastDirectPeerName,
    this.lastTransportError,
  });
}

class GroupMember {
  final String peerId;
  final String name;
  final bool isOwner;
  final bool isOnline;

  const GroupMember({
    required this.peerId,
    required this.name,
    required this.isOwner,
    required this.isOnline,
  });

  GroupMember copyWith({
    String? peerId,
    String? name,
    bool? isOwner,
    bool? isOnline,
  }) {
    return GroupMember(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      isOwner: isOwner ?? this.isOwner,
      isOnline: isOnline ?? this.isOnline,
    );
  }
}

class GroupRoom {
  final String groupId;
  final String name;
  final String ownerId;
  final String ownerName;
  final String code;
  final String joinSecret;
  final bool isOwner;
  final List<GroupMember> members;
  final DateTime createdAt;

  const GroupRoom({
    required this.groupId,
    required this.name,
    required this.ownerId,
    required this.ownerName,
    required this.code,
    required this.joinSecret,
    required this.isOwner,
    required this.members,
    required this.createdAt,
  });

  GroupRoom copyWith({
    String? groupId,
    String? name,
    String? ownerId,
    String? ownerName,
    String? code,
    String? joinSecret,
    bool? isOwner,
    List<GroupMember>? members,
    DateTime? createdAt,
  }) {
    return GroupRoom(
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      ownerName: ownerName ?? this.ownerName,
      code: code ?? this.code,
      joinSecret: joinSecret ?? this.joinSecret,
      isOwner: isOwner ?? this.isOwner,
      members: members ?? this.members,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class CanvasPoint {
  final double x;
  final double y;

  const CanvasPoint({
    required this.x,
    required this.y,
  });

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
      };

  factory CanvasPoint.fromJson(Map<String, dynamic> json) {
    return CanvasPoint(
      x: _doubleFrom(json['x']),
      y: _doubleFrom(json['y']),
    );
  }
}

class CanvasStroke {
  final String strokeId;
  final String fromId;
  final String fromName;
  final DateTime timestamp;
  final int colorValue;
  final double size;
  final bool isEraser;
  final List<CanvasPoint> points;

  const CanvasStroke({
    required this.strokeId,
    required this.fromId,
    required this.fromName,
    required this.timestamp,
    required this.colorValue,
    required this.size,
    required this.isEraser,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
        'strokeId': strokeId,
        'fromId': fromId,
        'fromName': fromName,
        'timestamp': timestamp.toIso8601String(),
        'colorValue': colorValue,
        'size': size,
        'isEraser': isEraser,
        'points': points.map((point) => point.toJson()).toList(growable: false),
      };

  factory CanvasStroke.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    final points = <CanvasPoint>[];
    if (rawPoints is List) {
      for (final entry in rawPoints) {
        if (entry is Map<String, dynamic>) {
          points.add(CanvasPoint.fromJson(entry));
        } else if (entry is Map) {
          points.add(CanvasPoint.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }

    return CanvasStroke(
      strokeId: (json['strokeId'] ?? '').toString(),
      fromId: (json['fromId'] ?? '').toString(),
      fromName: (json['fromName'] ?? '').toString(),
      timestamp: MessagingService._parseStaticTimestamp(json['timestamp']),
      colorValue: _intFrom(json['colorValue']),
      size: _doubleFrom(json['size']),
      isEraser: json['isEraser'] == true,
      points: points,
    );
  }
}

class CanvasEvent {
  final String eventId;
  final String conversationId;
  final ConversationKind conversationKind;
  final String type;
  final String fromId;
  final String fromName;
  final DateTime timestamp;
  final String? viaPeerName;
  final CanvasStroke? stroke;

  const CanvasEvent({
    required this.eventId,
    required this.conversationId,
    required this.conversationKind,
    required this.type,
    required this.fromId,
    required this.fromName,
    required this.timestamp,
    this.viaPeerName,
    this.stroke,
  });
}

class MessagingService extends ChangeNotifier {
  final String myId;
  String myName;

  ServerSocket? _server;
  Timer? _maintenanceTimer;
  final Map<String, Socket> _connections = {};
  final Map<Socket, _SocketState> _socketStates = {};
  final Map<String, Future<void>> _writeQueues = {};
  final Map<String, MessageHandler> _messageHandlers = {};
  final Map<String, CanvasEventHandler> _canvasHandlers = {};
  final Map<String, List<ChatMessage>> _history = {};
  final Map<String, List<ChatMessage>> _pendingBuffer = {};
  final Map<String, List<CanvasEvent>> _canvasHistory = {};
  final Map<String, List<CanvasEvent>> _pendingCanvas = {};
  final Map<String, String> _peerIps = {};
  final Map<String, int> _peerPorts = {};
  final Map<String, String> _peerNames = {};
  final Map<String, DateTime> _peerLastSeen = {};
  final Map<String, DateTime> _directPeerLastSeen = {};
  final Set<String> _peerRegistryIds = {};
  final Map<String, PeerPermissionState> _permissionStates = {};
  final Map<String, Completer<bool>> _permissionCompleters = {};
  final Map<String, String> _permissionFailureMessages = {};
  final Map<String, Future<bool>> _directVerificationTasks = {};
  final Map<String, _DirectPingProbe> _directPingProbes = {};
  final Map<String, _PendingIncomingTransfer> _pendingIncomingTransfers = {};
  final Map<String, DateTime> _autoAcceptIncomingFilesUntil = {};
  final LinkedHashMap<String, DateTime> _seenMessageCache =
      LinkedHashMap<String, DateTime>();
  final Map<String, _OutgoingTransfer> _outgoingTransfers = {};
  final Map<String, _IncomingTransfer> _incomingTransfers = {};
  final Map<String, _ProgressiveStreamSession> _streamSessions = {};
  final Map<String, GroupRoom> _groups = {};
  final ChatHistoryStore _historyStore = ChatHistoryStore();
  final Set<String> _persistentConversationKeys = <String>{};
  final Map<String, Future<void>> _historySaveTasks = {};

  PermissionRequestHandler? permissionRequestHandler;
  GroupJoinRequestHandler? groupJoinRequestHandler;
  IncomingMessageHandler? incomingMessageHandler;
  IncomingTransferOfferHandler? incomingTransferOfferHandler;
  ChatFeatureGuard? fileReceivingGuard;
  ChatFeatureGuard? canvasDrawingGuard;

  int _messageCounter = 0;
  bool _stopped = false;
  bool _isOnlineMode = true;
  bool _onlyInitiatedConnections = false;
  DateTime? _lastDirectPeerSeenAt;
  String? _lastDirectPeerId;
  String? _lastTransportError;

  MessagingService({
    required this.myId,
    required this.myName,
  }) {
    _peerNames[myId] = myName;
    _peerLastSeen[myId] = DateTime.now();
    unawaited(_loadPersistentChats());
  }

  static Future<void> cleanupOldStreamCache() async {
    if (kIsWeb) return;
    try {
      final tempRoot = await getTemporaryDirectory();
      final receiving = Directory(
        '${tempRoot.path}${Platform.pathSeparator}ShareViaLAN'
        '${Platform.pathSeparator}Receiving',
      );
      if (!await receiving.exists()) return;
      await for (final entity in receiving.list(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path.toLowerCase();
        if (!path.endsWith('.streaming')) continue;
        try {
          await entity.delete();
        } catch (error) {
          debugPrint(
              'Could not delete old stream cache ${entity.path}: $error');
        }
      }
    } catch (error) {
      debugPrint('Old stream cache cleanup failed: $error');
    }
  }

  Future<void> _loadPersistentChats() async {
    try {
      final keys = await _historyStore.loadPersistentKeys();
      _persistentConversationKeys
        ..clear()
        ..addAll(keys);
      for (final key in keys) {
        final rawMessages = await _historyStore.loadMessages(key);
        final messages = _history.putIfAbsent(key, () => <ChatMessage>[]);
        for (final raw in rawMessages) {
          final message = ChatMessage.fromJson(raw);
          if (message.messageId.isNotEmpty) {
            _upsertMessage(messages, message);
          }
        }
      }
      _emitChange();
    } catch (error) {
      debugPrint('Could not load persistent chat history: $error');
    }
  }

  bool isChatPersistent(ConversationKind kind, String conversationId) {
    return _persistentConversationKeys.contains(
      _conversationKey(kind, conversationId),
    );
  }

  bool canChangeChatPersistence(ConversationKind kind, String conversationId) {
    if (kind != ConversationKind.group) return true;
    return _groups[conversationId]?.isOwner ?? false;
  }

  Future<bool> setChatPersistence({
    required ConversationKind kind,
    required String conversationId,
    required bool enabled,
  }) async {
    if (!canChangeChatPersistence(kind, conversationId)) {
      return false;
    }
    await _applyChatPersistence(
      kind: kind,
      conversationId: conversationId,
      enabled: enabled,
      clearWhenDisabled: true,
    );
    await _sendChatPersistenceUpdate(
      kind: kind,
      conversationId: conversationId,
      enabled: enabled,
    );
    return true;
  }

  bool get isOnlineMode => _isOnlineMode;

  bool get onlyInitiatedConnections => _onlyInitiatedConnections;

  bool get isServerListening => _server != null;

  bool get hasActiveTransfers =>
      _outgoingTransfers.values.any((transfer) => transfer.isActiveTransfer) ||
      _incomingTransfers.values.any((transfer) => !transfer.canceled) ||
      _pendingIncomingTransfers.values.any((transfer) => !transfer.isStream);

  bool hasActiveTransfersForConversation(
    ConversationKind kind,
    String conversationId,
  ) {
    bool matchesConversation({
      required ConversationKind transferKind,
      required String transferConversationId,
    }) {
      return transferKind == kind && transferConversationId == conversationId;
    }

    return _outgoingTransfers.values.any(
          (transfer) =>
              transfer.isActiveTransfer &&
              matchesConversation(
                transferKind: transfer.conversationKind,
                transferConversationId: transfer.conversationId,
              ),
        ) ||
        _incomingTransfers.values.any(
          (transfer) =>
              !transfer.canceled &&
              matchesConversation(
                transferKind: transfer.conversationKind,
                transferConversationId: transfer.conversationId,
              ),
        ) ||
        _pendingIncomingTransfers.values.any(
          (transfer) =>
              !transfer.isStream &&
              matchesConversation(
                transferKind: transfer.conversationKind,
                transferConversationId: transfer.conversationId,
              ),
        );
  }

  ConnectionDiagnostics get diagnostics => ConnectionDiagnostics(
        serverListening: _server != null,
        directPeerCount: _directPeerIds().length,
        knownPeerCount:
            _peerRegistryIds.where((peerId) => peerId != myId).length,
        lastDirectPeerSeenAt: _lastDirectPeerSeenAt,
        lastDirectPeerId: _lastDirectPeerId,
        lastDirectPeerName:
            _lastDirectPeerId == null ? null : _displayName(_lastDirectPeerId),
        lastTransportError: _lastTransportError,
      );

  List<PeerSummary> get knownPeers {
    final now = DateTime.now();
    final ids = <String>{..._peerRegistryIds};
    ids.remove(myId);

    final peers = ids.map((peerId) {
      final lastSeen = _peerLastSeen[peerId] ?? now;
      final directIp = _peerIps[peerId] ?? '';
      final isApproved = canMessage(peerId);
      final directSeenAt = _directPeerLastSeen[peerId];
      final directFresh = directSeenAt != null &&
          now.difference(directSeenAt) <= _directPeerStaleDuration;
      final lastSeenFresh = now.difference(lastSeen) <= _peerForgetDuration;
      final routeStatus = directFresh
          ? PeerRouteStatus.directOnline
          : lastSeenFresh
              ? PeerRouteStatus.stale
              : PeerRouteStatus.offline;
      final isOnline = routeStatus == PeerRouteStatus.directOnline;
      final hasKnownAddress = directIp.isNotEmpty;

      return PeerSummary(
        peerId: peerId,
        name: _displayName(peerId),
        ip: directIp,
        isApproved: isApproved,
        isReachable: hasKnownAddress && routeStatus != PeerRouteStatus.offline,
        isDirect: true,
        isOnline: isOnline,
        hopCount: 1,
        nextHopId: hasKnownAddress ? peerId : null,
        viaPeerId: null,
        viaPeerName: null,
        lastSeen: lastSeen,
        routeStatus: routeStatus,
      );
    }).toList(growable: false);

    peers.sort((a, b) {
      final approvalWeight =
          (b.isApproved ? 1 : 0).compareTo(a.isApproved ? 1 : 0);
      if (approvalWeight != 0) return approvalWeight;
      final onlineWeight = (b.isOnline ? 1 : 0).compareTo(a.isOnline ? 1 : 0);
      if (onlineWeight != 0) return onlineWeight;
      final directWeight = (b.isDirect ? 1 : 0).compareTo(a.isDirect ? 1 : 0);
      if (directWeight != 0) return directWeight;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return peers;
  }

  List<GroupRoom> get groups {
    final rooms = _groups.values.toList(growable: false);
    rooms.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return rooms;
  }

  GroupRoom? groupById(String groupId) => _groups[groupId];

  PeerSummary? peerSummaryFor(String peerId) {
    for (final peer in knownPeers) {
      if (peer.peerId == peerId) return peer;
    }
    return null;
  }

  Future<void> start() async {
    if (_server != null) return;

    _stopped = false;
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        messagingPort,
        shared: true,
      );
      debugPrint('Messaging TCP server ready on port $messagingPort');
      _server!.listen(
        _acceptIncoming,
        onError: (Object error) {
          debugPrint('Messaging server socket error: $error');
        },
      );
      _maintenanceTimer = Timer.periodic(
        _directMaintenanceInterval,
        (_) {
          _expireSeenCaches();
          _expireStalePeers();
          unawaited(_refreshDirectConnections());
        },
      );
      unawaited(_refreshDirectConnections());
    } catch (error) {
      debugPrint('Could not start messaging server: $error');
      _lastTransportError = 'Could not start TCP server: $error';
      _emitChange();
    }
  }

  void stop() {
    _stopped = true;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    for (final socket in _connections.values.toList(growable: false)) {
      socket.destroy();
    }
    for (final state in _socketStates.values.toList(growable: false)) {
      unawaited(state.subscription?.cancel());
    }
    _cancelTransfersForDisconnectedPeers(
      _activeTransferPeerIds(),
      reason: 'Connection closed',
      status: TransferStatus.canceled,
    );
    _connections.clear();
    _socketStates.clear();
    _writeQueues.clear();
    _messageHandlers.clear();
    _canvasHandlers.clear();
    _outgoingTransfers.clear();
    _pendingIncomingTransfers.clear();
    _incomingTransfers.clear();
    for (final session in _streamSessions.values.toList(growable: false)) {
      unawaited(session.close());
    }
    _streamSessions.clear();
    _permissionFailureMessages.clear();
    _peerRegistryIds.clear();
    _directVerificationTasks.clear();
    _directPingProbes.clear();
    _directPeerLastSeen.clear();
    _peerPorts.clear();
    _seenMessageCache.clear();
    _lastDirectPeerSeenAt = null;
    _lastDirectPeerId = null;
    _lastTransportError = null;
    _server?.close();
    _server = null;
  }

  void setOnlineMode(bool isOnline) {
    if (_isOnlineMode == isOnline) return;
    _isOnlineMode = isOnline;
    if (!isOnline) {
      for (final entry in _socketStates.entries.toList(growable: false)) {
        final peerId = entry.value.peerId;
        if (peerId == null || !canMessage(peerId)) {
          entry.key.destroy();
        }
      }
    }
    _emitChange();
  }

  void setOnlyInitiatedConnections(bool value) {
    if (_onlyInitiatedConnections == value) return;
    _onlyInitiatedConnections = value;
    _emitChange();
  }

  void updateIdentity({
    required String name,
  }) {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    if (cleanName != myName) {
      myName = cleanName;
      _peerNames[myId] = cleanName;
    } else {
      return;
    }
    _emitChange();
    unawaited(_broadcastIdentity());
  }

  void registerDiscoveredPeer({
    required String peerId,
    required String peerName,
    required String peerIp,
    int tcpPort = messagingPort,
    String deviceType = 'unknown',
    String appVersion = '',
    String protocolVersion = '',
    DateTime? timestamp,
  }) {
    if (peerId == myId) return;
    final port = tcpPort <= 0 ? messagingPort : tcpPort;
    final previousIp = _peerIps[peerId];
    if (_peerRegistryIds.contains(peerId) &&
        previousIp != null &&
        previousIp.isNotEmpty &&
        previousIp != peerIp) {
      debugPrint(
        'Discovery candidate has new IP for $peerId: $previousIp -> $peerIp',
      );
    }
    debugPrint(
      'Discovery candidate received: $peerName ($peerId) '
      '$deviceType app=$appVersion protocol=$protocolVersion at $peerIp:$port',
    );
    _peerRegistryIds.add(peerId);
    _peerPorts[peerId] = port;
    _rememberPeer(
      peerId: peerId,
      peerName: peerName,
      peerIp: peerIp,
      seenAt: timestamp ?? DateTime.now(),
    );
    _emitChange();
    final current = _directVerificationTasks[peerId];
    if (current != null) return;

    final task = _verifyDiscoveredPeer(
      peerId: peerId,
      peerName: peerName,
      peerIp: peerIp,
      tcpPort: port,
      deviceType: deviceType,
      appVersion: appVersion,
      protocolVersion: protocolVersion,
      timestamp: timestamp,
    );
    _directVerificationTasks[peerId] = task;
    unawaited(
      task.whenComplete(() {
        if (_directVerificationTasks[peerId] == task) {
          _directVerificationTasks.remove(peerId);
        }
      }),
    );
  }

  Future<bool> _verifyDiscoveredPeer({
    required String peerId,
    required String peerName,
    required String peerIp,
    required int tcpPort,
    required String deviceType,
    required String appVersion,
    required String protocolVersion,
    required DateTime? timestamp,
  }) async {
    try {
      debugPrint(
        'Direct verification started: $peerName ($peerId) '
        'at $peerIp:$tcpPort announcedAt=${timestamp?.toIso8601String() ?? 'unknown'}',
      );
      final socket = await _ensureConnection(
        peerId: peerId,
        peerIp: peerIp,
        peerPort: tcpPort,
        allowBeforePermission: true,
      );
      final state = _socketStates[socket];
      if (state != null) {
        await _sendRegister(socket, state);
      }
      await _sendInfoRequest(socket);
      final alive = await _sendDirectPing(
        peerId: peerId,
        peerIp: peerIp,
        peerPort: tcpPort,
        peerName: peerName,
      );
      if (!alive) {
        throw StateError('PING/PONG verification failed');
      }
      debugPrint(
        'Direct verification succeeded: $peerName ($peerId) '
        '$deviceType app=$appVersion protocol=$protocolVersion',
      );
      return true;
    } catch (error) {
      debugPrint(
        'Direct verification failed: $peerName ($peerId) at $peerIp:$tcpPort: $error',
      );
      _lastTransportError = 'Direct verification failed for $peerName: $error';
      _emitChange();
      return false;
    }
  }

  Future<bool> _sendDirectPing({
    required String peerId,
    required String? peerIp,
    required int? peerPort,
    String? peerName,
    Duration timeout = _aliveProbeTimeout,
  }) async {
    final pingId = _nextOpaqueId('ping');
    final probe = _DirectPingProbe(peerId: peerId, peerPort: peerPort);
    _directPingProbes[pingId] = probe;

    try {
      final socket = await _ensureConnection(
        peerId: peerId,
        peerIp: peerIp,
        peerPort: peerPort,
        allowBeforePermission: true,
      );
      final state = _socketStates[socket];
      if (state != null) {
        await _sendRegister(socket, state);
      }
      await _sendJson(socket, {
        'type': directFramePing,
        'pingId': pingId,
        ..._localDeviceInfo(),
      });
      debugPrint(
        'PING sent: $pingId to ${peerName ?? _displayName(peerId)} ($peerId)',
      );
      return probe.completer.future.timeout(
        timeout,
        onTimeout: () {
          _directPingProbes.remove(pingId);
          debugPrint('PING timed out: $pingId to $peerId');
          return false;
        },
      );
    } catch (error) {
      _directPingProbes.remove(pingId);
      debugPrint('PING failed: $pingId to $peerId: $error');
      return false;
    }
  }

  Future<Set<String>> probeAlive(
    Iterable<String> peerIds, {
    Duration timeout = _aliveProbeTimeout,
    bool markUnresponsive = false,
  }) async {
    final uniquePeerIds = peerIds
        .where((peerId) => peerId.isNotEmpty && peerId != myId)
        .toSet()
        .toList(growable: false);
    if (uniquePeerIds.isEmpty) return const <String>{};

    final probes = <String, Future<bool>>{};
    for (final peerId in uniquePeerIds) {
      probes[peerId] = _sendDirectPing(
        peerId: peerId,
        peerIp: _peerIps[peerId],
        peerPort: _peerPorts[peerId],
        peerName: _displayName(peerId),
        timeout: timeout,
      );
    }

    final alivePeerIds = <String>{};
    for (final entry in probes.entries) {
      final isAlive = await entry.value;
      if (isAlive) {
        alivePeerIds.add(entry.key);
      } else if (markUnresponsive) {
        _markPeerUnresponsive(entry.key);
      }
    }
    _emitChange();
    return alivePeerIds;
  }

  List<ChatMessage> getHistory(String peerId) {
    return _conversationHistory(_peerConversationId(peerId));
  }

  List<ChatMessage> getGroupHistory(String groupId) {
    return _conversationHistory(_groupConversationId(groupId));
  }

  List<CanvasEvent> getPeerCanvasHistory(String peerId) {
    return _conversationCanvasHistory(_peerConversationId(peerId));
  }

  List<CanvasEvent> getGroupCanvasHistory(String groupId) {
    return _conversationCanvasHistory(_groupConversationId(groupId));
  }

  void clearChat(String peerId) {
    _clearConversation(_peerConversationId(peerId));
  }

  void clearGroupChat(String groupId) {
    _clearConversation(_groupConversationId(groupId));
  }

  void registerHandler(String peerId, MessageHandler handler) {
    _registerConversationHandler(_peerConversationId(peerId), handler);
  }

  void unregisterHandler(String peerId) {
    _messageHandlers.remove(_peerConversationId(peerId));
  }

  void registerGroupHandler(String groupId, MessageHandler handler) {
    _registerConversationHandler(_groupConversationId(groupId), handler);
  }

  void unregisterGroupHandler(String groupId) {
    _messageHandlers.remove(_groupConversationId(groupId));
  }

  void registerPeerCanvasHandler(String peerId, CanvasEventHandler handler) {
    _registerCanvasHandler(_peerConversationId(peerId), handler);
  }

  void unregisterPeerCanvasHandler(String peerId) {
    _canvasHandlers.remove(_peerConversationId(peerId));
  }

  void registerGroupCanvasHandler(String groupId, CanvasEventHandler handler) {
    _registerCanvasHandler(_groupConversationId(groupId), handler);
  }

  void unregisterGroupCanvasHandler(String groupId) {
    _canvasHandlers.remove(_groupConversationId(groupId));
  }

  PeerPermissionState permissionStateFor(String peerId) {
    return _permissionStates[peerId] ?? PeerPermissionState.none;
  }

  bool canMessage(String peerId) {
    return permissionStateFor(peerId) == PeerPermissionState.granted;
  }

  String? permissionFailureMessageFor(String peerId) {
    return _permissionFailureMessages[peerId];
  }

  Future<void> disconnectPeer(String peerId) {
    return _forceDisconnectPeers(
      {peerId},
      reason: 'Transfer canceled',
      clearPeerConversations: true,
      notifyPeers: true,
    );
  }

  Future<void> disconnectConversation({
    required ConversationKind kind,
    required String conversationId,
  }) {
    final peerIds = _peerIdsForConversation(kind, conversationId);
    return _forceDisconnectPeers(
      peerIds,
      reason: 'Transfer canceled',
      clearPeerConversations: kind == ConversationKind.peer,
      notifyPeers: true,
    );
  }

  Future<void> forceDisconnectAll({bool notifyPeers = true}) {
    final peerIds = <String>{
      ..._connections.keys,
      ..._directPeerIds(),
      ..._activeTransferPeerIds(),
    }..remove(myId);
    return _forceDisconnectPeers(
      peerIds,
      reason: 'Transfer canceled',
      clearPeerConversations: false,
      notifyPeers: notifyPeers,
    );
  }

  Set<String> _peerIdsForConversation(
    ConversationKind kind,
    String conversationId,
  ) {
    switch (kind) {
      case ConversationKind.peer:
        return conversationId.isEmpty || conversationId == myId
            ? <String>{}
            : <String>{conversationId};
      case ConversationKind.group:
        final room = _groups[conversationId];
        return room == null
            ? <String>{}
            : room.members
                .map((member) => member.peerId)
                .where((peerId) => peerId != myId)
                .toSet();
    }
  }

  Future<bool> requestPermission({
    String? peerIp,
    required String peerId,
    required String peerName,
  }) async {
    if (peerId == myId) return false;
    _rememberPeer(
      peerId: peerId,
      peerName: peerName,
      peerIp: peerIp,
      seenAt: DateTime.now(),
    );
    if (canMessage(peerId)) return true;

    final inFlight = _permissionCompleters[peerId];
    if (inFlight != null) return inFlight.future;

    final completer = Completer<bool>();
    _permissionCompleters[peerId] = completer;
    _permissionFailureMessages.remove(peerId);
    _setPermissionState(peerId, PeerPermissionState.requesting);
    debugPrint(
      'Permission request sent: to $peerName ($peerId) at ${peerIp ?? _peerIps[peerId] ?? 'unknown IP'}',
    );

    try {
      final delivered = await _sendPacket(
        destinationPeerId: peerId,
        directPeerIp: peerIp,
        allowUnapprovedDestination: true,
        payload: {
          'kind': 'permission_request',
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
      if (!delivered) {
        debugPrint(
          'Permission request blocked: no direct connection to $peerName ($peerId)',
        );
        throw StateError('No direct LAN connection found to $peerName');
      }
    } catch (error) {
      debugPrint('Failed to request permission from $peerId: $error');
      _permissionCompleters.remove(peerId);
      _permissionFailureMessages[peerId] =
          'Could not deliver the connection request to $peerName. '
          'Make sure both devices are on the same Wi-Fi or hotspot, keep ShareViaLAN open, and check that TCP $messagingPort is not blocked.';
      _setPermissionState(peerId, PeerPermissionState.none);
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future.timeout(
      const Duration(seconds: _permissionTimeoutSeconds),
      onTimeout: () {
        debugPrint('Permission request timed out: $peerName ($peerId)');
        _permissionCompleters.remove(peerId);
        _permissionFailureMessages[peerId] =
            'Connection request to $peerName timed out. The device may be '
            'offline, on another network, blocked by a firewall, or unable to show the permission dialog.';
        if (!canMessage(peerId)) {
          _setPermissionState(peerId, PeerPermissionState.none);
        }
        return false;
      },
    );
  }

  Future<bool> sendMessage({
    String? peerIp,
    required String peerId,
    required String text,
  }) async {
    if (!canMessage(peerId)) {
      debugPrint(
          'Blocked text send to $peerId because permission is not granted');
      return false;
    }

    final timestamp = DateTime.now();
    final messageId = _nextMessageId();

    final delivered = await _sendPacket(
      destinationPeerId: peerId,
      directPeerIp: peerIp,
      payload: {
        'kind': 'text',
        'conversationType': 'peer',
        'messageId': messageId,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      },
    );

    if (!delivered) {
      return false;
    }

    _upsertAndNotify(
      _peerConversationId(peerId),
      ChatMessage(
        messageId: messageId,
        conversationId: peerId,
        conversationKind: ConversationKind.peer,
        text: text,
        fromName: myName,
        fromId: myId,
        timestamp: timestamp,
        isMe: true,
      ),
    );
    return true;
  }

  Future<bool> sendFile({
    String? peerIp,
    required String peerId,
    required String filePath,
    required String fileName,
  }) {
    if (!canMessage(peerId)) {
      debugPrint(
          'Blocked file send to $peerId because permission is not granted');
      return Future<bool>.value(false);
    }

    return _sendFileToConversation(
      kind: ConversationKind.peer,
      conversationId: peerId,
      recipients: [peerId],
      filePath: filePath,
      fileName: fileName,
      directPeerIps: {peerId: peerIp},
    );
  }

  Future<bool> shareVideoStream({
    String? peerIp,
    required String peerId,
    required String filePath,
    required String fileName,
    StreamTransferMode streamMode = StreamTransferMode.streamOnly,
    bool deleteSourceOnComplete = false,
  }) {
    if (!canMessage(peerId)) {
      debugPrint(
          'Blocked stream share to $peerId because permission is not granted');
      return Future<bool>.value(false);
    }

    return _shareStreamToConversation(
      kind: ConversationKind.peer,
      conversationId: peerId,
      recipients: [peerId],
      filePath: filePath,
      fileName: fileName,
      directPeerIps: {peerId: peerIp},
      streamMode: streamMode,
      deleteSourceOnComplete: deleteSourceOnComplete,
    );
  }

  Future<bool> sendVideoStream({
    String? peerIp,
    required String peerId,
    required String filePath,
    required String fileName,
    StreamTransferMode streamMode = StreamTransferMode.streamOnly,
  }) {
    return shareVideoStream(
      peerIp: peerIp,
      peerId: peerId,
      filePath: filePath,
      fileName: fileName,
      streamMode: streamMode,
    );
  }

  GroupRoom createGroup({
    required String name,
  }) {
    final groupId = _nextOpaqueId('group');
    final joinSecret = _randomCode(length: 8);
    final code = _encodeInviteCode('GRP', {
      'groupId': groupId,
      'groupName': name,
      'ownerId': myId,
      'ownerName': myName,
      'secret': joinSecret,
    });

    final room = GroupRoom(
      groupId: groupId,
      name: name,
      ownerId: myId,
      ownerName: myName,
      code: code,
      joinSecret: joinSecret,
      isOwner: true,
      members: [
        GroupMember(
          peerId: myId,
          name: myName,
          isOwner: true,
          isOnline: true,
        ),
      ],
      createdAt: DateTime.now(),
    );
    _groups[groupId] = room;
    _addSystemMessage(
      _groupConversationId(groupId),
      conversationId: groupId,
      kind: ConversationKind.group,
      text: 'Group "$name" created. Share the code to invite others.',
    );
    _emitChange();
    return room;
  }

  Future<bool> requestJoinGroup(String code) async {
    final decoded = _decodeInviteCode(code, 'GRP');
    if (decoded == null) return false;

    final ownerId = (decoded['ownerId'] ?? '').toString();
    final groupId = (decoded['groupId'] ?? '').toString();
    final groupName = (decoded['groupName'] ?? 'Group').toString();
    if (ownerId.isEmpty || groupId.isEmpty || ownerId == myId) {
      return false;
    }

    return _sendPacket(
      destinationPeerId: ownerId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': 'group_join_request',
        'groupId': groupId,
        'groupName': groupName,
        'groupCode': code,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<bool> sendGroupMessage({
    required String groupId,
    required String text,
  }) async {
    final room = _groups[groupId];
    if (room == null) return false;

    final timestamp = DateTime.now();
    final messageId = _nextMessageId();
    final recipients = room.members
        .where((member) => member.peerId != myId)
        .map((member) => member.peerId)
        .toList(growable: false);

    final delivered = await _sendPlainPayloadToRecipients(
      recipients: recipients,
      allowUnapprovedDestinations: true,
      payloadBuilder: (_) => {
        'kind': 'text',
        'conversationType': 'group',
        'conversationId': groupId,
        'conversationName': room.name,
        'messageId': messageId,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      },
    );

    if (!delivered && recipients.isNotEmpty) {
      return false;
    }

    _upsertAndNotify(
      _groupConversationId(groupId),
      ChatMessage(
        messageId: messageId,
        conversationId: groupId,
        conversationKind: ConversationKind.group,
        text: text,
        fromName: myName,
        fromId: myId,
        timestamp: timestamp,
        isMe: true,
      ),
    );
    return true;
  }

  Future<bool> sendGroupFile({
    required String groupId,
    required String filePath,
    required String fileName,
  }) async {
    final room = _groups[groupId];
    if (room == null) return false;
    final recipients = room.members
        .where((member) => member.peerId != myId)
        .map((member) => member.peerId)
        .toList(growable: false);

    return _sendFileToConversation(
      kind: ConversationKind.group,
      conversationId: groupId,
      conversationName: room.name,
      recipients: recipients,
      filePath: filePath,
      fileName: fileName,
      allowUnapprovedDestinations: true,
    );
  }

  Future<bool> shareGroupVideoStream({
    required String groupId,
    required String filePath,
    required String fileName,
    StreamTransferMode streamMode = StreamTransferMode.streamOnly,
    bool deleteSourceOnComplete = false,
  }) async {
    final room = _groups[groupId];
    if (room == null) return false;
    final recipients = room.members
        .where((member) => member.peerId != myId)
        .map((member) => member.peerId)
        .toList(growable: false);

    return _shareStreamToConversation(
      kind: ConversationKind.group,
      conversationId: groupId,
      conversationName: room.name,
      recipients: recipients,
      filePath: filePath,
      fileName: fileName,
      allowUnapprovedDestinations: true,
      streamMode: streamMode,
      deleteSourceOnComplete: deleteSourceOnComplete,
    );
  }

  Future<bool> sendGroupVideoStream({
    required String groupId,
    required String filePath,
    required String fileName,
    StreamTransferMode streamMode = StreamTransferMode.streamOnly,
  }) {
    return shareGroupVideoStream(
      groupId: groupId,
      filePath: filePath,
      fileName: fileName,
      streamMode: streamMode,
    );
  }

  Future<bool> sendPeerCanvasStroke({
    String? peerIp,
    required String peerId,
    required CanvasStroke stroke,
  }) {
    return _sendCanvasStroke(
      kind: ConversationKind.peer,
      conversationId: peerId,
      recipients: [peerId],
      stroke: stroke,
      directPeerIps: {peerId: peerIp},
    );
  }

  Future<bool> sendGroupCanvasStroke({
    required String groupId,
    required CanvasStroke stroke,
  }) {
    final room = _groups[groupId];
    if (room == null) return Future<bool>.value(false);
    return _sendCanvasStroke(
      kind: ConversationKind.group,
      conversationId: groupId,
      conversationName: room.name,
      recipients: room.members
          .where((member) => member.peerId != myId)
          .map((member) => member.peerId)
          .toList(growable: false),
      stroke: stroke,
      allowUnapprovedDestinations: true,
    );
  }

  Future<bool> clearPeerCanvas({
    String? peerIp,
    required String peerId,
  }) {
    return _sendCanvasClear(
      kind: ConversationKind.peer,
      conversationId: peerId,
      recipients: [peerId],
      directPeerIps: {peerId: peerIp},
    );
  }

  Future<bool> clearGroupCanvas({
    required String groupId,
  }) {
    final room = _groups[groupId];
    if (room == null) return Future<bool>.value(false);
    return _sendCanvasClear(
      kind: ConversationKind.group,
      conversationId: groupId,
      conversationName: room.name,
      recipients: room.members
          .where((member) => member.peerId != myId)
          .map((member) => member.peerId)
          .toList(growable: false),
      allowUnapprovedDestinations: true,
    );
  }

  void _acceptIncoming(Socket socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // Best effort; not every platform exposes every socket option.
    }
    debugPrint(
        'Accepted incoming connection from ${socket.remoteAddress.address}');
    _listenOnSocket(socket, knownPeerId: null);
  }

  void _listenOnSocket(Socket socket, {required String? knownPeerId}) {
    final state = _SocketState(peerId: knownPeerId);
    _socketStates[socket] = state;
    if (knownPeerId != null) {
      _bindSocketToPeer(
        peerId: knownPeerId,
        socket: socket,
        state: state,
      );
    }
    _listenOnSocketWithState(socket, state);
  }

  void _listenOnSocketWithState(Socket socket, _SocketState state) {
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        subscription.pause();
        unawaited(
          _handleSocketChunk(socket, state, chunk).catchError((Object error) {
            debugPrint(
                'Socket parse error (${socket.remoteAddress.address}): $error');
            socket.destroy();
          }).whenComplete(() {
            if (subscription.isPaused) {
              subscription.resume();
            }
          }),
        );
      },
      onError: (Object error) {
        debugPrint('Socket error (${socket.remoteAddress.address}): $error');
        _handleSocketClosed(socket, state, error: error);
      },
      onDone: () {
        _handleSocketClosed(socket, state);
      },
      cancelOnError: true,
    );
    state.subscription = subscription;
  }

  Future<void> _handleSocketChunk(
    Socket socket,
    _SocketState state,
    List<int> chunk,
  ) async {
    var offset = 0;

    while (offset < chunk.length) {
      final newlineIndex = _indexOfByte(chunk, 10, offset);
      if (newlineIndex == -1) {
        final extraBytes = chunk.length - offset;
        if (state.headerBuffer.length + extraBytes > _headerLimitBytes) {
          throw const FormatException('Incoming JSON frame is too large');
        }
        state.headerBuffer.addAll(chunk.sublist(offset));
        break;
      }

      state.headerBuffer.addAll(chunk.sublist(offset, newlineIndex));
      final frameBytes = List<int>.from(state.headerBuffer);
      state.headerBuffer.clear();
      offset = newlineIndex + 1;

      final frameText = utf8.decode(frameBytes).trim();
      if (frameText.isEmpty) continue;

      final decoded = jsonDecode(frameText);
      if (decoded is! Map) {
        throw const FormatException('Incoming JSON frame is not an object');
      }

      await _handleFrame(socket, state, Map<String, dynamic>.from(decoded));
    }
  }

  Future<void> _handleFrame(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    if (_isNetworkMessageFrame(frame)) {
      await _handleNetworkMessage(socket, state, frame);
      return;
    }

    final type = (frame['type'] ?? '').toString();
    switch (type) {
      case directFrameInfo:
        await _handleInfo(socket, state, frame);
        return;
      case directFrameRegister:
        await _handleRegister(socket, state, frame);
        return;
      case directFramePing:
        await _handleDirectPing(socket, state, frame);
        return;
      case directFramePong:
        _handleDirectPong(socket, state, frame);
        return;
      case 'hello':
        await _handleHello(socket, state, frame);
        return;
      case 'permission_request':
        await _handleDirectPermissionRequest(socket, state, frame);
        return;
      case 'permission_response':
        _handleDirectPermissionResponse(socket, state, frame);
        return;
      case 'disconnect':
        final peerId =
            (frame['id'] ?? frame['deviceId'] ?? state.peerId ?? '').toString();
        if (peerId.isNotEmpty && peerId != myId) {
          _handleDisconnectPayload(originId: peerId);
        }
        return;
      case 'packet':
        await _handleNetworkMessage(socket, state, frame);
        return;
      default:
        debugPrint('Ignoring unknown frame type: $type');
    }
  }

  Map<String, dynamic> _localDeviceInfo() => {
        'deviceId': myId,
        'deviceName': myName,
        'deviceType': Platform.operatingSystem,
        'appVersion': lanComAppVersion,
        'protocolVersion': lanComProtocolVersion,
        'tcpPort': messagingPort,
        'timestamp': DateTime.now().toIso8601String(),
      };

  int? _tcpPortFromFrame(Map<String, dynamic> frame) {
    final port = int.tryParse((frame['tcpPort'] ?? '').toString());
    if (port == null || port <= 0 || port > 65535) return null;
    return port;
  }

  Future<void> _sendInfoRequest(Socket socket) {
    return _sendJson(socket, {
      'type': directFrameInfo,
      'request': true,
      ..._localDeviceInfo(),
    });
  }

  Future<void> _sendRegister(Socket socket, _SocketState state) async {
    if (state.registerSent) return;
    state.registerSent = true;
    await _sendJson(socket, {
      'type': directFrameRegister,
      ..._localDeviceInfo(),
    });
  }

  Future<void> _handleInfo(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final peerId = (frame['deviceId'] ?? frame['id'] ?? '').toString();
    final peerName =
        (frame['deviceName'] ?? frame['name'] ?? peerId).toString();
    if (peerId.isNotEmpty && peerId != myId) {
      _markDirectVerified(
        peerId: peerId,
        peerName: peerName,
        peerIp: socket.remoteAddress.address,
        peerPort: _tcpPortFromFrame(frame) ?? messagingPort,
        socket: socket,
        state: state,
      );
      debugPrint('INFO received from $peerName ($peerId)');
    }
    if (frame['request'] == true) {
      await _sendJson(socket, {
        'type': directFrameInfo,
        'request': false,
        ..._localDeviceInfo(),
      });
    }
  }

  Future<void> _handleRegister(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final peerId = (frame['deviceId'] ?? frame['id'] ?? '').toString();
    final peerName =
        (frame['deviceName'] ?? frame['name'] ?? peerId).toString();
    if (peerId.isEmpty || peerId == myId) return;

    _markDirectVerified(
      peerId: peerId,
      peerName: peerName,
      peerIp: socket.remoteAddress.address,
      peerPort: _tcpPortFromFrame(frame) ?? messagingPort,
      socket: socket,
      state: state,
    );
    debugPrint('REGISTER received from $peerName ($peerId)');

    if (frame['ack'] != true) {
      await _sendJson(socket, {
        'type': directFrameRegister,
        'ack': true,
        ..._localDeviceInfo(),
      });
    }
  }

  Future<void> _handleDirectPing(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final peerId =
        (frame['deviceId'] ?? frame['id'] ?? state.peerId ?? '').toString();
    final peerName =
        (frame['deviceName'] ?? frame['name'] ?? peerId).toString();
    final pingId = (frame['pingId'] ?? '').toString();
    if (peerId.isEmpty || peerId == myId || pingId.isEmpty) return;

    _markDirectVerified(
      peerId: peerId,
      peerName: peerName,
      peerIp: socket.remoteAddress.address,
      peerPort: _tcpPortFromFrame(frame) ?? messagingPort,
      socket: socket,
      state: state,
    );
    await _sendJson(socket, {
      'type': directFramePong,
      'pingId': pingId,
      ..._localDeviceInfo(),
    });
    debugPrint('PONG sent: $pingId to $peerName ($peerId)');
  }

  void _handleDirectPong(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) {
    final pingId = (frame['pingId'] ?? '').toString();
    final probe = _directPingProbes.remove(pingId);
    final peerId = (frame['deviceId'] ??
            frame['id'] ??
            state.peerId ??
            probe?.peerId ??
            '')
        .toString();
    final peerName =
        (frame['deviceName'] ?? frame['name'] ?? peerId).toString();
    if (peerId.isEmpty || peerId == myId) return;

    _markDirectVerified(
      peerId: peerId,
      peerName: peerName,
      peerIp: socket.remoteAddress.address,
      peerPort:
          _tcpPortFromFrame(frame) ?? probe?.peerPort ?? _peerPorts[peerId],
      socket: socket,
      state: state,
    );
    debugPrint('PONG received: $pingId from $peerName ($peerId)');
    if (probe != null && !probe.completer.isCompleted) {
      probe.completer.complete(true);
    }
  }

  Future<void> _handleHello(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final peerId = (frame['id'] ?? '').toString();
    final peerName = (frame['name'] ?? 'Unknown').toString();
    if (peerId.isEmpty) return;

    _markDirectVerified(
      peerId: peerId,
      peerIp: socket.remoteAddress.address,
      peerName: peerName,
      peerPort: _tcpPortFromFrame(frame) ?? messagingPort,
      socket: socket,
      state: state,
    );

    if (!state.registerSent) {
      await _sendHello(socket, state);
    }
  }

  Future<void> _handleDirectPermissionRequest(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final peerId = (frame['id'] ?? '').toString();
    final peerName = (frame['name'] ?? 'Unknown').toString();
    if (peerId.isEmpty) {
      throw const FormatException('Missing permission requester id');
    }

    _markDirectVerified(
      peerId: peerId,
      peerIp: socket.remoteAddress.address,
      peerName: peerName,
      peerPort:
          _tcpPortFromFrame(frame) ?? state.manualRemotePort ?? messagingPort,
      socket: socket,
      state: state,
    );

    if (!state.registerSent) {
      await _sendHello(socket, state);
    }

    if ((!_isOnlineMode || _onlyInitiatedConnections) &&
        !canMessage(peerId) &&
        permissionStateFor(peerId) != PeerPermissionState.requesting) {
      final reason = !_isOnlineMode
          ? 'receiver_offline_mode'
          : 'receiver_only_accepts_own_requests';
      debugPrint(
        'Permission request blocked: direct request from $peerId denied ($reason)',
      );
      await _sendJson(socket, {
        'type': 'permission_response',
        'id': myId,
        'name': myName,
        'accepted': false,
        'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      });
      socket.destroy();
      return;
    }

    if (canMessage(peerId)) {
      debugPrint('Permission request accepted: $peerId already approved');
      await _sendJson(socket, {
        'type': 'permission_response',
        'id': myId,
        'name': myName,
        'accepted': true,
        'timestamp': DateTime.now().toIso8601String(),
      });
      return;
    }

    if (permissionStateFor(peerId) == PeerPermissionState.requesting) {
      debugPrint(
        'Permission request accepted: simultaneous request with $peerId',
      );
      _grantPeerAccess(peerId);
      _completePermission(peerId, accepted: true);
      await _sendJson(socket, {
        'type': 'permission_response',
        'id': myId,
        'name': myName,
        'accepted': true,
        'timestamp': DateTime.now().toIso8601String(),
      });
      return;
    }

    _setPermissionState(peerId, PeerPermissionState.incoming);

    var accepted = false;
    var reason = 'user_denied';
    final handler = permissionRequestHandler;
    if (handler != null) {
      try {
        accepted = await handler(
          PermissionRequest(
            peerId: peerId,
            peerName: peerName,
            peerIp: socket.remoteAddress.address,
            timestamp: _parseTimestamp(frame['timestamp']),
          ),
        );
      } catch (error) {
        debugPrint('Permission dialog failed for $peerId: $error');
        accepted = false;
        reason = 'permission_dialog_failed';
      }
    } else {
      reason = 'receiver_has_no_permission_handler';
    }

    _setPermissionState(
      peerId,
      accepted ? PeerPermissionState.granted : PeerPermissionState.denied,
    );
    debugPrint(
      accepted
          ? 'Permission request accepted: $peerId'
          : 'Permission request blocked: $peerId ($reason)',
    );
    if (accepted) {
      _grantPeerAccess(peerId, notify: false);
    }

    await _sendJson(socket, {
      'type': 'permission_response',
      'id': myId,
      'name': myName,
      'accepted': accepted,
      if (!accepted) 'reason': reason,
      'timestamp': DateTime.now().toIso8601String(),
    });

    if (!accepted) {
      socket.destroy();
    }
    _emitChange();
  }

  void _handleDirectPermissionResponse(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) {
    final peerId = (frame['id'] ?? '').toString();
    final peerName = (frame['name'] ?? 'Unknown').toString();
    if (peerId.isEmpty) return;

    _markDirectVerified(
      peerId: peerId,
      peerIp: socket.remoteAddress.address,
      peerName: peerName,
      peerPort:
          _tcpPortFromFrame(frame) ?? state.manualRemotePort ?? messagingPort,
      socket: socket,
      state: state,
    );

    final accepted = frame['accepted'] == true;
    if (accepted) {
      _permissionFailureMessages.remove(peerId);
      _grantPeerAccess(peerId);
      debugPrint('Permission request accepted by $peerId');
    } else {
      _permissionFailureMessages[peerId] = _permissionFailureText(
        peerName: peerName,
        reason: (frame['reason'] ?? '').toString(),
      );
      _setPermissionState(peerId, PeerPermissionState.denied);
      debugPrint(
        'Permission request blocked by $peerId: ${(frame['reason'] ?? '').toString()}',
      );
    }
    _completePermission(peerId, accepted: accepted);
    debugPrint(
      '$peerName ${accepted ? 'accepted' : 'denied'} the connection request',
    );

    if (!accepted) {
      socket.destroy();
    }
  }

  Future<void> _handleNetworkMessage(
    Socket socket,
    _SocketState state,
    Map<String, dynamic> frame,
  ) async {
    final payload = _mapFrom(frame['payload']);
    final messageId =
        (frame['messageId'] ?? frame['packetId'] ?? '').toString();
    final senderId = (frame['senderId'] ?? frame['fromId'] ?? '').toString();
    final senderName =
        (frame['senderName'] ?? frame['fromName'] ?? senderId).toString();
    final destinationId =
        (frame['destinationId'] ?? frame['toId'] ?? '').toString();
    final protocolType = _protocolTypeForFrame(frame, payload);
    if (messageId.isEmpty ||
        senderId.isEmpty ||
        destinationId.isEmpty ||
        payload == null) {
      return;
    }

    if (!_markPacketSeen(messageId)) return;

    debugPrint(
      'Message received: $protocolType $messageId from $senderName '
      'to $destinationId directly',
    );

    _rememberPeer(
      peerId: senderId,
      peerName: senderName,
      seenAt: DateTime.now(),
    );
    if (state.peerId != null && state.directVerified) {
      _peerLastSeen[state.peerId!] = DateTime.now();
      _directPeerLastSeen[state.peerId!] = DateTime.now();
    }

    if (destinationId != myId) {
      debugPrint(
        'Dropping packet for $destinationId; direct mode only accepts packets addressed to this device',
      );
      return;
    }

    await _handlePayload(
      payload: payload,
      originId: senderId,
      originName: senderName,
      viaPeerName: null,
      packetId: messageId,
    );
    debugPrint(
      'Message delivered: $messageId from $senderName ($senderId) '
      'to $destinationId',
    );
  }

  Future<void> _handlePayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
    required String? viaPeerName,
    required String packetId,
  }) async {
    final kind = (payload['kind'] ?? '').toString();
    switch (kind) {
      case 'permission_request':
        await _handlePermissionRequestPayload(
          payload: payload,
          originId: originId,
          originName: originName,
        );
        return;
      case 'permission_response':
        _handlePermissionResponsePayload(payload: payload, originId: originId);
        return;
      case 'disconnect':
        _handleDisconnectPayload(originId: originId);
        return;
      case 'group_join_request':
        await _handleGroupJoinRequest(
          payload: payload,
          originId: originId,
          originName: originName,
        );
        return;
      case 'group_join_response':
        _handleGroupJoinResponse(payload);
        return;
      case 'group_membership_update':
        _handleGroupMembershipUpdate(payload);
        return;
      case 'chat_persistence':
        await _handleChatPersistencePayload(
          payload: payload,
          originId: originId,
        );
        return;
      case 'text':
        _handleTextPayload(
          payload: payload,
          originId: originId,
          originName: originName,
          viaPeerName: viaPeerName,
        );
        return;
      case 'file_offer':
      case 'stream_offer':
        await _handleFileOfferPayload(
          payload: payload,
          originId: originId,
          originName: originName,
          viaPeerName: viaPeerName,
          isStream: kind == 'stream_offer',
        );
        return;
      case 'file_response':
      case 'stream_response':
        _handleFileResponsePayload(payload: payload, originId: originId);
        return;
      case 'file_cancel':
      case 'stream_cancel':
        await _handleFileCancelPayload(payload: payload, originId: originId);
        return;
      case 'file_pause':
      case 'stream_pause':
        await _handleFilePausePayload(payload: payload, originId: originId);
        return;
      case 'file_resume':
      case 'stream_resume':
        await _handleFileResumePayload(payload: payload, originId: originId);
        return;
      case 'file_chunk_ack':
      case 'stream_chunk_ack':
        _handleFileChunkAckPayload(payload: payload, originId: originId);
        return;
      case 'file_complete':
      case 'stream_complete':
        _handleFileCompletePayload(payload: payload, originId: originId);
        return;
      case 'file_chunk':
      case 'stream_chunk':
        await _handleFileChunkPayload(
          payload: payload,
          originId: originId,
        );
        return;
      case 'file_end':
      case 'stream_end':
        await _handleFileEndPayload(
          payload: payload,
          originId: originId,
        );
        return;
      case 'canvas_stroke':
        await _handleCanvasStrokePayload(
          payload: payload,
          originId: originId,
          originName: originName,
          viaPeerName: viaPeerName,
        );
        return;
      case 'canvas_clear':
        await _handleCanvasClearPayload(
          payload: payload,
          originId: originId,
          originName: originName,
          viaPeerName: viaPeerName,
        );
        return;
      default:
        debugPrint('Ignoring unknown payload kind: $kind ($packetId)');
    }
  }

  Future<void> _handlePermissionRequestPayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
  }) async {
    if ((!_isOnlineMode || _onlyInitiatedConnections) &&
        !canMessage(originId) &&
        permissionStateFor(originId) != PeerPermissionState.requesting) {
      final reason = !_isOnlineMode
          ? 'receiver_offline_mode'
          : 'receiver_only_accepts_own_requests';
      debugPrint(
        'Permission request blocked: direct request from $originId denied ($reason)',
      );
      unawaited(
        _sendPacket(
          destinationPeerId: originId,
          allowUnapprovedDestination: true,
          payload: {
            'kind': 'permission_response',
            'accepted': false,
            'reason': reason,
            'timestamp': DateTime.now().toIso8601String(),
          },
        ),
      );
      return;
    }

    if (canMessage(originId)) {
      debugPrint('Permission request accepted: $originId already approved');
      unawaited(
        _sendPacket(
          destinationPeerId: originId,
          allowUnapprovedDestination: true,
          payload: {
            'kind': 'permission_response',
            'accepted': true,
            'timestamp': DateTime.now().toIso8601String(),
          },
        ),
      );
      return;
    }

    if (permissionStateFor(originId) == PeerPermissionState.requesting) {
      debugPrint(
        'Permission request accepted: simultaneous direct request with $originId',
      );
      _grantPeerAccess(originId);
      _completePermission(originId, accepted: true);
      unawaited(
        _sendPacket(
          destinationPeerId: originId,
          allowUnapprovedDestination: true,
          payload: {
            'kind': 'permission_response',
            'accepted': true,
            'timestamp': DateTime.now().toIso8601String(),
          },
        ),
      );
      return;
    }

    _setPermissionState(originId, PeerPermissionState.incoming);
    var accepted = false;
    var reason = 'user_denied';
    final handler = permissionRequestHandler;
    if (handler != null) {
      try {
        accepted = await handler(
          PermissionRequest(
            peerId: originId,
            peerName: originName,
            peerIp: _peerIps[originId] ?? '',
            timestamp: _parseTimestamp(payload['timestamp']),
          ),
        );
      } catch (error) {
        debugPrint('Permission dialog failed for $originId: $error');
        accepted = false;
        reason = 'permission_dialog_failed';
      }
    } else {
      reason = 'receiver_has_no_permission_handler';
    }

    if (accepted) {
      _grantPeerAccess(originId);
      debugPrint('Permission request accepted: direct packet from $originId');
    } else {
      _setPermissionState(originId, PeerPermissionState.denied);
      debugPrint(
        'Permission request blocked: direct packet from $originId ($reason)',
      );
    }

    await _sendPacket(
      destinationPeerId: originId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': 'permission_response',
        'accepted': accepted,
        if (!accepted) 'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  void _handlePermissionResponsePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) {
    final accepted = payload['accepted'] == true;
    if (accepted) {
      _permissionFailureMessages.remove(originId);
      _grantPeerAccess(originId);
      debugPrint('Permission request accepted by $originId');
    } else {
      _permissionFailureMessages[originId] = _permissionFailureText(
        peerName: _displayName(originId),
        reason: (payload['reason'] ?? '').toString(),
      );
      _setPermissionState(originId, PeerPermissionState.denied);
      debugPrint(
        'Permission request blocked by $originId: ${(payload['reason'] ?? '').toString()}',
      );
    }
    _completePermission(originId, accepted: accepted);
  }

  void _handleDisconnectPayload({required String originId}) {
    _cancelTransfersForDisconnectedPeers(
      {originId},
      reason: 'Peer disconnected',
      status: TransferStatus.canceled,
    );
    _forgetDisconnectedPeer(originId, clearPeerConversation: true);
    debugPrint('Peer disconnected: $originId');
    _emitChange();
  }

  Set<String> _activeTransferPeerIds() {
    final peerIds = <String>{};
    for (final transfer in _outgoingTransfers.values) {
      if (!transfer.stopped) {
        peerIds.addAll(transfer.allRecipients);
      }
    }
    for (final transfer in _incomingTransfers.values) {
      if (!transfer.canceled) {
        peerIds.add(transfer.originPeerId);
      }
    }
    for (final transfer in _pendingIncomingTransfers.values) {
      peerIds.add(transfer.originPeerId);
    }
    peerIds.remove(myId);
    return peerIds;
  }

  Future<void> _forceDisconnectPeers(
    Iterable<String> rawPeerIds, {
    required String reason,
    required bool clearPeerConversations,
    required bool notifyPeers,
  }) async {
    final peerIds = rawPeerIds
        .where((peerId) => peerId.isNotEmpty && peerId != myId)
        .toSet();
    if (peerIds.isEmpty) return;

    _cancelTransfersForDisconnectedPeers(
      peerIds,
      reason: reason,
      status: TransferStatus.canceled,
    );

    final notices = <Future<void>>[];
    if (notifyPeers) {
      for (final peerId in peerIds) {
        notices.add(_sendDirectDisconnectNotice(peerId));
      }
      await Future.wait(notices).timeout(
        _directDisconnectFlushTimeout,
        onTimeout: () => const <void>[],
      );
    }

    for (final peerId in peerIds) {
      _forgetDisconnectedPeer(
        peerId,
        clearPeerConversation: clearPeerConversations,
      );
    }
    _emitChange();
  }

  Future<void> _sendDirectDisconnectNotice(String peerId) async {
    final socket = _connections[peerId];
    if (socket == null) return;
    try {
      socket.add(
        utf8.encode(
          '${jsonEncode({
                'type': 'disconnect',
                'id': myId,
                'name': myName,
                'timestamp': DateTime.now().toIso8601String(),
              })}\n',
        ),
      );
      await socket.flush().timeout(_directDisconnectFlushTimeout);
    } catch (error) {
      debugPrint('Disconnect notice failed for $peerId: $error');
    }
  }

  void _forgetDisconnectedPeer(
    String peerId, {
    required bool clearPeerConversation,
  }) {
    _permissionCompleters.remove(peerId);
    _permissionFailureMessages.remove(peerId);
    _setPermissionState(peerId, PeerPermissionState.none, notify: false);
    _directPeerLastSeen.remove(peerId);
    final socket = _connections.remove(peerId);
    socket?.destroy();
    if (clearPeerConversation) {
      _clearTransientPeerConversation(peerId);
    }
  }

  void _cancelTransfersForDisconnectedPeers(
    Set<String> peerIds, {
    required String reason,
    required TransferStatus status,
  }) {
    for (final entry in _outgoingTransfers.entries.toList(growable: false)) {
      final transfer = entry.value;
      final affected =
          transfer.allRecipients.any((peerId) => peerIds.contains(peerId));
      if (!affected) continue;
      transfer.cancel();
      _outgoingTransfers.remove(entry.key);
      unawaited(transfer.disposeTemporarySource());
      _updateOutgoingTransferStatus(
        transfer,
        status,
        error: reason,
      );
    }

    for (final entry
        in _pendingIncomingTransfers.entries.toList(growable: false)) {
      final transfer = entry.value;
      if (!peerIds.contains(transfer.originPeerId)) continue;
      _pendingIncomingTransfers.remove(entry.key);
      _updateTransferMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        transferStatus: status,
        transferSpeedBytesPerSecond: 0,
        error: reason,
      );
    }

    for (final entry in _incomingTransfers.entries.toList(growable: false)) {
      final transfer = entry.value;
      if (!peerIds.contains(transfer.originPeerId)) continue;
      _incomingTransfers.remove(entry.key);
      unawaited(transfer.disposeWithFailure(reason));
      _updateTransferMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        transferStatus: status,
        transferSpeedBytesPerSecond: 0,
        error: reason,
      );
    }
  }

  Future<void> _handleGroupJoinRequest({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
  }) async {
    final groupId = (payload['groupId'] ?? '').toString();
    final groupName = (payload['groupName'] ?? 'Group').toString();
    final groupCode = (payload['groupCode'] ?? '').toString();
    final room = _groups[groupId];
    if (room == null || !room.isOwner || groupCode.isEmpty) {
      return;
    }

    if (room.joinSecret !=
        (_decodeInviteCode(groupCode, 'GRP')?['secret'] ?? '')) {
      await _sendPacket(
        destinationPeerId: originId,
        allowUnapprovedDestination: true,
        payload: {
          'kind': 'group_join_response',
          'groupId': groupId,
          'accepted': false,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
      return;
    }

    var accepted = true;
    final handler = groupJoinRequestHandler;
    if (handler != null) {
      try {
        accepted = await handler(
          GroupJoinRequest(
            groupId: groupId,
            groupName: groupName,
            groupCode: groupCode,
            requesterId: originId,
            requesterName: originName,
            timestamp: _parseTimestamp(payload['timestamp']),
          ),
        );
      } catch (error) {
        debugPrint('Group join dialog failed for $originId: $error');
        accepted = false;
      }
    }

    if (accepted) {
      _grantPeerAccess(originId);
      final members = _memberListWithPeer(
        room.members,
        originId,
        originName,
        isOwner: false,
      );
      _groups[groupId] = room.copyWith(members: members);
      _addSystemMessage(
        _groupConversationId(groupId),
        conversationId: groupId,
        kind: ConversationKind.group,
        text: '$originName joined the group.',
      );
      await _broadcastGroupMembership(groupId);
    }

    await _sendPacket(
      destinationPeerId: originId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': 'group_join_response',
        'groupId': groupId,
        'accepted': accepted,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  void _handleGroupJoinResponse(Map<String, dynamic> payload) {
    if (payload['accepted'] == true) return;
    final groupId = (payload['groupId'] ?? '').toString();
    if (groupId.isNotEmpty) {
      _addSystemMessage(
        _groupConversationId(groupId),
        conversationId: groupId,
        kind: ConversationKind.group,
        text: 'Join request was denied.',
      );
    }
  }

  void _handleGroupMembershipUpdate(Map<String, dynamic> payload) {
    final groupId = (payload['groupId'] ?? '').toString();
    if (groupId.isEmpty) return;
    final room = _groupFromPayload(payload);
    _groups[groupId] = room;
    _grantPeerAccess(room.ownerId);
    _emitChange();
  }

  void _handleTextPayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
    required String? viaPeerName,
  }) {
    final conversationKind =
        _conversationKindFrom(payload['conversationType']?.toString());
    final conversationId = _incomingConversationId(
        conversationKind, payload['conversationId'], originId);
    if (conversationKind == ConversationKind.group &&
        !_conversationAllowsSender(
            conversationKind, conversationId, originId)) {
      return;
    }

    final messageId =
        (payload['messageId'] ?? _nextRemoteMessageId(originId)).toString();
    final message = ChatMessage(
      messageId: messageId,
      conversationId: conversationId,
      conversationKind: conversationKind,
      text: (payload['text'] ?? '').toString(),
      fromName: originName,
      fromId: originId,
      timestamp: _parseTimestamp(payload['timestamp']),
      isMe: false,
      viaPeerName: viaPeerName,
    );
    _upsertAndNotify(
      _conversationKey(conversationKind, conversationId),
      message,
      bufferIfNoHandler: true,
    );
    incomingMessageHandler?.call(message);
  }

  Future<void> _handleChatPersistencePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final conversationKind =
        _conversationKindFrom(payload['conversationType']?.toString());
    final conversationId = _incomingConversationId(
      conversationKind,
      payload['conversationId'],
      originId,
    );
    final enabled = payload['enabled'] == true;

    final allowed = switch (conversationKind) {
      ConversationKind.peer => canMessage(originId),
      ConversationKind.group => _groups[conversationId]?.ownerId == originId,
    };
    if (!allowed) return;

    await _applyChatPersistence(
      kind: conversationKind,
      conversationId: conversationId,
      enabled: enabled,
      clearWhenDisabled: true,
    );
  }

  Future<void> _handleFileOfferPayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
    required String? viaPeerName,
    bool isStream = false,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    final fileName = (payload['fileName'] ?? 'file').toString();
    final fileSize = _intFrom(payload['fileSize']);
    if (transferId.isEmpty || fileSize < 0) return;

    final conversationKind =
        _conversationKindFrom(payload['conversationType']?.toString());
    final conversationId = _incomingConversationId(
        conversationKind, payload['conversationId'], originId);
    if (conversationKind == ConversationKind.group &&
        !_conversationAllowsSender(
            conversationKind, conversationId, originId)) {
      return;
    }
    if (!await _featureAllowed(
      fileReceivingGuard,
      conversationKind,
      conversationId,
    )) {
      debugPrint(
        'Blocked incoming file for ${conversationKind.name}::$conversationId',
      );
      await _sendFileResponse(
        destinationPeerId: originId,
        transferId: transferId,
        accepted: false,
        isStream: isStream,
        reason: 'file_receive_disabled',
      );
      return;
    }

    final streamMode = isStream
        ? _streamModeFromName((payload['streamMode'] ?? '').toString())
        : StreamTransferMode.streamAndSend;
    final messageId =
        (payload['messageId'] ?? _nextRemoteMessageId(originId)).toString();
    final pending = _PendingIncomingTransfer(
      conversationId: conversationId,
      conversationKind: conversationKind,
      originPeerId: originId,
      originPeerName: originName,
      transferId: transferId,
      messageId: messageId,
      fileName: fileName,
      fileSize: fileSize,
      isStream: isStream,
      streamMode: streamMode,
      timestamp: _parseTimestamp(payload['timestamp']),
      viaPeerName: viaPeerName,
    );
    _pendingIncomingTransfers[transferId] = pending;

    final message = ChatMessage(
      messageId: messageId,
      conversationId: conversationId,
      conversationKind: conversationKind,
      text: isStream ? '[Video] $fileName' : '[File] $fileName',
      fromName: originName,
      fromId: originId,
      timestamp: _parseTimestamp(payload['timestamp']),
      isMe: false,
      isFile: true,
      isStream: isStream,
      streamSavesFile:
          !isStream || streamMode == StreamTransferMode.streamAndSend,
      transferId: transferId,
      fileName: fileName,
      fileSize: fileSize,
      transferStatus: TransferStatus.pending,
      transferProgress: 0,
      viaPeerName: viaPeerName,
    );
    _upsertAndNotify(
      _conversationKey(conversationKind, conversationId),
      message,
      bufferIfNoHandler: true,
    );
    if (!isStream && _shouldAutoAcceptIncomingFile(pending)) {
      await _acceptPendingIncomingTransfer(transferId);
      return;
    }
    incomingTransferOfferHandler?.call(message);
  }

  void _handleFileResponsePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;
    final outgoing = _outgoingTransfers[transferId];
    if (outgoing == null) return;

    if (payload['accepted'] == true) {
      if (outgoing.isStream && outgoing.transferStarted) {
        unawaited(_cancelLateStreamRequest(outgoing, originId));
        return;
      }
      outgoing.markAccepted(originId);
      if (outgoing.isStream) {
        _scheduleSharedStreamStart(outgoing);
      }
    } else {
      outgoing.markRejected(originId);
      if (outgoing.isStream &&
          !outgoing.transferStarted &&
          outgoing.pendingRecipients.isEmpty &&
          outgoing.acceptedRecipients.isEmpty) {
        _updateOutgoingTransferStatus(
          outgoing,
          TransferStatus.rejected,
          error: 'Stream dismissed',
        );
        _outgoingTransfers.remove(transferId);
        unawaited(outgoing.disposeTemporarySource());
      }
    }
  }

  Future<void> _handleFileCancelPayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;
    final reason = (payload['reason'] ?? '').toString();
    final remoteError = switch (reason) {
      'stream_already_active' => 'Stream already in progress',
      'file_unavailable' => 'File is no longer available',
      _ => 'Sender canceled',
    };

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null) {
      outgoing.markRejected(originId);
      if (outgoing.acceptedRecipients.isEmpty &&
          outgoing.pendingRecipients.isEmpty) {
        outgoing.cancel();
        if (outgoing.isStream && !outgoing.transferStarted) {
          _updateOutgoingTransferStatus(
            outgoing,
            TransferStatus.rejected,
            error: 'Stream dismissed',
          );
          _outgoingTransfers.remove(transferId);
          unawaited(outgoing.disposeTemporarySource());
        }
      }
      return;
    }

    final pending = _pendingIncomingTransfers.remove(transferId);
    if (pending != null) {
      _updateTransferMessage(
        conversationKind: pending.conversationKind,
        conversationId: pending.conversationId,
        messageId: pending.messageId,
        transferStatus: TransferStatus.canceled,
        error: remoteError,
      );
      return;
    }

    final incoming = _incomingTransfers.remove(transferId);
    if (incoming == null) return;
    await incoming.disposeWithFailure(remoteError);
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus: TransferStatus.canceled,
      transferSpeedBytesPerSecond: 0,
      error: remoteError,
    );
  }

  Future<void> acceptIncomingFile(String transferId) async {
    final pending = _pendingIncomingTransfers[transferId];
    if (pending?.isStream == true) {
      await requestIncomingStream(transferId);
      return;
    }
    await _acceptPendingIncomingTransfer(transferId);
  }

  Future<int> acceptIncomingFilesFromSender(String transferId) async {
    final pending = _pendingIncomingTransfers[transferId];
    if (pending == null) return 0;
    if (pending.isStream) {
      await requestIncomingStream(transferId);
      return 1;
    }

    final batchKey = _incomingFileBatchKey(pending);
    _autoAcceptIncomingFilesUntil[batchKey] =
        DateTime.now().add(_bulkFileAcceptDuration);
    final transferIds = _pendingIncomingTransfers.values
        .where((candidate) =>
            !candidate.isStream && _incomingFileBatchKey(candidate) == batchKey)
        .map((candidate) => candidate.transferId)
        .toList(growable: false);

    for (final id in transferIds) {
      await _acceptPendingIncomingTransfer(id);
    }
    return transferIds.length;
  }

  Future<void> requestIncomingStream(String transferId) async {
    final pending = _pendingIncomingTransfers[transferId];
    if (pending == null || !pending.isStream) return;
    await _acceptPendingIncomingTransfer(transferId);
  }

  Future<void> releaseStreamPlayback(
    String transferId, {
    bool cancelIfActive = false,
  }) async {
    if (cancelIfActive) {
      final incoming = _incomingTransfers[transferId];
      if (incoming != null && incoming.isStreamOnly) {
        await cancelTransfer(transferId);
        return;
      }
    }

    final session = _streamSessions[transferId];
    if (session != null) {
      await session.close(force: true);
    }

    final message = _findMessageByTransferId(transferId);
    if (message?.isStreamOnly == true) {
      final path = message?.localPath;
      if (path != null && !path.startsWith('http')) {
        try {
          await File(path).delete();
        } catch (_) {
          // Best effort cleanup for old temporary stream files.
        }
      }
      _updateFileMessage(
        conversationKind: message!.conversationKind,
        conversationId: message.conversationId,
        messageId: message.messageId,
        localPath: null,
        transferStatus: TransferStatus.canceled,
        transferSpeedBytesPerSecond: 0,
        error: 'Temporary stream closed',
      );
    }
  }

  Future<void> _acceptPendingIncomingTransfer(String transferId) async {
    final pending = _pendingIncomingTransfers.remove(transferId);
    if (pending == null) return;

    try {
      // Android 6–9 needs permission to publish into public Downloads. Newer
      // Android uses MediaStore; temporary streams never need this permission.
      if (Platform.isAndroid &&
          !(pending.isStream &&
              pending.streamMode == StreamTransferMode.streamOnly)) {
        final sdk = await LanPlatformChannel.androidSdkInt();
        if (sdk >= 23 &&
            sdk <= 28 &&
            !await ph.Permission.storage.request().isGranted) {
          throw const FileSystemException(
            'Storage permission denied. Allow storage access in Android app '
            'settings, then ask the sender to send this file again.',
          );
        }
      }
      final finalPath = await _uniqueDownloadPath(pending.fileName);
      final tempPath = await _incomingTempPath(
        transferId: transferId,
        fileName: pending.fileName,
        finalPath: finalPath,
        isStream: pending.isStream,
      );
      final tempFile = File(tempPath);
      await tempFile.parent.create(recursive: true);
      final writer = await tempFile.open(mode: FileMode.write);
      _ProgressiveStreamSession? streamSession;
      String? playbackPath;
      if (pending.isStream) {
        streamSession = _ProgressiveStreamSession(
          transferId: transferId,
          fileName: pending.fileName,
          filePath: tempPath,
          fileSize: pending.fileSize,
          onClosed: () => _streamSessions.remove(transferId),
        );
        playbackPath = await streamSession.start();
        if (playbackPath != null) {
          _streamSessions[transferId] = streamSession;
        } else {
          streamSession = null;
        }
      }
      _incomingTransfers[transferId] = _IncomingTransfer(
        conversationId: pending.conversationId,
        conversationKind: pending.conversationKind,
        originPeerId: pending.originPeerId,
        originPeerName: pending.originPeerName,
        transferId: pending.transferId,
        messageId: pending.messageId,
        fileName: pending.fileName,
        fileSize: pending.fileSize,
        isStream: pending.isStream,
        streamMode: pending.streamMode,
        tempPath: tempPath,
        finalPath: finalPath,
        writer: writer,
        streamSession: streamSession,
      );
      _updateTransferMessage(
        conversationKind: pending.conversationKind,
        conversationId: pending.conversationId,
        messageId: pending.messageId,
        localPath: pending.isStream ? playbackPath ?? tempPath : null,
        transferStatus: TransferStatus.receiving,
        transferProgress: pending.fileSize == 0 ? 1 : 0,
        transferSpeedBytesPerSecond: 0,
      );
      await _sendFileResponse(
        destinationPeerId: pending.originPeerId,
        transferId: transferId,
        accepted: true,
        isStream: pending.isStream,
      );
    } catch (error) {
      debugPrint('Could not accept incoming transfer $transferId: $error');
      _updateTransferMessage(
        conversationKind: pending.conversationKind,
        conversationId: pending.conversationId,
        messageId: pending.messageId,
        transferStatus: TransferStatus.failed,
        transferSpeedBytesPerSecond: 0,
        error: error is FileSystemException
            ? error.message
            : 'Could not prepare storage. Check free space and folder permissions.',
      );
      await _sendFileResponse(
        destinationPeerId: pending.originPeerId,
        transferId: transferId,
        accepted: false,
        isStream: pending.isStream,
        reason: 'storage_unavailable',
      );
    }
  }

  Future<void> rejectIncomingFile(String transferId) async {
    final pending = _pendingIncomingTransfers.remove(transferId);
    if (pending == null) return;
    _updateTransferMessage(
      conversationKind: pending.conversationKind,
      conversationId: pending.conversationId,
      messageId: pending.messageId,
      transferStatus: TransferStatus.rejected,
      error: 'File rejected',
    );
    await _sendFileResponse(
      destinationPeerId: pending.originPeerId,
      transferId: transferId,
      accepted: false,
      isStream: pending.isStream,
      reason: 'rejected',
    );
  }

  bool _shouldAutoAcceptIncomingFile(_PendingIncomingTransfer pending) {
    _clearExpiredAutoAcceptRules();
    final expiresAt =
        _autoAcceptIncomingFilesUntil[_incomingFileBatchKey(pending)];
    return expiresAt != null && expiresAt.isAfter(DateTime.now());
  }

  void _clearExpiredAutoAcceptRules() {
    final now = DateTime.now();
    _autoAcceptIncomingFilesUntil.removeWhere(
      (_, expiresAt) => !expiresAt.isAfter(now),
    );
  }

  String _incomingFileBatchKey(_PendingIncomingTransfer pending) {
    return [
      pending.conversationKind.name,
      pending.conversationId,
      pending.originPeerId,
    ].join('|');
  }

  Future<void> _sendFileControl({
    required ConversationKind kind,
    required String conversationId,
    required List<String> recipients,
    required String controlKind,
    required String transferId,
  }) {
    final payload = {
      'kind': controlKind,
      'conversationType': kind.name,
      if (kind != ConversationKind.peer) 'conversationId': conversationId,
      'transferId': transferId,
      'timestamp': DateTime.now().toIso8601String(),
    };

    return _sendPlainPayloadToRecipients(
      recipients: recipients,
      allowUnapprovedDestinations: true,
      payloadBuilder: (_) => payload,
    );
  }

  Future<void> pauseTransfer(String transferId) async {
    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null && !outgoing.stopped) {
      if (outgoing.isStream) return;
      outgoing.pause();
      _updateOutgoingTransferStatus(outgoing, TransferStatus.paused);
      await _sendFileControl(
        kind: outgoing.conversationKind,
        conversationId: outgoing.conversationId,
        recipients: outgoing.acceptedRecipients.toList(growable: false),
        controlKind: outgoing.isStream ? 'stream_pause' : 'file_pause',
        transferId: transferId,
      );
      return;
    }

    final incoming = _incomingTransfers[transferId];
    if (incoming == null || incoming.canceled) return;
    incoming.pause();
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus: TransferStatus.paused,
      transferSpeedBytesPerSecond: 0,
    );
    await _sendFileControl(
      kind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      recipients: [incoming.originPeerId],
      controlKind: incoming.isStream ? 'stream_pause' : 'file_pause',
      transferId: transferId,
    );
  }

  Future<void> resumeTransfer(String transferId) async {
    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null && !outgoing.stopped) {
      if (outgoing.isStream) return;
      outgoing.resume();
      _updateOutgoingTransferStatus(
        outgoing,
        outgoing.paused ? TransferStatus.paused : TransferStatus.sending,
      );
      await _sendFileControl(
        kind: outgoing.conversationKind,
        conversationId: outgoing.conversationId,
        recipients: outgoing.acceptedRecipients.toList(growable: false),
        controlKind: outgoing.isStream ? 'stream_resume' : 'file_resume',
        transferId: transferId,
      );
      return;
    }

    final incoming = _incomingTransfers[transferId];
    if (incoming == null || incoming.canceled) return;
    incoming.resume();
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus:
          incoming.paused ? TransferStatus.paused : TransferStatus.receiving,
      transferSpeedBytesPerSecond: 0,
    );
    await _sendFileControl(
      kind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      recipients: [incoming.originPeerId],
      controlKind: incoming.isStream ? 'stream_resume' : 'file_resume',
      transferId: transferId,
    );
  }

  Future<void> cancelTransfer(String transferId) async {
    final outgoing = _outgoingTransfers.remove(transferId);
    if (outgoing != null) {
      outgoing.cancel();
      await _sendPlainPayloadToRecipients(
        recipients: outgoing.allRecipients.toList(growable: false),
        allowUnapprovedDestinations: true,
        payloadBuilder: (_) => {
          'kind': outgoing.isStream ? 'stream_cancel' : 'file_cancel',
          'conversationType': outgoing.conversationKind.name,
          if (outgoing.conversationKind != ConversationKind.peer)
            'conversationId': outgoing.conversationId,
          'transferId': transferId,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
      _updateOutgoingTransferStatus(
        outgoing,
        TransferStatus.canceled,
        error: 'Transfer canceled',
      );
      await outgoing.disposeTemporarySource();
      return;
    }

    final pending = _pendingIncomingTransfers[transferId];
    if (pending != null) {
      await rejectIncomingFile(transferId);
      return;
    }

    final incoming = _incomingTransfers.remove(transferId);
    if (incoming == null) return;
    await incoming.disposeWithFailure('Receiver canceled');
    await _sendPlainPayloadToRecipients(
      recipients: [incoming.originPeerId],
      allowUnapprovedDestinations: true,
      payloadBuilder: (_) => {
        'kind': incoming.isStream ? 'stream_cancel' : 'file_cancel',
        'conversationType': incoming.conversationKind.name,
        if (incoming.conversationKind != ConversationKind.peer)
          'conversationId': incoming.conversationId,
        'transferId': transferId,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus: TransferStatus.canceled,
      transferSpeedBytesPerSecond: 0,
      error: 'Transfer canceled',
    );
  }

  Future<void> _handleFilePausePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null && outgoing.acceptedRecipients.contains(originId)) {
      outgoing.pauseBy(originId);
      _updateOutgoingTransferStatus(outgoing, TransferStatus.paused);
      return;
    }

    final incoming = _incomingTransfers[transferId];
    if (incoming == null || incoming.originPeerId != originId) return;
    incoming.pause(remote: true);
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus: TransferStatus.paused,
      transferSpeedBytesPerSecond: 0,
    );
  }

  Future<void> _handleFileResumePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null && outgoing.acceptedRecipients.contains(originId)) {
      outgoing.resumeBy(originId);
      _updateOutgoingTransferStatus(
        outgoing,
        outgoing.paused ? TransferStatus.paused : TransferStatus.sending,
      );
      return;
    }

    final incoming = _incomingTransfers[transferId];
    if (incoming == null || incoming.originPeerId != originId) return;
    incoming.resume(remote: true);
    _updateTransferMessage(
      conversationKind: incoming.conversationKind,
      conversationId: incoming.conversationId,
      messageId: incoming.messageId,
      transferStatus:
          incoming.paused ? TransferStatus.paused : TransferStatus.receiving,
      transferSpeedBytesPerSecond: 0,
    );
  }

  Future<void> _sendFileResponse({
    required String destinationPeerId,
    required String transferId,
    required bool accepted,
    bool isStream = false,
    String? reason,
  }) {
    return _sendPacket(
      destinationPeerId: destinationPeerId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': isStream ? 'stream_response' : 'file_response',
        'transferId': transferId,
        'accepted': accepted,
        if (reason != null) 'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<void> _sendFileChunkAck({
    required String destinationPeerId,
    required String transferId,
    required int chunkIndex,
    required int receivedBytes,
    bool isStream = false,
    bool success = true,
    String? reason,
  }) {
    return _sendPacket(
      destinationPeerId: destinationPeerId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': isStream ? 'stream_chunk_ack' : 'file_chunk_ack',
        'transferId': transferId,
        'chunkIndex': chunkIndex,
        'receivedBytes': receivedBytes,
        'success': success,
        if (reason != null) 'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<void> _sendFileCompleteAck({
    required String destinationPeerId,
    required String transferId,
    required int receivedBytes,
    bool isStream = false,
    bool success = true,
    String? reason,
  }) {
    return _sendPacket(
      destinationPeerId: destinationPeerId,
      allowUnapprovedDestination: true,
      payload: {
        'kind': isStream ? 'stream_complete' : 'file_complete',
        'transferId': transferId,
        'receivedBytes': receivedBytes,
        'success': success,
        if (reason != null) 'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  void _updateOutgoingTransferStatus(
    _OutgoingTransfer outgoing,
    TransferStatus status, {
    String? error,
  }) {
    _updateTransferMessage(
      conversationKind: outgoing.conversationKind,
      conversationId: outgoing.conversationId,
      messageId: outgoing.messageId,
      transferStatus: status,
      transferSpeedBytesPerSecond: 0,
      error: error,
    );
  }

  void _updateTransferMessage({
    required ConversationKind conversationKind,
    required String conversationId,
    required String messageId,
    TransferStatus? transferStatus,
    double? transferProgress,
    double? transferSpeedBytesPerSecond,
    Object? localPath = _unset,
    String? error,
  }) {
    _updateFileMessage(
      conversationKind: conversationKind,
      conversationId: conversationId,
      messageId: messageId,
      localPath: localPath,
      transferStatus: transferStatus,
      transferProgress: transferProgress,
      transferSpeedBytesPerSecond: transferSpeedBytesPerSecond,
      error: error,
    );
  }

  void _handleFileChunkAckPayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) {
    final transferId = (payload['transferId'] ?? '').toString();
    final chunkIndex = _intFrom(payload['chunkIndex']);
    final receivedBytes = _intFrom(payload['receivedBytes']);
    if (transferId.isEmpty) return;

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing == null || !outgoing.acceptedRecipients.contains(originId)) {
      return;
    }

    if (payload['success'] == false) {
      outgoing.fail((payload['reason'] ?? 'Receiver failed').toString());
      _updateOutgoingTransferStatus(
        outgoing,
        TransferStatus.failed,
        error: outgoing.failureReason,
      );
      return;
    }

    outgoing.markChunkAck(
      peerId: originId,
      chunkIndex: chunkIndex,
      receivedBytes: receivedBytes,
    );
  }

  void _handleFileCompletePayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;

    final outgoing = _outgoingTransfers[transferId];
    if (outgoing == null || !outgoing.acceptedRecipients.contains(originId)) {
      return;
    }

    if (payload['success'] == false) {
      outgoing.fail((payload['reason'] ?? 'Receiver failed').toString());
      _updateOutgoingTransferStatus(
        outgoing,
        TransferStatus.failed,
        error: outgoing.failureReason,
      );
      return;
    }

    outgoing.markCompleteAck(originId);
  }

  Future<void> _handleFileChunkPayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    final encoded = (payload['data'] ?? '').toString();
    if (transferId.isEmpty || encoded.isEmpty) return;

    final transfer = _incomingTransfers[transferId];
    if (transfer == null || transfer.originPeerId != originId) return;

    final chunkIndex = _intFrom(payload['chunkIndex']);
    final offset = _intFrom(payload['offset']);
    final byteCount = _intFrom(payload['byteCount']);

    try {
      if (!transfer.isStream && offset != transfer.receivedBytes) {
        if (offset < transfer.receivedBytes) {
          await _sendFileChunkAck(
            destinationPeerId: transfer.originPeerId,
            transferId: transfer.transferId,
            chunkIndex: chunkIndex,
            receivedBytes: transfer.receivedBytes,
            isStream: transfer.isStream,
          );
          return;
        }
        throw StateError(
          'Unexpected file offset $offset, expected ${transfer.receivedBytes}',
        );
      }

      final bytes = base64Decode(encoded);
      if (byteCount > 0 && bytes.length != byteCount) {
        throw StateError(
          'Unexpected chunk length ${bytes.length}, expected $byteCount',
        );
      }
      if (offset < 0 || offset + bytes.length > transfer.fileSize) {
        throw StateError('Incoming file exceeded expected size');
      }

      await transfer.writeChunk(offset: offset, bytes: bytes);
      if (transfer.isStream || transfer.shouldFlushAfterChunk()) {
        await transfer.writer.flush();
      }
      transfer.streamSession
          ?.updateBufferedRange(offset, offset + bytes.length);

      await _sendFileChunkAck(
        destinationPeerId: transfer.originPeerId,
        transferId: transfer.transferId,
        chunkIndex: chunkIndex,
        receivedBytes: transfer.receivedBytes,
        isStream: transfer.isStream,
      );
    } catch (error) {
      debugPrint('Failed to receive file chunk: $error');
      await _sendFileChunkAck(
        destinationPeerId: transfer.originPeerId,
        transferId: transfer.transferId,
        chunkIndex: chunkIndex,
        receivedBytes: transfer.receivedBytes,
        isStream: transfer.isStream,
        success: false,
        reason: 'Receive failed',
      );
      _incomingTransfers.remove(transferId);
      await transfer.disposeWithFailure('Receive failed');
      _updateFileMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        transferStatus: TransferStatus.failed,
        transferSpeedBytesPerSecond: 0,
        error: 'Receive failed',
      );
      return;
    }

    if (transfer.isStream ||
        transfer.tracker
            .shouldEmit(transfer.receivedBytes, transfer.fileSize)) {
      _updateFileMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        localPath: transfer.isStream
            ? transfer.streamSession?.playbackUrl ?? transfer.tempPath
            : _unset,
        transferProgress: _progress(transfer.receivedBytes, transfer.fileSize),
        transferSpeedBytesPerSecond:
            transfer.tracker.speed(transfer.receivedBytes),
      );
    }
  }

  Future<void> _handleFileEndPayload({
    required Map<String, dynamic> payload,
    required String originId,
  }) async {
    final transferId = (payload['transferId'] ?? '').toString();
    if (transferId.isEmpty) return;

    final transfer = _incomingTransfers[transferId];
    if (transfer == null || transfer.originPeerId != originId) return;
    _incomingTransfers.remove(transferId);

    try {
      if (transfer.receivedBytes != transfer.fileSize) {
        throw StateError(
          'Incomplete file: ${transfer.receivedBytes}/${transfer.fileSize}',
        );
      }
      await transfer.writer.flush();
      await transfer.writer.close();
      final savedPath = transfer.isStreamOnly
          ? await _completeTemporaryStream(transfer)
          : await _publishCompletedIncomingFile(transfer);
      _updateFileMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        localPath: savedPath,
        transferStatus: TransferStatus.saved,
        transferProgress: 1,
        transferSpeedBytesPerSecond: 0,
      );
      await _sendFileCompleteAck(
        destinationPeerId: transfer.originPeerId,
        transferId: transfer.transferId,
        receivedBytes: transfer.receivedBytes,
        isStream: transfer.isStream,
      );
    } catch (error) {
      debugPrint('Failed to save incoming file: $error');
      await _sendFileCompleteAck(
        destinationPeerId: transfer.originPeerId,
        transferId: transfer.transferId,
        receivedBytes: transfer.receivedBytes,
        isStream: transfer.isStream,
        success: false,
        reason: 'Save failed',
      );
      await transfer.disposeWithFailure('Save failed');
      _updateFileMessage(
        conversationKind: transfer.conversationKind,
        conversationId: transfer.conversationId,
        messageId: transfer.messageId,
        transferStatus: TransferStatus.failed,
        transferSpeedBytesPerSecond: 0,
        error: 'Save failed',
      );
    }
  }

  Future<void> _handleCanvasStrokePayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
    required String? viaPeerName,
  }) async {
    final conversationKind =
        _conversationKindFrom(payload['conversationType']?.toString());
    final conversationId = _incomingConversationId(
        conversationKind, payload['conversationId'], originId);
    if (conversationKind == ConversationKind.group &&
        !_conversationAllowsSender(
            conversationKind, conversationId, originId)) {
      return;
    }
    if (!await _featureAllowed(
      canvasDrawingGuard,
      conversationKind,
      conversationId,
    )) {
      debugPrint(
        'Blocked incoming canvas event for ${conversationKind.name}::$conversationId',
      );
      return;
    }

    final strokeMap = _mapFrom(payload['stroke']);
    if (strokeMap == null) return;
    final event = CanvasEvent(
      eventId: (payload['eventId'] ?? _nextOpaqueId('canvas')).toString(),
      conversationId: conversationId,
      conversationKind: conversationKind,
      type: 'stroke',
      fromId: originId,
      fromName: originName,
      timestamp: _parseTimestamp(payload['timestamp']),
      viaPeerName: viaPeerName,
      stroke: CanvasStroke.fromJson(strokeMap),
    );
    _appendCanvasEvent(
        _conversationKey(conversationKind, conversationId), event);
  }

  Future<void> _handleCanvasClearPayload({
    required Map<String, dynamic> payload,
    required String originId,
    required String originName,
    required String? viaPeerName,
  }) async {
    final conversationKind =
        _conversationKindFrom(payload['conversationType']?.toString());
    final conversationId = _incomingConversationId(
        conversationKind, payload['conversationId'], originId);
    if (conversationKind == ConversationKind.group &&
        !_conversationAllowsSender(
            conversationKind, conversationId, originId)) {
      return;
    }
    if (!await _featureAllowed(
      canvasDrawingGuard,
      conversationKind,
      conversationId,
    )) {
      debugPrint(
        'Blocked incoming canvas clear for ${conversationKind.name}::$conversationId',
      );
      return;
    }

    final event = CanvasEvent(
      eventId: (payload['eventId'] ?? _nextOpaqueId('canvas')).toString(),
      conversationId: conversationId,
      conversationKind: conversationKind,
      type: 'clear',
      fromId: originId,
      fromName: originName,
      timestamp: _parseTimestamp(payload['timestamp']),
      viaPeerName: viaPeerName,
    );
    _appendCanvasEvent(
        _conversationKey(conversationKind, conversationId), event);
  }

  Future<bool> _sendCanvasStroke({
    required ConversationKind kind,
    required String conversationId,
    required List<String> recipients,
    required CanvasStroke stroke,
    Map<String, String?> directPeerIps = const {},
    bool allowUnapprovedDestinations = false,
    String? conversationName,
  }) async {
    final event = CanvasEvent(
      eventId: _nextOpaqueId('canvas'),
      conversationId: conversationId,
      conversationKind: kind,
      type: 'stroke',
      fromId: myId,
      fromName: myName,
      timestamp: DateTime.now(),
      stroke: stroke,
    );
    _appendCanvasEvent(_conversationKey(kind, conversationId), event);

    if (recipients.isEmpty) return true;

    return _sendPlainPayloadToRecipients(
      recipients: recipients,
      directPeerIps: directPeerIps,
      allowUnapprovedDestinations: allowUnapprovedDestinations,
      payloadBuilder: (_) => {
        'kind': 'canvas_stroke',
        'conversationType': kind.name,
        if (kind != ConversationKind.peer) 'conversationId': conversationId,
        if (conversationName != null) 'conversationName': conversationName,
        'eventId': event.eventId,
        'timestamp': event.timestamp.toIso8601String(),
        'stroke': stroke.toJson(),
      },
    );
  }

  Future<bool> _sendCanvasClear({
    required ConversationKind kind,
    required String conversationId,
    required List<String> recipients,
    Map<String, String?> directPeerIps = const {},
    bool allowUnapprovedDestinations = false,
    String? conversationName,
  }) async {
    final event = CanvasEvent(
      eventId: _nextOpaqueId('canvas'),
      conversationId: conversationId,
      conversationKind: kind,
      type: 'clear',
      fromId: myId,
      fromName: myName,
      timestamp: DateTime.now(),
    );
    _appendCanvasEvent(_conversationKey(kind, conversationId), event);

    if (recipients.isEmpty) return true;

    return _sendPlainPayloadToRecipients(
      recipients: recipients,
      directPeerIps: directPeerIps,
      allowUnapprovedDestinations: allowUnapprovedDestinations,
      payloadBuilder: (_) => {
        'kind': 'canvas_clear',
        'conversationType': kind.name,
        if (kind != ConversationKind.peer) 'conversationId': conversationId,
        if (conversationName != null) 'conversationName': conversationName,
        'eventId': event.eventId,
        'timestamp': event.timestamp.toIso8601String(),
      },
    );
  }

  Future<bool> _sendFileToConversation({
    required ConversationKind kind,
    required String conversationId,
    required List<String> recipients,
    required String filePath,
    required String fileName,
    Map<String, String?> directPeerIps = const {},
    bool allowUnapprovedDestinations = false,
    String? conversationName,
  }) async {
    final file = File(filePath);
    int fileSize;
    try {
      if (!await file.exists()) {
        return false;
      }
      fileSize = await file.length();
    } catch (error) {
      debugPrint('Could not prepare file "$filePath" for sending: $error');
      return false;
    }

    final uniqueRecipients = recipients
        .where((recipientId) => recipientId != myId)
        .toSet()
        .toList(growable: false);
    final timestamp = DateTime.now();
    final messageId = _nextMessageId();
    final transferId = _nextOpaqueId('file');
    final conversationKey = _conversationKey(kind, conversationId);

    var optimistic = ChatMessage(
      messageId: messageId,
      conversationId: conversationId,
      conversationKind: kind,
      text: '[File] $fileName',
      fromName: myName,
      fromId: myId,
      timestamp: timestamp,
      isMe: true,
      isFile: true,
      transferId: transferId,
      fileName: fileName,
      localPath: filePath,
      fileSize: fileSize,
      transferStatus: uniqueRecipients.isEmpty
          ? TransferStatus.sent
          : TransferStatus.pending,
      transferProgress: uniqueRecipients.isEmpty ? 1 : 0,
    );
    _upsertAndNotify(conversationKey, optimistic);

    if (uniqueRecipients.isEmpty) return true;

    final outgoing = _OutgoingTransfer(
      transferId: transferId,
      conversationKind: kind,
      conversationId: conversationId,
      messageId: messageId,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      recipients: uniqueRecipients,
      directPeerIps: directPeerIps,
      allowUnapprovedDestinations: allowUnapprovedDestinations,
      conversationName: conversationName,
      isStream: false,
    );
    _outgoingTransfers[transferId] = outgoing;

    for (final recipientId in uniqueRecipients) {
      final delivered = await _sendTransferPayloadToRecipients(
        outgoing,
        [recipientId],
        _transferOfferPayload(outgoing, timestamp),
      );
      if (!delivered) {
        outgoing.markRejected(recipientId);
      }
    }
    outgoing.completeIfSettled();

    final hasAccepted = await outgoing.waitForAcceptances();
    if (outgoing.stopped ||
        !hasAccepted ||
        outgoing.acceptedRecipients.isEmpty) {
      final status = outgoing.canceled
          ? TransferStatus.canceled
          : outgoing.failed
              ? TransferStatus.failed
              : TransferStatus.rejected;
      optimistic = optimistic.copyWith(
        transferStatus: status,
        error: outgoing.canceled
            ? 'Transfer canceled'
            : outgoing.failureReason ?? 'File rejected',
      );
      _upsertAndNotify(conversationKey, optimistic);
      _outgoingTransfers.remove(transferId);
      unawaited(outgoing.disposeTemporarySource());
      return false;
    }

    return _runOutgoingTransfer(outgoing);
  }

  Future<bool> _shareStreamToConversation({
    required ConversationKind kind,
    required String conversationId,
    required List<String> recipients,
    required String filePath,
    required String fileName,
    Map<String, String?> directPeerIps = const {},
    bool allowUnapprovedDestinations = false,
    String? conversationName,
    required StreamTransferMode streamMode,
    bool deleteSourceOnComplete = false,
  }) async {
    final file = File(filePath);
    int fileSize;
    try {
      if (!await file.exists()) {
        return false;
      }
      fileSize = await file.length();
    } catch (error) {
      debugPrint('Could not prepare video "$filePath" for sharing: $error');
      return false;
    }

    final uniqueRecipients = recipients
        .where((recipientId) => recipientId != myId)
        .toSet()
        .toList(growable: false);
    final timestamp = DateTime.now();
    final messageId = _nextMessageId();
    final transferId = _nextOpaqueId('stream');
    final conversationKey = _conversationKey(kind, conversationId);

    var optimistic = ChatMessage(
      messageId: messageId,
      conversationId: conversationId,
      conversationKind: kind,
      text: '[Video] $fileName',
      fromName: myName,
      fromId: myId,
      timestamp: timestamp,
      isMe: true,
      isFile: true,
      isStream: true,
      streamSavesFile: streamMode == StreamTransferMode.streamAndSend,
      transferId: transferId,
      fileName: fileName,
      localPath: filePath,
      fileSize: fileSize,
      transferStatus: uniqueRecipients.isEmpty
          ? TransferStatus.sent
          : TransferStatus.pending,
      transferProgress: uniqueRecipients.isEmpty ? 1 : 0,
    );
    _upsertAndNotify(conversationKey, optimistic);

    if (uniqueRecipients.isEmpty) return true;

    final outgoing = _OutgoingTransfer(
      transferId: transferId,
      conversationKind: kind,
      conversationId: conversationId,
      messageId: messageId,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      recipients: uniqueRecipients,
      directPeerIps: directPeerIps,
      allowUnapprovedDestinations: allowUnapprovedDestinations,
      conversationName: conversationName,
      isStream: true,
      streamMode: streamMode,
      deleteSourceOnComplete: deleteSourceOnComplete,
    );
    _outgoingTransfers[transferId] = outgoing;

    var deliveredToAnyReceiver = false;
    for (final recipientId in uniqueRecipients) {
      final delivered = await _sendTransferPayloadToRecipients(
        outgoing,
        [recipientId],
        _transferOfferPayload(outgoing, timestamp),
      );
      if (delivered) {
        deliveredToAnyReceiver = true;
      } else {
        outgoing.markRejected(recipientId);
      }
    }

    if (!deliveredToAnyReceiver) {
      optimistic = optimistic.copyWith(
        transferStatus: TransferStatus.failed,
        error: 'Could not share video',
      );
      _upsertAndNotify(conversationKey, optimistic);
      _outgoingTransfers.remove(transferId);
      unawaited(outgoing.disposeTemporarySource());
      return false;
    }

    return true;
  }

  Map<String, dynamic> _transferOfferPayload(
    _OutgoingTransfer outgoing,
    DateTime timestamp,
  ) {
    return {
      'kind': outgoing.isStream ? 'stream_offer' : 'file_offer',
      'conversationType': outgoing.conversationKind.name,
      if (outgoing.conversationKind != ConversationKind.peer)
        'conversationId': outgoing.conversationId,
      if (outgoing.conversationName != null)
        'conversationName': outgoing.conversationName,
      'messageId': outgoing.messageId,
      'transferId': outgoing.transferId,
      'fileName': outgoing.fileName,
      'fileSize': outgoing.fileSize,
      if (outgoing.isStream) 'streamMode': outgoing.streamMode.name,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  Future<bool> _sendTransferPayloadToRecipients(
    _OutgoingTransfer outgoing,
    Iterable<String> targetRecipients,
    Map<String, dynamic> payload,
  ) async {
    final targets = targetRecipients.toList(growable: false);
    if (targets.isEmpty || outgoing.stopped) return false;

    var deliveredAny = false;
    for (final recipientId in targets.toSet()) {
      if (recipientId == myId || outgoing.stopped) continue;
      final delivered = await _sendPacket(
        destinationPeerId: recipientId,
        directPeerIp: outgoing.directPeerIps[recipientId],
        allowUnapprovedDestination: outgoing.allowUnapprovedDestinations,
        payload: payload,
      );
      if (delivered) {
        deliveredAny = true;
        continue;
      }

      debugPrint(
        'Transfer ${outgoing.transferId} dropping unreachable recipient $recipientId',
      );
      outgoing.markRejected(recipientId);
    }
    return deliveredAny;
  }

  void _scheduleSharedStreamStart(_OutgoingTransfer outgoing) {
    if (!outgoing.isStream ||
        outgoing.transferTask != null ||
        outgoing.transferStarted ||
        outgoing.stopped) {
      return;
    }

    final task = () async {
      await Future<void>.delayed(_streamReceiverJoinDelay);
      if (outgoing.stopped || outgoing.acceptedRecipients.isEmpty) return;
      await _runOutgoingTransfer(outgoing);
    }();
    outgoing.transferTask = task;
    unawaited(task);
  }

  Future<void> _cancelLateStreamRequest(
    _OutgoingTransfer outgoing,
    String receiverId,
  ) {
    return _notifyOutgoingTransferCanceled(
      outgoing,
      recipients: [receiverId],
      reason: 'stream_already_active',
    );
  }

  Future<void> _notifyOutgoingTransferCanceled(
    _OutgoingTransfer outgoing, {
    required Iterable<String> recipients,
    required String reason,
  }) async {
    final targets = recipients.toList(growable: false);
    if (targets.isEmpty) return;
    await _sendPlainPayloadToRecipients(
      recipients: targets,
      directPeerIps: outgoing.directPeerIps,
      allowUnapprovedDestinations: true,
      payloadBuilder: (_) => {
        'kind': outgoing.isStream ? 'stream_cancel' : 'file_cancel',
        'conversationType': outgoing.conversationKind.name,
        if (outgoing.conversationKind != ConversationKind.peer)
          'conversationId': outgoing.conversationId,
        'transferId': outgoing.transferId,
        'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<bool> _runOutgoingTransfer(_OutgoingTransfer outgoing) async {
    final file = File(outgoing.filePath);
    final conversationKey = _conversationKey(
      outgoing.conversationKind,
      outgoing.conversationId,
    );
    final initialMessage = _findMessage(conversationKey, outgoing.messageId);
    if (initialMessage == null || !await file.exists()) {
      outgoing.fail('File is no longer available');
      await _notifyOutgoingTransferCanceled(
        outgoing,
        recipients: outgoing.acceptedRecipients,
        reason: 'file_unavailable',
      );
      _updateOutgoingTransferStatus(
        outgoing,
        TransferStatus.failed,
        error: outgoing.failureReason,
      );
      _outgoingTransfers.remove(outgoing.transferId);
      unawaited(outgoing.disposeTemporarySource());
      return false;
    }

    var success = true;
    var optimistic = initialMessage.copyWith(
      transferStatus: TransferStatus.sending,
      transferProgress: outgoing.fileSize == 0 ? 1 : 0,
      transferSpeedBytesPerSecond: 0,
      error: null,
    );
    outgoing.transferStarted = true;
    _upsertAndNotify(conversationKey, optimistic);

    var chunkIndex = 0;
    final pendingChunkAcks = <int>[];
    final chunkBytes = outgoing.isStream ? _streamChunkBytes : _fileChunkBytes;
    final ackWindow = outgoing.isStream ? _streamAckWindowChunks : 1;
    final tracker = _ProgressTracker();
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      Future<int?> sendChunkAt(int offset, int maxBytes) async {
        await outgoing.waitWhilePaused();
        if (outgoing.stopped) {
          return null;
        }

        final targets = outgoing.acceptedRecipients.toList(growable: false);
        if (targets.isEmpty) {
          return null;
        }

        final readSize = math.min(maxBytes, outgoing.fileSize - offset);
        await reader!.setPosition(offset);
        final chunk = await reader.read(readSize);
        if (chunk.isEmpty) {
          outgoing.fail('File read ended early');
          return null;
        }

        final currentChunkIndex = chunkIndex++;
        outgoing.expectChunkAck(
          chunkIndex: currentChunkIndex,
          recipients: targets,
        );
        pendingChunkAcks.add(currentChunkIndex);
        final delivered = await _sendTransferPayloadToRecipients(
          outgoing,
          targets,
          {
            'kind': outgoing.isStream ? 'stream_chunk' : 'file_chunk',
            'conversationType': outgoing.conversationKind.name,
            if (outgoing.conversationKind != ConversationKind.peer)
              'conversationId': outgoing.conversationId,
            'transferId': outgoing.transferId,
            'chunkIndex': currentChunkIndex,
            'offset': offset,
            'byteCount': chunk.length,
            'data': base64Encode(chunk),
          },
        );
        if (!delivered) {
          outgoing.fail('Send failed');
          return null;
        }

        return chunk.length;
      }

      Future<bool> drainAcksAndReportProgress() async {
        final acknowledged =
            await _drainOutgoingChunkAcks(outgoing, pendingChunkAcks);
        if (!acknowledged || outgoing.stopped) {
          return false;
        }

        final ackedBytes = outgoing.acknowledgedBytes;
        if (tracker.shouldEmit(ackedBytes, outgoing.fileSize)) {
          optimistic = optimistic.copyWith(
            transferProgress: _progress(ackedBytes, outgoing.fileSize),
            transferSpeedBytesPerSecond: tracker.speed(ackedBytes),
          );
          _upsertAndNotify(conversationKey, optimistic);
        }
        return true;
      }

      final sequentialLimit = outgoing.isStream
          ? _streamSequentialLimit(outgoing.fileSize)
          : outgoing.fileSize;

      if (outgoing.isStream && sequentialLimit < outgoing.fileSize) {
        var metadataOffset = sequentialLimit;
        while (metadataOffset < outgoing.fileSize) {
          final chunkLength = await sendChunkAt(metadataOffset, chunkBytes);
          if (chunkLength == null) {
            success = false;
            break;
          }
          metadataOffset += chunkLength;
          if (pendingChunkAcks.length >= ackWindow ||
              metadataOffset >= outgoing.fileSize) {
            final acknowledged = await drainAcksAndReportProgress();
            if (!acknowledged) {
              success = false;
              break;
            }
          }
        }
      }

      var sent = 0;
      while (success && sent < sequentialLimit) {
        final chunkLength = await sendChunkAt(sent, chunkBytes);
        if (chunkLength == null) {
          success = false;
          break;
        }

        sent += chunkLength;
        final shouldDrainAcks =
            pendingChunkAcks.length >= ackWindow || sent >= sequentialLimit;
        if (shouldDrainAcks) {
          final acknowledged = await drainAcksAndReportProgress();
          if (!acknowledged) {
            success = false;
            break;
          }
        }
      }
    } catch (error) {
      debugPrint('Outgoing file transfer failed: $error');
      success = false;
      if (!outgoing.stopped) {
        outgoing.fail('Send failed');
      }
    } finally {
      try {
        await reader?.close();
      } catch (error) {
        debugPrint('Could not close outgoing file reader: $error');
      }
    }

    if (success && pendingChunkAcks.isNotEmpty) {
      success = await _drainOutgoingChunkAcks(outgoing, pendingChunkAcks);
    }

    if (success && !outgoing.stopped) {
      final targets = outgoing.acceptedRecipients.toList(growable: false);
      outgoing.expectCompleteAck(targets);
      success = await _sendTransferPayloadToRecipients(
        outgoing,
        targets,
        {
          'kind': outgoing.isStream ? 'stream_end' : 'file_end',
          'conversationType': outgoing.conversationKind.name,
          if (outgoing.conversationKind != ConversationKind.peer)
            'conversationId': outgoing.conversationId,
          'transferId': outgoing.transferId,
        },
      );
      if (success) {
        success = await outgoing.waitForCompleteAck();
      }
    }

    if ((!success || outgoing.failed) && !outgoing.canceled) {
      await _notifyOutgoingTransferCanceled(
        outgoing,
        recipients: outgoing.acceptedRecipients,
        reason: outgoing.failureReason ?? 'send_failed',
      );
    }

    optimistic = optimistic.copyWith(
      transferStatus: outgoing.canceled
          ? TransferStatus.canceled
          : success && !outgoing.failed
              ? TransferStatus.sent
              : TransferStatus.failed,
      transferProgress:
          success && !outgoing.failed ? 1 : optimistic.transferProgress,
      transferSpeedBytesPerSecond: 0,
      error: success && !outgoing.failed
          ? null
          : outgoing.canceled
              ? 'Transfer canceled'
              : outgoing.failureReason ?? 'Send failed',
    );
    _upsertAndNotify(conversationKey, optimistic);
    _outgoingTransfers.remove(outgoing.transferId);
    unawaited(outgoing.disposeTemporarySource());

    return success && !outgoing.failed && !outgoing.canceled;
  }

  Future<bool> _drainOutgoingChunkAcks(
    _OutgoingTransfer outgoing,
    List<int> pendingChunkAcks,
  ) async {
    while (pendingChunkAcks.isNotEmpty) {
      final pendingChunkIndex = pendingChunkAcks.removeAt(0);
      final acknowledged = await outgoing.waitForChunkAck(pendingChunkIndex);
      if (!acknowledged || outgoing.stopped) {
        pendingChunkAcks.clear();
        return false;
      }
    }
    return true;
  }

  Future<bool> _sendPlainPayloadToRecipients({
    required List<String> recipients,
    Map<String, String?> directPeerIps = const {},
    bool allowUnapprovedDestinations = false,
    required Map<String, dynamic> Function(String recipientId) payloadBuilder,
  }) async {
    var success = true;
    final uniqueRecipients = recipients.toSet().toList(growable: false);
    for (final recipientId in uniqueRecipients) {
      if (recipientId == myId) continue;
      try {
        final delivered = await _sendPacket(
          destinationPeerId: recipientId,
          directPeerIp: directPeerIps[recipientId],
          allowUnapprovedDestination: allowUnapprovedDestinations,
          payload: payloadBuilder(recipientId),
        );
        success = success && delivered;
      } catch (error) {
        debugPrint('Payload send failed for $recipientId: $error');
        success = false;
      }
    }
    return success || uniqueRecipients.isEmpty;
  }

  Future<bool> _sendPacket({
    required String destinationPeerId,
    Map<String, dynamic> payload = const {},
    String? directPeerIp,
    bool allowUnapprovedDestination = false,
  }) async {
    if (destinationPeerId.isEmpty || destinationPeerId == myId) {
      return false;
    }
    if (!allowUnapprovedDestination && !canMessage(destinationPeerId)) {
      _lastTransportError =
          'Permission has not been granted for ${_displayName(destinationPeerId)}.';
      _emitChange();
      return false;
    }

    final protocolType = _protocolTypeForPayload(payload);
    final timestamp = DateTime.now();
    final messageId = _nextMessageId();
    final frame = _buildNetworkFrame(
      messageId: messageId,
      protocolType: protocolType,
      senderId: myId,
      senderName: myName,
      destinationId: destinationPeerId,
      timestamp: timestamp,
      payload: payload,
    );
    _markPacketSeen(messageId, logDuplicate: false);

    final addresses = _directAddressCandidates(destinationPeerId, directPeerIp);
    if (addresses.isEmpty && !_connections.containsKey(destinationPeerId)) {
      debugPrint(
        'No direct address to $destinationPeerId for $messageId',
      );
      _lastTransportError =
          'No direct IP is known for ${_displayName(destinationPeerId)}. Refresh discovery or connect manually.';
      _emitChange();
      return false;
    }

    Object? lastError;
    for (var attempt = 0; attempt < _packetSendAttempts; attempt += 1) {
      final peerIp = addresses.isEmpty
          ? null
          : addresses[math.min(attempt, addresses.length - 1)];
      try {
        await _sendDirectFrame(
          peerId: destinationPeerId,
          peerIp: peerIp,
          allowBeforePermission: true,
          frame: frame,
        );
        _lastTransportError = null;
        return true;
      } catch (error) {
        lastError = error;
        debugPrint(
          'Direct send attempt ${attempt + 1}/$_packetSendAttempts failed '
          'for $destinationPeerId: $error',
        );
        if (attempt + 1 < _packetSendAttempts) {
          await Future<void>.delayed(_sendRetryDelay);
        }
      }
    }

    _lastTransportError =
        'Could not reach ${_displayName(destinationPeerId)} directly: $lastError';
    _emitChange();
    return false;
  }

  bool _isNetworkMessageFrame(Map<String, dynamic> frame) {
    final hasMessageId =
        frame.containsKey('messageId') || frame.containsKey('packetId');
    final hasSender =
        frame.containsKey('senderId') || frame.containsKey('fromId');
    final hasDestination =
        frame.containsKey('destinationId') || frame.containsKey('toId');
    return hasMessageId && hasSender && hasDestination;
  }

  String _protocolTypeForFrame(
    Map<String, dynamic> frame,
    Map<String, dynamic>? payload,
  ) {
    final type = (frame['type'] ?? '').toString();
    if (type.isNotEmpty && type != 'packet') return type;
    return _protocolTypeForPayload(payload ?? const <String, dynamic>{});
  }

  String _protocolTypeForPayload(Map<String, dynamic> payload) {
    switch ((payload['kind'] ?? '').toString()) {
      case 'text':
      case 'chat_persistence':
      case 'canvas_stroke':
      case 'canvas_clear':
        return _protocolChatMessage;
      case 'file_offer':
        return _protocolFileOffer;
      case 'file_chunk':
        return _protocolFileChunk;
      case 'stream_offer':
        return _protocolStreamOffer;
      case 'stream_chunk':
        return _protocolStreamChunk;
      case 'file_end':
      case 'file_response':
      case 'file_cancel':
      case 'file_pause':
      case 'file_resume':
      case 'file_chunk_ack':
      case 'file_complete':
        return _protocolFileAck;
      case 'stream_end':
      case 'stream_response':
      case 'stream_cancel':
      case 'stream_pause':
      case 'stream_resume':
      case 'stream_chunk_ack':
      case 'stream_complete':
        return _protocolStreamAck;
      default:
        final kind = (payload['kind'] ?? '').toString();
        return kind.isEmpty ? 'MESSAGE' : kind.toUpperCase();
    }
  }

  Map<String, dynamic> _buildNetworkFrame({
    required String messageId,
    required String protocolType,
    required String senderId,
    required String senderName,
    required String destinationId,
    required DateTime timestamp,
    required Map<String, dynamic> payload,
  }) {
    return {
      'type': protocolType,
      'messageId': messageId,
      'packetId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'fromId': senderId,
      'fromName': senderName,
      'destinationId': destinationId,
      'toId': destinationId,
      'timestamp': timestamp.toIso8601String(),
      'payload': payload,
    };
  }

  Future<void> _sendDirectFrame({
    required String peerId,
    required Map<String, dynamic> frame,
    String? peerIp,
    bool allowBeforePermission = false,
  }) {
    return _enqueuePeerWrite(
      peerId: peerId,
      peerIp: peerIp,
      allowBeforePermission: allowBeforePermission,
      action: (socket) => _sendJson(socket, frame),
    );
  }

  Future<T> _enqueuePeerWrite<T>({
    required String peerId,
    required String? peerIp,
    required Future<T> Function(Socket socket) action,
    bool allowBeforePermission = false,
  }) {
    final previous = _writeQueues[peerId] ?? Future<void>.value();
    final completer = Completer<T>();

    late final Future<void> current;
    current = previous.catchError((_) {}).then((_) async {
      try {
        final socket = await _ensureConnection(
          peerId: peerId,
          peerIp: peerIp,
          allowBeforePermission: allowBeforePermission,
        );
        final result = await action(socket);
        if (!completer.isCompleted) completer.complete(result);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });

    _writeQueues[peerId] = current;
    unawaited(
      current.whenComplete(() {
        if (_writeQueues[peerId] == current) {
          _writeQueues.remove(peerId);
        }
      }),
    );

    return completer.future;
  }

  Future<Socket> _ensureConnection({
    required String peerId,
    required String? peerIp,
    int? peerPort,
    required bool allowBeforePermission,
  }) async {
    if (!allowBeforePermission && !canMessage(peerId)) {
      throw StateError('Permission has not been granted for $peerId');
    }

    final existing = _connections[peerId];
    if (existing != null) {
      final state = _socketStates[existing];
      try {
        if (state != null && !state.registerSent) {
          await _sendHello(existing, state).timeout(_sendFlushTimeout);
        }
        return existing;
      } catch (error) {
        debugPrint(
            'Existing TCP connection is not writable for $peerId: $error');
        if (_connections[peerId] == existing) {
          _connections.remove(peerId);
        }
        existing.destroy();
      }
    }

    final addresses = _directAddressCandidates(peerId, peerIp);
    if (addresses.isEmpty) {
      throw StateError('No direct IP known for $peerId');
    }

    final port = peerPort ?? _peerPorts[peerId] ?? messagingPort;
    Object? lastError;

    for (final address in addresses) {
      for (var attempt = 0; attempt < 2; attempt += 1) {
        debugPrint(
          'TCP connect attempt ${attempt + 1}/2: $peerId -> $address:$port',
        );
        try {
          final socket = await Socket.connect(
            address,
            port,
            timeout: const Duration(seconds: _socketTimeoutSeconds),
          );
          socket.setOption(SocketOption.tcpNoDelay, true);
          _listenOnSocket(socket, knownPeerId: peerId);
          final state = _socketStates[socket];
          if (state != null) {
            await _sendHello(socket, state).timeout(_sendFlushTimeout);
          }
          _lastTransportError = null;
          return socket;
        } catch (error) {
          lastError = error;
          debugPrint(
            'Direct peer connection failed: $peerId at $address:$port: $error',
          );
          if (attempt == 0) {
            await Future<void>.delayed(_sendRetryDelay);
          }
        }
      }
    }

    throw SocketException(
      'Could not connect directly to $peerId at ${addresses.join(', ')}:$port',
      osError: lastError is OSError ? lastError : null,
    );
  }

  Future<void> _sendHello(Socket socket, _SocketState state) async {
    await _sendRegister(socket, state);
  }

  void _bindSocketToPeer({
    required String peerId,
    required Socket socket,
    required _SocketState state,
  }) {
    final existing = _connections[peerId];
    state.peerId = peerId;
    if (state.manualRemotePort != null) {
      _peerPorts[peerId] = state.manualRemotePort!;
    }
    if (existing != null && existing != socket) {
      existing.destroy();
    }
    _connections[peerId] = socket;
  }

  void _markDirectVerified({
    required String peerId,
    required String? peerName,
    required String? peerIp,
    required int? peerPort,
    required Socket socket,
    required _SocketState state,
  }) {
    final now = DateTime.now();
    final previousIp = _peerIps[peerId];
    final previousDirectSeen = _directPeerLastSeen[peerId];
    _bindSocketToPeer(peerId: peerId, socket: socket, state: state);
    state.directVerified = true;
    _peerRegistryIds.add(peerId);
    if (peerIp != null && peerIp.isNotEmpty) {
      _peerIps[peerId] = peerIp;
    }
    if (peerName != null && peerName.isNotEmpty) {
      _peerNames[peerId] = peerName;
    }
    if (peerPort != null && peerPort > 0) {
      _peerPorts[peerId] = peerPort;
    }
    _peerLastSeen[peerId] = now;
    _directPeerLastSeen[peerId] = now;
    _lastDirectPeerSeenAt = now;
    _lastDirectPeerId = peerId;
    debugPrint(
      'Direct peer connected: ${_displayName(peerId)} ($peerId) at ${socket.remoteAddress.address}:${socket.remotePort}',
    );
    if (previousIp != null && previousIp.isNotEmpty && previousIp != peerIp) {
      debugPrint('Peer IP updated by deviceId: $peerId $previousIp -> $peerIp');
    }

    final hadRecentDirectSignal = previousDirectSeen != null &&
        now.difference(previousDirectSeen) <= _directPeerStaleDuration;
    final directSignalChanged =
        !hadRecentDirectSignal || previousIp != _peerIps[peerId];
    if (directSignalChanged) {
      _emitChange();
    }
  }

  Future<void> _sendJson(Socket socket, Map<String, dynamic> payload) async {
    try {
      socket.add(utf8.encode('${jsonEncode(payload)}\n'));
      await socket.flush().timeout(_sendFlushTimeout);
    } on TimeoutException catch (error) {
      throw TimeoutException('Timed out flushing TCP frame', error.duration);
    } on SocketException {
      rethrow;
    } on JsonUnsupportedObjectError {
      rethrow;
    } catch (error) {
      throw StateError('Could not write TCP frame: $error');
    }
  }

  void _handleSocketClosed(
    Socket socket,
    _SocketState state, {
    Object? error,
  }) {
    final peerId = state.peerId;
    if (peerId != null && _connections[peerId] == socket) {
      _connections.remove(peerId);
    }
    _socketStates.remove(socket);
    socket.destroy();
    if (peerId != null) {
      _cancelTransfersForDisconnectedPeers(
        {peerId},
        reason: 'Connection closed',
        status: TransferStatus.failed,
      );
      _emitChange();
    }
    if (error != null) {
      _lastTransportError = error.toString();
      debugPrint('Connection closed with error: $error');
    }
  }

  void _grantPeerAccess(String peerId, {bool notify = true}) {
    _setPermissionState(peerId, PeerPermissionState.granted, notify: false);
    if (notify) {
      _emitChange();
    }
  }

  void _completePermission(String peerId, {required bool accepted}) {
    final completer = _permissionCompleters.remove(peerId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(accepted);
    }
  }

  void _setPermissionState(
    String peerId,
    PeerPermissionState state, {
    bool notify = true,
  }) {
    if (_permissionStates[peerId] == state) return;
    _permissionStates[peerId] = state;
    if (notify) {
      _emitChange();
    }
  }

  void _registerConversationHandler(String key, MessageHandler handler) {
    _messageHandlers[key] = handler;
    final pending = _pendingBuffer.remove(key);
    if (pending != null) {
      for (final message in pending) {
        handler(message);
      }
    }
  }

  void _registerCanvasHandler(String key, CanvasEventHandler handler) {
    _canvasHandlers[key] = handler;
    final pending = _pendingCanvas.remove(key);
    if (pending != null) {
      for (final event in pending) {
        handler(event);
      }
    }
  }

  List<ChatMessage> _conversationHistory(String key) {
    return List.unmodifiable(_history[key] ?? const <ChatMessage>[]);
  }

  List<CanvasEvent> _conversationCanvasHistory(String key) {
    return List.unmodifiable(_canvasHistory[key] ?? const <CanvasEvent>[]);
  }

  void _clearConversation(String key) {
    _history.remove(key);
    _pendingBuffer.remove(key);
    _canvasHistory.remove(key);
    _pendingCanvas.remove(key);
    unawaited(_historyStore.clearMessages(key));
    _emitChange();
  }

  Future<void> _applyChatPersistence({
    required ConversationKind kind,
    required String conversationId,
    required bool enabled,
    required bool clearWhenDisabled,
  }) async {
    final key = _conversationKey(kind, conversationId);
    if (enabled) {
      _persistentConversationKeys.add(key);
      await _historyStore.setPersistent(key, true);
      await _persistConversation(key);
    } else {
      _persistentConversationKeys.remove(key);
      await _historyStore.setPersistent(key, false);
      await _historyStore.clearMessages(key);
      if (clearWhenDisabled) {
        _history.remove(key);
        _pendingBuffer.remove(key);
      }
    }
    _emitChange();
  }

  void _clearTransientPeerConversation(String peerId) {
    final key = _peerConversationId(peerId);
    if (_persistentConversationKeys.contains(key)) return;
    _history.remove(key);
    _pendingBuffer.remove(key);
  }

  Future<void> _persistConversation(String key) {
    final previous = _historySaveTasks[key] ?? Future<void>.value();
    late final Future<void> task;
    task = previous.catchError((_) {}).then((_) {
      final messages = (_history[key] ?? const <ChatMessage>[])
          .map((message) => message.toJson())
          .toList(growable: false);
      return _historyStore.saveMessages(key, messages);
    });
    _historySaveTasks[key] = task;
    unawaited(
      task.whenComplete(() {
        if (_historySaveTasks[key] == task) {
          _historySaveTasks.remove(key);
        }
      }),
    );
    return task;
  }

  void _upsertAndNotify(
    String key,
    ChatMessage message, {
    bool bufferIfNoHandler = false,
    bool persist = true,
  }) {
    _upsertMessage(_history.putIfAbsent(key, () => []), message);
    if (persist && _persistentConversationKeys.contains(key)) {
      unawaited(_persistConversation(key));
    }
    final handler = _messageHandlers[key];
    if (handler != null) {
      handler(message);
    } else if (bufferIfNoHandler) {
      _upsertMessage(_pendingBuffer.putIfAbsent(key, () => []), message);
    }
    _emitChange();
  }

  void _appendCanvasEvent(String key, CanvasEvent event) {
    final history = _canvasHistory.putIfAbsent(key, () => []);
    if (event.type == 'clear') {
      history
        ..clear()
        ..add(event);
    } else {
      history.add(event);
    }

    final handler = _canvasHandlers[key];
    if (handler != null) {
      handler(event);
    } else {
      _pendingCanvas.putIfAbsent(key, () => []).add(event);
    }
    _emitChange();
  }

  void _updateFileMessage({
    required ConversationKind conversationKind,
    required String conversationId,
    required String messageId,
    Object? localPath = _unset,
    TransferStatus? transferStatus,
    double? transferProgress,
    double? transferSpeedBytesPerSecond,
    String? error,
  }) {
    final key = _conversationKey(conversationKind, conversationId);
    final message = _findMessage(key, messageId);
    if (message == null) return;
    final localPathChanged =
        !identical(localPath, _unset) && localPath != message.localPath;
    final shouldPersist =
        transferStatus != null || localPathChanged || error != null;

    _upsertAndNotify(
      key,
      message.copyWith(
        localPath: localPath,
        transferStatus: transferStatus,
        transferProgress: transferProgress,
        transferSpeedBytesPerSecond: transferSpeedBytesPerSecond,
        error: error,
      ),
      bufferIfNoHandler: !message.isMe,
      persist: shouldPersist,
    );
  }

  ChatMessage? _findMessage(String key, String messageId) {
    final messages = _history[key];
    if (messages == null) return null;
    for (final message in messages) {
      if (message.messageId == messageId) {
        return message;
      }
    }
    return null;
  }

  ChatMessage? _findMessageByTransferId(String transferId) {
    if (transferId.isEmpty) return null;
    for (final messages in _history.values) {
      for (final message in messages) {
        if (message.transferId == transferId) return message;
      }
    }
    return null;
  }

  void _upsertMessage(List<ChatMessage> messages, ChatMessage message) {
    final index =
        messages.indexWhere((item) => item.messageId == message.messageId);
    if (index == -1) {
      messages.add(message);
    } else {
      messages[index] = message;
    }
  }

  void _rememberPeer({
    required String peerId,
    String? peerName,
    String? peerIp,
    DateTime? seenAt,
  }) {
    if (peerId.isEmpty) return;
    if (peerName != null && peerName.isNotEmpty) {
      _peerNames[peerId] = peerName;
    }
    if (peerIp != null && peerIp.isNotEmpty) {
      _peerIps[peerId] = peerIp;
    }
    _peerLastSeen[peerId] = seenAt ?? DateTime.now();
  }

  void _rememberDirectPeer({
    required String peerId,
    String? peerName,
    String? peerIp,
    DateTime? seenAt,
  }) {
    if (peerId.isEmpty || peerId == myId) return;
    final now = seenAt ?? DateTime.now();
    _rememberPeer(
      peerId: peerId,
      peerName: peerName,
      peerIp: peerIp,
      seenAt: now,
    );
    _directPeerLastSeen[peerId] = now;
  }

  Future<bool> connectToManualEndpoint(String endpoint) async {
    final parsed = _parseEndpoint(endpoint);
    if (parsed == null) {
      _lastTransportError = 'Manual endpoint must look like 192.168.1.20:9002.';
      _emitChange();
      return false;
    }

    try {
      final socket = await Socket.connect(
        parsed.host,
        parsed.port,
        timeout: const Duration(seconds: _socketTimeoutSeconds),
      );
      final state = _SocketState(
        peerId: null,
        manualRemotePort: parsed.port == messagingPort ? null : parsed.port,
      );
      _socketStates[socket] = state;
      _listenOnSocketWithState(socket, state);
      await _sendHello(socket, state);
      _lastTransportError = null;
      _emitChange();
      return true;
    } catch (error) {
      _lastTransportError = 'Manual connection failed: $error';
      _emitChange();
      return false;
    }
  }

  _ManualEndpoint? _parseEndpoint(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    var host = trimmed;
    var port = messagingPort;

    final bracketedIpv6 = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(trimmed);
    if (bracketedIpv6 != null) {
      host = bracketedIpv6.group(1)!;
      port = int.tryParse(bracketedIpv6.group(2)!) ?? messagingPort;
    } else {
      final lastColon = trimmed.lastIndexOf(':');
      if (lastColon > -1 && trimmed.indexOf(':') == lastColon) {
        host = trimmed.substring(0, lastColon).trim();
        port = int.tryParse(trimmed.substring(lastColon + 1).trim()) ??
            messagingPort;
      }
    }

    if (host.isEmpty || port <= 0 || port > 65535) return null;
    return _ManualEndpoint(host: host, port: port);
  }

  Iterable<String> _directPeerIds({Set<String> excludePeerIds = const {}}) {
    final now = DateTime.now();
    final ids = <String>{
      ..._directPeerLastSeen.entries
          .where(
            (entry) => now.difference(entry.value) <= _directPeerStaleDuration,
          )
          .map((entry) => entry.key),
    }..remove(myId);
    ids.removeWhere(excludePeerIds.contains);
    return ids;
  }

  List<String> _directAddressCandidates(String peerId, String? preferredIp) {
    final addresses = <String>[];
    void add(String? ip) {
      if (ip == null || ip.isEmpty || addresses.contains(ip)) return;
      addresses.add(ip);
    }

    add(preferredIp);
    add(_peerIps[peerId]);
    final socket = _connections[peerId];
    if (socket != null) {
      add(socket.remoteAddress.address);
    }
    return addresses;
  }

  void _expireStalePeers() {
    final now = DateTime.now();
    for (final entry in _directPeerLastSeen.entries.toList(growable: false)) {
      if (_connections.containsKey(entry.key)) continue;
      if (now.difference(entry.value) > _directPeerStaleDuration) {
        _directPeerLastSeen.remove(entry.key);
        debugPrint('Peer timeout: direct peer ${entry.key} is stale');
      }
    }

    for (final entry in _peerLastSeen.entries.toList(growable: false)) {
      final peerId = entry.key;
      if (peerId == myId ||
          canMessage(peerId) ||
          now.difference(entry.value) <= _peerForgetDuration) {
        continue;
      }
      _peerLastSeen.remove(peerId);
      _peerNames.remove(peerId);
      _peerIps.remove(peerId);
      _directPeerLastSeen.remove(peerId);
      _peerRegistryIds.remove(peerId);
      debugPrint('Peer timeout: forgetting stale peer $peerId');
    }
  }

  void _markPeerUnresponsive(String peerId) {
    if (peerId.isEmpty || peerId == myId) return;
    _peerLastSeen[peerId] = DateTime.now().subtract(_peerForgetDuration * 2);
    _directPeerLastSeen.remove(peerId);
    final socket = _connections.remove(peerId);
    socket?.destroy();
  }

  Future<void> _refreshDirectConnections() async {
    final peerIds = <String>{
      ..._connections.keys,
      ..._peerRegistryIds
          .where((peerId) => _peerIps[peerId]?.isNotEmpty == true),
    }..remove(myId);
    if (peerIds.isEmpty) return;

    for (final peerId in peerIds) {
      if (!_isOnlineMode && !canMessage(peerId)) continue;
      unawaited(
        _sendDirectPing(
          peerId: peerId,
          peerIp: _peerIps[peerId],
          peerPort: _peerPorts[peerId],
          peerName: _displayName(peerId),
          timeout: _aliveProbeTimeout,
        ),
      );
    }
  }

  Future<void> _broadcastIdentity() async {
    for (final peerId in _directPeerIds()) {
      try {
        await _sendDirectFrame(
          peerId: peerId,
          peerIp: _peerIps[peerId],
          allowBeforePermission: true,
          frame: {
            'type': directFrameInfo,
            'request': false,
            ..._localDeviceInfo(),
          },
        );
      } catch (error) {
        debugPrint('Identity update failed for $peerId: $error');
      }
    }
  }

  Future<void> _broadcastGroupMembership(String groupId) async {
    final room = _groups[groupId];
    if (room == null) return;
    final payload = {
      'kind': 'group_membership_update',
      'groupId': room.groupId,
      'groupName': room.name,
      'ownerId': room.ownerId,
      'ownerName': room.ownerName,
      'code': room.code,
      'joinSecret': room.joinSecret,
      'createdAt': room.createdAt.toIso8601String(),
      'members': room.members
          .map((member) => {
                'peerId': member.peerId,
                'name': member.name,
                'isOwner': member.isOwner,
              })
          .toList(growable: false),
    };

    final recipients = room.members
        .where((member) => member.peerId != myId)
        .map((member) => member.peerId)
        .toList(growable: false);
    await _sendPlainPayloadToRecipients(
      recipients: recipients,
      allowUnapprovedDestinations: true,
      payloadBuilder: (_) => payload,
    );
    _emitChange();
  }

  Future<void> _sendChatPersistenceUpdate({
    required ConversationKind kind,
    required String conversationId,
    required bool enabled,
  }) async {
    final payload = {
      'kind': 'chat_persistence',
      'conversationType': kind.name,
      if (kind != ConversationKind.peer) 'conversationId': conversationId,
      'enabled': enabled,
      'timestamp': DateTime.now().toIso8601String(),
    };

    switch (kind) {
      case ConversationKind.peer:
        await _sendPlainPayloadToRecipients(
          recipients: [conversationId],
          allowUnapprovedDestinations: true,
          payloadBuilder: (_) => payload,
        );
      case ConversationKind.group:
        final room = _groups[conversationId];
        if (room == null) return;
        await _sendPlainPayloadToRecipients(
          recipients: room.members
              .where((member) => member.peerId != myId)
              .map((member) => member.peerId)
              .toList(growable: false),
          allowUnapprovedDestinations: true,
          payloadBuilder: (_) => payload,
        );
    }
  }

  GroupRoom _groupFromPayload(Map<String, dynamic> payload) {
    final groupId = (payload['groupId'] ?? '').toString();
    final members = _memberListFromPayload(payload['members']);
    return GroupRoom(
      groupId: groupId,
      name: (payload['groupName'] ?? 'Group').toString(),
      ownerId: (payload['ownerId'] ?? '').toString(),
      ownerName: (payload['ownerName'] ?? '').toString(),
      code: (payload['code'] ?? '').toString(),
      joinSecret: (payload['joinSecret'] ?? '').toString(),
      isOwner: (payload['ownerId'] ?? '').toString() == myId,
      members: _withLiveMemberStatus(members),
      createdAt: _parseTimestamp(payload['createdAt']),
    );
  }

  List<GroupMember> _memberListFromPayload(Object? rawMembers) {
    final members = <GroupMember>[];
    if (rawMembers is List) {
      for (final entry in rawMembers) {
        final map = _mapFrom(entry);
        if (map == null) continue;
        final peerId = (map['peerId'] ?? '').toString();
        final name = (map['name'] ?? peerId).toString();
        if (peerId.isEmpty) continue;
        _rememberPeer(peerId: peerId, peerName: name, seenAt: DateTime.now());
        members.add(
          GroupMember(
            peerId: peerId,
            name: name,
            isOwner: map['isOwner'] == true,
            isOnline: _peerIsOnline(peerId),
          ),
        );
      }
    }
    return _withLiveMemberStatus(members);
  }

  List<GroupMember> _memberListWithPeer(
    List<GroupMember> source,
    String peerId,
    String peerName, {
    required bool isOwner,
  }) {
    final next = source.where((member) => member.peerId != peerId).toList();
    next.add(
      GroupMember(
        peerId: peerId,
        name: peerName,
        isOwner: isOwner,
        isOnline: _peerIsOnline(peerId),
      ),
    );
    return _withLiveMemberStatus(next);
  }

  List<GroupMember> _withLiveMemberStatus(List<GroupMember> members) {
    return members
        .map(
          (member) => member.copyWith(
            isOnline:
                member.peerId == myId ? true : _peerIsOnline(member.peerId),
          ),
        )
        .toList(growable: false);
  }

  bool _conversationAllowsSender(
    ConversationKind kind,
    String conversationId,
    String senderId,
  ) {
    switch (kind) {
      case ConversationKind.peer:
        return canMessage(senderId);
      case ConversationKind.group:
        final room = _groups[conversationId];
        return room != null &&
            room.members.any((member) => member.peerId == senderId);
    }
  }

  void _addSystemMessage(
    String key, {
    required String conversationId,
    required ConversationKind kind,
    required String text,
  }) {
    _upsertAndNotify(
      key,
      ChatMessage(
        messageId: _nextOpaqueId('sys'),
        conversationId: conversationId,
        conversationKind: kind,
        text: text,
        fromName: 'ShareViaLAN',
        fromId: 'system',
        timestamp: DateTime.now(),
        isMe: false,
        isSystem: true,
      ),
    );
  }

  bool _peerIsOnline(String peerId) {
    if (peerId == myId) return true;
    final directSeen = _directPeerLastSeen[peerId];
    if (directSeen != null &&
        DateTime.now().difference(directSeen) <= _directPeerStaleDuration) {
      return true;
    }
    final lastSeen = _peerLastSeen[peerId];
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen) <= const Duration(seconds: 20);
  }

  @visibleForTesting
  void debugRegisterDirectPeer({
    required String peerId,
    required String peerName,
    String peerIp = '',
    DateTime? seenAt,
  }) {
    _peerRegistryIds.add(peerId);
    _rememberDirectPeer(
      peerId: peerId,
      peerName: peerName,
      peerIp: peerIp,
      seenAt: seenAt ?? DateTime.now(),
    );
  }

  @visibleForTesting
  String? debugNextHopFor(String peerId) =>
      _peerRegistryIds.contains(peerId) ? peerId : null;

  @visibleForTesting
  int? debugHopCountFor(String peerId) =>
      _peerRegistryIds.contains(peerId) ? 1 : null;

  @visibleForTesting
  void debugRebuildRoutes() {}

  String _incomingConversationId(
    ConversationKind kind,
    Object? rawConversationId,
    String originId,
  ) {
    switch (kind) {
      case ConversationKind.peer:
        return originId;
      case ConversationKind.group:
        return (rawConversationId ?? '').toString();
    }
  }

  ConversationKind _conversationKindFrom(String? raw) {
    switch (raw) {
      case 'group':
        return ConversationKind.group;
      case 'peer':
      default:
        return ConversationKind.peer;
    }
  }

  String _conversationKey(ConversationKind kind, String id) {
    switch (kind) {
      case ConversationKind.peer:
        return _peerConversationId(id);
      case ConversationKind.group:
        return _groupConversationId(id);
    }
  }

  String _peerConversationId(String peerId) => 'peer::$peerId';

  String _groupConversationId(String groupId) => 'group::$groupId';

  String _displayName(String? peerId) {
    if (peerId == null || peerId.isEmpty) return 'Unknown';
    if (peerId == myId) return myName;
    return _peerNames[peerId] ?? peerId;
  }

  String _permissionFailureText({
    required String peerName,
    required String reason,
  }) {
    switch (reason) {
      case 'receiver_offline_mode':
        return '$peerName is in offline mode and rejected new connection requests.';
      case 'receiver_only_accepts_own_requests':
        return '$peerName only accepts connections they initiate.';
      case 'receiver_has_no_permission_handler':
        return '$peerName received the request, but its permission dialog is not available.';
      case 'permission_dialog_failed':
        return '$peerName received the request, but could not show the allow/deny dialog.';
      case 'user_denied':
        return '$peerName denied the connection request.';
      default:
        return '$peerName did not allow the connection.';
    }
  }

  Future<String> _uniqueDownloadPath(String fileName) async {
    final safeName = _safeFileName(fileName);
    if (Platform.isAndroid) {
      final publicPath =
          await LanPlatformChannel.androidPublicDownloadPath(safeName);
      if (publicPath != null && publicPath.isNotEmpty) return publicPath;
      return '/storage/emulated/0/Download/ShareViaLAN/$safeName';
    }

    final directory = await _shareViaLanDownloadDirectory();
    await directory.create(recursive: true);

    final separator = Platform.pathSeparator;
    final dotIndex = safeName.lastIndexOf('.');
    final base = dotIndex <= 0 ? safeName : safeName.substring(0, dotIndex);
    final extension = dotIndex <= 0 ? '' : safeName.substring(dotIndex);

    var counter = 0;
    while (true) {
      final suffix = counter == 0 ? '' : ' ($counter)';
      final candidate = '${directory.path}$separator$base$suffix$extension';
      final streamingCandidate = _streamingPathFor(candidate);
      if (!await File(candidate).exists() &&
          !await File('$candidate.part').exists() &&
          !await File(streamingCandidate).exists()) {
        return candidate;
      }
      counter += 1;
    }
  }

  String _streamingPathFor(String finalPath) {
    final separator = Platform.pathSeparator;
    final slashIndex = finalPath.lastIndexOf(separator);
    final directory =
        slashIndex == -1 ? '' : finalPath.substring(0, slashIndex + 1);
    final name =
        slashIndex == -1 ? finalPath : finalPath.substring(slashIndex + 1);
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$directory$name.streaming';
    }
    return '$directory${name.substring(0, dotIndex)}.streaming${name.substring(dotIndex)}';
  }

  Future<String> _incomingTempPath({
    required String transferId,
    required String fileName,
    required String finalPath,
    required bool isStream,
  }) async {
    if (Platform.isAndroid) {
      final tempRoot = await getTemporaryDirectory();
      final directory = Directory(
        '${tempRoot.path}${Platform.pathSeparator}ShareViaLAN'
        '${Platform.pathSeparator}Receiving',
      );
      await directory.create(recursive: true);
      final suffix = isStream ? '.streaming' : '.part';
      return '${directory.path}${Platform.pathSeparator}$transferId-'
          '${_safeFileName(fileName)}$suffix';
    }

    return isStream ? _streamingPathFor(finalPath) : '$finalPath.part';
  }

  Future<String> _publishCompletedIncomingFile(
    _IncomingTransfer transfer,
  ) async {
    final tempFile = File(transfer.tempPath);
    if (Platform.isAndroid) {
      final savedPath = await LanPlatformChannel.publishAndroidDownload(
        sourcePath: transfer.tempPath,
        fileName: _safeFileName(transfer.fileName),
      );
      if (savedPath == null || savedPath.isEmpty) {
        throw StateError('Could not publish file to Android Downloads');
      }
      if (transfer.isStream && transfer.streamSession != null) {
        transfer.streamSession!.markComplete(
          deleteOnClosePath: transfer.tempPath,
        );
      } else {
        try {
          await tempFile.delete();
        } catch (error) {
          debugPrint('Could not remove temporary received file: $error');
        }
      }
      return savedPath;
    }

    final finalFile = File(transfer.finalPath);
    if (transfer.isStream && transfer.streamSession != null) {
      await tempFile.copy(finalFile.path);
      transfer.streamSession!.markComplete(
        deleteOnClosePath: transfer.tempPath,
      );
    } else {
      await _moveFile(tempFile, finalFile);
    }
    return transfer.finalPath;
  }

  Future<String> _completeTemporaryStream(_IncomingTransfer transfer) async {
    transfer.streamSession?.markComplete(deleteOnClosePath: transfer.tempPath);
    return transfer.streamSession?.playbackUrl ?? transfer.tempPath;
  }

  Future<Directory> _shareViaLanDownloadDirectory() async {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Download/ShareViaLAN');
    }

    // Respect relocated Windows folders and Linux XDG/localized Downloads.
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return Directory(
            '${downloads.path}${Platform.pathSeparator}ShareViaLAN');
      }
    } catch (error) {
      debugPrint('Could not resolve the system Downloads folder: $error');
    }

    if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory('$home/Downloads/ShareViaLAN');
      }
    }

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return Directory('$userProfile\\Downloads\\ShareViaLAN');
      }
    }

    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}${Platform.pathSeparator}ShareViaLAN');
  }

  String _safeFileName(String fileName) {
    return safeFileName(fileName);
  }

  Future<void> _moveFile(File from, File to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await from.copy(to.path);
      await from.delete();
    }
  }

  int _indexOfByte(List<int> bytes, int byte, int start) {
    for (var i = start; i < bytes.length; i += 1) {
      if (bytes[i] == byte) return i;
    }
    return -1;
  }

  bool _markPacketSeen(String packetId, {bool logDuplicate = true}) {
    return _markSeen(
      cache: _seenMessageCache,
      id: packetId,
      expiry: _seenMessageCacheDuration,
      maxEntries: 4096,
      duplicateLog:
          logDuplicate ? 'Message dropped duplicate: $packetId' : null,
    );
  }

  bool _markSeen({
    required LinkedHashMap<String, DateTime> cache,
    required String id,
    required Duration expiry,
    required int maxEntries,
    required String? duplicateLog,
  }) {
    final now = DateTime.now();
    _expireSeenCache(cache, expiry, now);
    if (cache.containsKey(id)) {
      if (duplicateLog != null) {
        debugPrint(duplicateLog);
      }
      return false;
    }
    cache[id] = now;
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
    return true;
  }

  void _expireSeenCaches() {
    final now = DateTime.now();
    _expireSeenCache(_seenMessageCache, _seenMessageCacheDuration, now);
  }

  void _expireSeenCache(
    LinkedHashMap<String, DateTime> cache,
    Duration expiry,
    DateTime now,
  ) {
    cache.removeWhere((_, seenAt) => now.difference(seenAt) > expiry);
  }

  Map<String, dynamic>? _mapFrom(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  DateTime _parseTimestamp(Object? value) => _parseStaticTimestamp(value);

  static DateTime _parseStaticTimestamp(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.now();
    }
    return DateTime.now();
  }

  double _progress(int done, int total) {
    if (total <= 0) return 1;
    return (done / total).clamp(0, 1).toDouble();
  }

  String _nextMessageId() {
    _messageCounter += 1;
    return '$myId-${DateTime.now().microsecondsSinceEpoch}-$_messageCounter';
  }

  String _nextRemoteMessageId(String peerId) {
    _messageCounter += 1;
    return '$peerId-${DateTime.now().microsecondsSinceEpoch}-$_messageCounter';
  }

  String _nextOpaqueId(String prefix) {
    _messageCounter += 1;
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$_messageCounter';
  }

  String _randomCode({required int length}) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = math.Random.secure();
    return List<String>.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  String _encodeInviteCode(String prefix, Map<String, dynamic> payload) {
    final raw = utf8.encode(jsonEncode(payload));
    return '$prefix-${base64Url.encode(raw).replaceAll('=', '')}';
  }

  Map<String, dynamic>? _decodeInviteCode(String code, String prefix) {
    final normalized = code.trim();
    if (!normalized.startsWith('$prefix-')) return null;
    final encoded = normalized.substring(prefix.length + 1);
    if (encoded.isEmpty) return null;

    final padded = switch (encoded.length % 4) {
      0 => encoded,
      2 => '$encoded==',
      3 => '$encoded=',
      _ => encoded,
    };
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  void _emitChange() {
    if (!_stopped) {
      notifyListeners();
    }
  }

  Future<bool> _featureAllowed(
    ChatFeatureGuard? guard,
    ConversationKind kind,
    String conversationId,
  ) async {
    if (guard == null) return true;
    try {
      return await guard(kind, conversationId);
    } catch (error) {
      debugPrint(
        'Chat feature guard failed for ${kind.name}::$conversationId: $error',
      );
      return false;
    }
  }
}

class _SocketState {
  String? peerId;
  final int? manualRemotePort;
  bool registerSent = false;
  bool directVerified = false;
  final List<int> headerBuffer = [];
  StreamSubscription<List<int>>? subscription;

  _SocketState({
    required this.peerId,
    this.manualRemotePort,
  });
}

class _ManualEndpoint {
  final String host;
  final int port;

  const _ManualEndpoint({
    required this.host,
    required this.port,
  });
}

class _DirectPingProbe {
  final String peerId;
  final int? peerPort;
  final Completer<bool> completer = Completer<bool>();

  _DirectPingProbe({
    required this.peerId,
    required this.peerPort,
  });
}

class _TransferAckWaiter {
  final Set<String> pendingPeerIds;
  final Completer<bool> completer = Completer<bool>();

  _TransferAckWaiter(Iterable<String> peerIds)
      : pendingPeerIds = peerIds.toSet() {
    if (pendingPeerIds.isEmpty) {
      completer.complete(true);
    }
  }

  void markAcked(String peerId) {
    pendingPeerIds.remove(peerId);
    if (pendingPeerIds.isEmpty && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  void complete(bool value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }
}

class _OutgoingTransfer {
  final String transferId;
  final ConversationKind conversationKind;
  final String conversationId;
  final String messageId;
  final String filePath;
  final String fileName;
  final int fileSize;
  final Map<String, String?> directPeerIps;
  final bool allowUnapprovedDestinations;
  final String? conversationName;
  final bool isStream;
  final StreamTransferMode streamMode;
  final bool deleteSourceOnComplete;
  final Set<String> pendingRecipients;
  final Set<String> acceptedRecipients = <String>{};
  final Set<String> rejectedRecipients = <String>{};
  final Set<String> pausedRecipients = <String>{};
  final Map<String, int> ackedBytesByRecipient = <String, int>{};
  final Map<int, _TransferAckWaiter> _chunkAckWaiters =
      <int, _TransferAckWaiter>{};
  final Completer<bool> _decisionCompleter = Completer<bool>();

  _TransferAckWaiter? _completeAckWaiter;
  bool _locallyPaused = false;
  bool canceled = false;
  bool failed = false;
  bool transferStarted = false;
  Future<void>? transferTask;
  String? failureReason;

  _OutgoingTransfer({
    required this.transferId,
    required this.conversationKind,
    required this.conversationId,
    required this.messageId,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required Iterable<String> recipients,
    required Map<String, String?> directPeerIps,
    required this.allowUnapprovedDestinations,
    required this.conversationName,
    required this.isStream,
    this.streamMode = StreamTransferMode.streamAndSend,
    this.deleteSourceOnComplete = false,
  })  : directPeerIps = Map.unmodifiable(directPeerIps),
        pendingRecipients = recipients.toSet();

  Set<String> get allRecipients => <String>{
        ...pendingRecipients,
        ...acceptedRecipients,
        ...rejectedRecipients,
      };

  void markAccepted(String peerId) {
    pendingRecipients.remove(peerId);
    rejectedRecipients.remove(peerId);
    acceptedRecipients.add(peerId);
    ackedBytesByRecipient[peerId] = 0;
    completeIfSettled();
  }

  void markRejected(String peerId) {
    pendingRecipients.remove(peerId);
    acceptedRecipients.remove(peerId);
    pausedRecipients.remove(peerId);
    ackedBytesByRecipient.remove(peerId);
    rejectedRecipients.add(peerId);
    for (final waiter in _chunkAckWaiters.values) {
      waiter.markAcked(peerId);
    }
    _completeAckWaiter?.markAcked(peerId);
    completeIfSettled();
  }

  void completeIfSettled() {
    if (pendingRecipients.isEmpty && !_decisionCompleter.isCompleted) {
      _decisionCompleter.complete(acceptedRecipients.isNotEmpty);
    }
  }

  Future<bool> waitForAcceptances() {
    if (pendingRecipients.isEmpty) {
      return Future<bool>.value(acceptedRecipients.isNotEmpty);
    }
    return _decisionCompleter.future.timeout(
      _fileAcceptTimeout,
      onTimeout: () => acceptedRecipients.isNotEmpty,
    );
  }

  bool get paused => _locallyPaused || pausedRecipients.isNotEmpty;

  bool get stopped => canceled || failed;

  bool get isActiveTransfer =>
      !stopped &&
      (!isStream || transferStarted || acceptedRecipients.isNotEmpty);

  int get acknowledgedBytes {
    if (acceptedRecipients.isEmpty) return 0;
    const sentinel = 1 << 62;
    var minBytes = sentinel;
    for (final peerId in acceptedRecipients) {
      minBytes = math.min(minBytes, ackedBytesByRecipient[peerId] ?? 0);
    }
    return minBytes == sentinel ? 0 : minBytes;
  }

  void pause() {
    _locallyPaused = true;
  }

  void resume() {
    _locallyPaused = false;
  }

  void pauseBy(String peerId) {
    if (acceptedRecipients.contains(peerId)) {
      pausedRecipients.add(peerId);
    }
  }

  void resumeBy(String peerId) {
    pausedRecipients.remove(peerId);
  }

  void cancel() {
    canceled = true;
    _locallyPaused = false;
    pausedRecipients.clear();
    _completePendingAcks(false);
    if (!_decisionCompleter.isCompleted) {
      _decisionCompleter.complete(false);
    }
  }

  void fail(String reason) {
    failed = true;
    failureReason = reason;
    _locallyPaused = false;
    pausedRecipients.clear();
    _completePendingAcks(false);
    if (!_decisionCompleter.isCompleted) {
      _decisionCompleter.complete(false);
    }
  }

  void expectChunkAck({
    required int chunkIndex,
    required Iterable<String> recipients,
  }) {
    _chunkAckWaiters[chunkIndex] = _TransferAckWaiter(
      recipients.where(acceptedRecipients.contains),
    );
  }

  void markChunkAck({
    required String peerId,
    required int chunkIndex,
    required int receivedBytes,
  }) {
    if (!acceptedRecipients.contains(peerId)) return;
    ackedBytesByRecipient[peerId] = math.max(
      ackedBytesByRecipient[peerId] ?? 0,
      receivedBytes,
    );
    _chunkAckWaiters[chunkIndex]?.markAcked(peerId);
  }

  Future<bool> waitForChunkAck(int chunkIndex) async {
    final waiter = _chunkAckWaiters[chunkIndex];
    if (waiter == null) return false;
    try {
      return await waiter.completer.future.timeout(
        _fileAckTimeout,
        onTimeout: () => false,
      );
    } finally {
      _chunkAckWaiters.remove(chunkIndex);
    }
  }

  void expectCompleteAck(Iterable<String> recipients) {
    _completeAckWaiter = _TransferAckWaiter(
      recipients.where(acceptedRecipients.contains),
    );
  }

  void markCompleteAck(String peerId) {
    _completeAckWaiter?.markAcked(peerId);
  }

  Future<bool> waitForCompleteAck() async {
    final waiter = _completeAckWaiter;
    if (waiter == null) return false;
    try {
      return await waiter.completer.future.timeout(
        _fileAckTimeout,
        onTimeout: () => false,
      );
    } finally {
      if (_completeAckWaiter == waiter) {
        _completeAckWaiter = null;
      }
    }
  }

  void _completePendingAcks(bool value) {
    for (final waiter in _chunkAckWaiters.values) {
      waiter.complete(value);
    }
    _chunkAckWaiters.clear();
    _completeAckWaiter?.complete(value);
    _completeAckWaiter = null;
  }

  Future<void> waitWhilePaused() async {
    while (paused && !stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> disposeTemporarySource() async {
    if (!deleteSourceOnComplete) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      final parent = file.parent;
      if (parent.path.contains('${Platform.pathSeparator}lancom_picked'
          '${Platform.pathSeparator}')) {
        await parent.delete();
      }
    } catch (error) {
      debugPrint(
          'Could not remove temporary outgoing source $filePath: $error');
    }
  }
}

class _PendingIncomingTransfer {
  final String conversationId;
  final ConversationKind conversationKind;
  final String originPeerId;
  final String originPeerName;
  final String transferId;
  final String messageId;
  final String fileName;
  final int fileSize;
  final bool isStream;
  final StreamTransferMode streamMode;
  final DateTime timestamp;
  final String? viaPeerName;

  const _PendingIncomingTransfer({
    required this.conversationId,
    required this.conversationKind,
    required this.originPeerId,
    required this.originPeerName,
    required this.transferId,
    required this.messageId,
    required this.fileName,
    required this.fileSize,
    required this.isStream,
    required this.streamMode,
    required this.timestamp,
    required this.viaPeerName,
  });
}

class _IncomingTransfer {
  final String conversationId;
  final ConversationKind conversationKind;
  final String originPeerId;
  final String originPeerName;
  final String transferId;
  final String messageId;
  final String fileName;
  final int fileSize;
  final bool isStream;
  final StreamTransferMode streamMode;
  final String tempPath;
  final String finalPath;
  final RandomAccessFile writer;
  final _ProgressiveStreamSession? streamSession;
  final _ProgressTracker tracker = _ProgressTracker();
  final _BufferedByteRanges _receivedRanges = _BufferedByteRanges();

  int receivedBytes = 0;
  bool _locallyPaused = false;
  bool _remotePaused = false;
  bool _flushedInitialStreamChunk = false;
  DateTime _lastStreamFlushAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool canceled = false;

  _IncomingTransfer({
    required this.conversationId,
    required this.conversationKind,
    required this.originPeerId,
    required this.originPeerName,
    required this.transferId,
    required this.messageId,
    required this.fileName,
    required this.fileSize,
    required this.isStream,
    required this.streamMode,
    required this.tempPath,
    required this.finalPath,
    required this.writer,
    this.streamSession,
  });

  bool get paused => _locallyPaused || _remotePaused;

  bool get isStreamOnly =>
      isStream && streamMode == StreamTransferMode.streamOnly;

  bool shouldFlushAfterChunk() {
    if (!isStream) return false;
    final now = DateTime.now();
    if (!_flushedInitialStreamChunk ||
        now.difference(_lastStreamFlushAt) >= _streamSinkFlushInterval ||
        receivedBytes >= fileSize) {
      _flushedInitialStreamChunk = true;
      _lastStreamFlushAt = now;
      return true;
    }
    return false;
  }

  Future<void> writeChunk({
    required int offset,
    required List<int> bytes,
  }) async {
    await writer.setPosition(offset);
    await writer.writeFrom(bytes);
    if (isStream) {
      _receivedRanges.add(offset, offset + bytes.length);
      receivedBytes = math.min(_receivedRanges.prefixEnd, fileSize);
    } else {
      receivedBytes += bytes.length;
    }
  }

  void pause({bool remote = false}) {
    if (remote) {
      _remotePaused = true;
    } else {
      _locallyPaused = true;
    }
  }

  void resume({bool remote = false}) {
    if (remote) {
      _remotePaused = false;
    } else {
      _locallyPaused = false;
    }
  }

  Future<void> disposeWithFailure(String reason) async {
    canceled = true;
    await streamSession?.fail(reason);
    try {
      await writer.close();
    } catch (_) {
      // Best effort.
    }
    try {
      await File(tempPath).delete();
    } catch (_) {
      // Best effort.
    }
    debugPrint('Incoming transfer $transferId failed: $reason');
  }
}

class _ProgressiveStreamSession {
  final String transferId;
  final String fileName;
  final String filePath;
  final int fileSize;
  final VoidCallback onClosed;
  final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);
  final _BufferedByteRanges _bufferedRanges = _BufferedByteRanges();

  HttpServer? _server;
  Timer? _closeTimer;
  String? _deleteOnClosePath;
  String? playbackUrl;
  int bufferedBytes = 0;
  bool _complete = false;
  bool _failed = false;
  bool _closed = false;

  _ProgressiveStreamSession({
    required this.transferId,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.onClosed,
  });

  Future<String?> start() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: true,
      );
    } catch (error) {
      debugPrint('Could not start progressive stream server: $error');
      await close();
      return null;
    }

    _server!.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (Object error) {
        debugPrint('Progressive stream server error: $error');
      },
    );

    final encodedName = Uri.encodeComponent(fileName);
    final url =
        'http://127.0.0.1:${_server!.port}/stream/$transferId/$encodedName';
    playbackUrl = url;
    return url;
  }

  void updateBufferedBytes(int bytes) {
    if (_closed || bytes <= bufferedBytes) return;
    updateBufferedRange(0, math.min(bytes, fileSize));
  }

  void updateBufferedRange(int start, int end) {
    if (_closed || end <= start) return;
    _bufferedRanges.add(math.max(0, start), math.min(end, fileSize));
    bufferedBytes = math.min(_bufferedRanges.prefixEnd, fileSize);
    _notifyWaiters();
  }

  void markComplete({String? deleteOnClosePath}) {
    if (_closed) return;
    _deleteOnClosePath = deleteOnClosePath;
    _complete = true;
    _bufferedRanges.add(0, fileSize);
    bufferedBytes = fileSize;
    _notifyWaiters();
    _closeTimer?.cancel();
    _closeTimer = Timer(_streamServerCompleteGrace, () {
      unawaited(close());
    });
  }

  Future<void> fail(String reason) async {
    if (_closed) return;
    _failed = true;
    _notifyWaiters();
    debugPrint('Progressive stream $transferId failed: $reason');
    await close(force: true);
  }

  Future<void> close({bool force = false}) async {
    if (_closed) return;
    _closed = true;
    _closeTimer?.cancel();
    _notifyWaiters();
    try {
      await _server?.close(force: force);
    } catch (_) {
      // Best effort.
    }
    if (!_changes.isClosed) {
      await _changes.close();
    }
    final deletePath = _deleteOnClosePath;
    if (deletePath != null) {
      try {
        await File(deletePath).delete();
      } catch (_) {
        // Best effort.
      }
    }
    onClosed();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    if (!_isPlaybackRequest(request)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }
    if (_failed || _closed) {
      response.statusCode = HttpStatus.gone;
      await response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = _HttpByteRange.parse(rangeHeader, fileSize);
    if (rangeHeader != null && range == null) {
      await _sendRangeNotSatisfiable(response);
      return;
    }
    if (fileSize == 0) {
      response.statusCode = rangeHeader == null
          ? HttpStatus.ok
          : HttpStatus.requestedRangeNotSatisfiable;
      response.contentLength = 0;
      if (rangeHeader != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */0');
      }
      await response.close();
      return;
    }

    final start = range?.start ?? 0;
    final requestedEnd = range?.end ?? fileSize - 1;
    if (start < 0 || start >= fileSize || requestedEnd < start) {
      await _sendRangeNotSatisfiable(response);
      return;
    }

    if (request.method != 'HEAD' &&
        !_complete &&
        !_bufferedRanges.contains(start)) {
      await _waitForMoreBytes(start);
    }
    if (_failed || _closed) {
      response.statusCode = HttpStatus.gone;
      await response.close();
      return;
    }

    final end = range == null || request.method == 'HEAD'
        ? requestedEnd
        : _availableRangeEnd(start: start, requestedEnd: requestedEnd);
    final contentLength = end - start + 1;
    if (contentLength <= 0) {
      await _sendRangeNotSatisfiable(response);
      return;
    }

    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType.parse(_videoContentTypeFor(fileName));

    if (range == null) {
      response.statusCode = HttpStatus.ok;
    } else {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$fileSize',
      );
    }
    response.contentLength = contentLength;

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    await _writeRange(response, start, end);
  }

  int _availableRangeEnd({
    required int start,
    required int requestedEnd,
  }) {
    if (_complete) return requestedEnd;
    final availableEnd = _bufferedRanges.contiguousEndFor(start);
    if (availableEnd == null) return start;
    final lastBufferedByte = math.max(start, availableEnd - 1);
    return math.min(requestedEnd, lastBufferedByte);
  }

  bool _isPlaybackRequest(HttpRequest request) {
    final segments = request.uri.pathSegments;
    return segments.length >= 2 &&
        segments[0] == 'stream' &&
        segments[1] == transferId;
  }

  Future<void> _sendRangeNotSatisfiable(HttpResponse response) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
    await response.close();
  }

  Future<void> _writeRange(HttpResponse response, int start, int end) async {
    RandomAccessFile? input;
    var offset = start;
    try {
      input = await _openInputWhenReady(start);
      if (input == null) return;
      await input.setPosition(start);

      while (offset <= end && !_closed && !_failed) {
        final bufferedEnd = _bufferedRanges.contiguousEndFor(offset);
        final available = bufferedEnd == null
            ? 0
            : math.min(bufferedEnd - offset, end - offset + 1);
        if (available <= 0) {
          if (_complete) break;
          await _waitForMoreBytes(offset);
          continue;
        }

        final readSize = math.min(_streamServerReadChunkBytes, available);
        final bytes = await input.read(readSize);
        if (bytes.isEmpty) {
          if (_complete) break;
          await _waitForMoreBytes(offset);
          continue;
        }

        response.add(bytes);
        offset += bytes.length;
        await response.flush();
      }
    } on SocketException {
      // The player closed the request while buffering.
    } on HttpException {
      // The player closed the request while buffering.
    } catch (error) {
      debugPrint('Progressive stream response failed: $error');
    } finally {
      try {
        await input?.close();
      } catch (_) {
        // Best effort.
      }
      try {
        await response.close();
      } catch (_) {
        // Best effort.
      }
    }
  }

  Future<RandomAccessFile?> _openInputWhenReady(int offset) async {
    while (!_closed && !_failed) {
      try {
        return await File(filePath).open();
      } catch (_) {
        if (_complete && bufferedBytes <= offset) return null;
        await _waitForMoreBytes(offset);
      }
    }
    return null;
  }

  Future<void> _waitForMoreBytes(int offset) async {
    while (!_closed &&
        !_failed &&
        !_complete &&
        !_bufferedRanges.contains(offset)) {
      try {
        await _changes.stream.first.timeout(_streamServerWaitInterval);
      } on TimeoutException {
        // Re-check state periodically even if no chunk notification arrives.
      }
    }
  }

  void _notifyWaiters() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}

class _BufferedByteRanges {
  final List<_BufferedByteRange> _ranges = <_BufferedByteRange>[];

  void add(int start, int end) {
    if (end <= start) return;

    var mergedStart = start;
    var mergedEnd = end;
    var index = 0;
    while (index < _ranges.length) {
      final range = _ranges[index];
      if (range.end < mergedStart) {
        index += 1;
        continue;
      }
      if (range.start > mergedEnd) break;

      mergedStart = math.min(mergedStart, range.start);
      mergedEnd = math.max(mergedEnd, range.end);
      _ranges.removeAt(index);
    }
    _ranges.insert(index, _BufferedByteRange(mergedStart, mergedEnd));
  }

  bool contains(int offset) => contiguousEndFor(offset) != null;

  int get prefixEnd => contiguousEndFor(0) ?? 0;

  int? contiguousEndFor(int offset) {
    for (final range in _ranges) {
      if (offset < range.start) return null;
      if (offset >= range.start && offset < range.end) return range.end;
    }
    return null;
  }
}

class _BufferedByteRange {
  final int start;
  final int end;

  const _BufferedByteRange(this.start, this.end);
}

class _HttpByteRange {
  final int start;
  final int end;

  const _HttpByteRange({
    required this.start,
    required this.end,
  });

  static _HttpByteRange? parse(String? header, int fileSize) {
    if (header == null) return null;
    if (!header.startsWith('bytes=') || header.contains(',')) return null;

    final value = header.substring('bytes='.length).trim();
    final dashIndex = value.indexOf('-');
    if (dashIndex == -1) return null;

    final rawStart = value.substring(0, dashIndex).trim();
    final rawEnd = value.substring(dashIndex + 1).trim();
    if (rawStart.isEmpty) {
      final suffixLength = int.tryParse(rawEnd);
      if (suffixLength == null || suffixLength <= 0 || fileSize <= 0) {
        return null;
      }
      final start = math.max(0, fileSize - suffixLength);
      return _HttpByteRange(start: start, end: fileSize - 1);
    }

    final start = int.tryParse(rawStart);
    if (start == null || start < 0) return null;
    final end = rawEnd.isEmpty ? fileSize - 1 : int.tryParse(rawEnd);
    if (end == null || end < start) return null;
    return _HttpByteRange(
      start: start,
      end: math.min(end, math.max(fileSize - 1, 0)),
    );
  }
}

class _ProgressTracker {
  DateTime _lastEmitAt = DateTime.now();
  int _lastEmitBytes = 0;
  double _lastSpeed = 0;

  bool shouldEmit(int done, int total) {
    if (done >= total) return true;
    return DateTime.now().difference(_lastEmitAt).inMilliseconds >=
        _progressIntervalMs;
  }

  double speed(int done) {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastEmitAt).inMilliseconds;
    if (elapsedMs <= 0) return _lastSpeed;

    final delta = done - _lastEmitBytes;
    _lastSpeed = delta / (elapsedMs / 1000);
    _lastEmitAt = now;
    _lastEmitBytes = done;
    return _lastSpeed;
  }
}

class _Unset {
  const _Unset();
}

String _videoContentTypeFor(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) {
    return 'video/mp4';
  }
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.mkv')) return 'video/x-matroska';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.avi')) return 'video/x-msvideo';
  if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
  if (lower.endsWith('.flv')) return 'video/x-flv';
  if (lower.endsWith('.3gp')) return 'video/3gpp';
  return 'application/octet-stream';
}

int _streamSequentialLimit(int fileSize) {
  if (fileSize <= 0) return 0;
  return math.max(0, fileSize - _streamStartupMetadataBytes);
}

StreamTransferMode _streamModeFromName(String value) {
  for (final mode in StreamTransferMode.values) {
    if (mode.name == value) return mode;
  }
  return StreamTransferMode.streamAndSend;
}

int _intFrom(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _doubleFrom(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

ConversationKind _conversationKindFromName(String value) {
  for (final kind in ConversationKind.values) {
    if (kind.name == value) return kind;
  }
  return ConversationKind.peer;
}

TransferStatus _transferStatusFromName(String value) {
  for (final status in TransferStatus.values) {
    if (status.name == value) return status;
  }
  return TransferStatus.none;
}
