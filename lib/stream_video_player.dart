import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'external_video_launcher.dart';
import 'messaging.dart';

const int _streamStartupBufferBytes = 4 * 1024 * 1024;
const double _streamStartupBufferFraction = 0.02;
const Duration _playerStartupRetryDelay = Duration(seconds: 12);

class StreamVideoPlayerScreen extends StatefulWidget {
  final MessagingService messaging;
  final ConversationKind conversationKind;
  final String conversationId;
  final ChatMessage initialMessage;

  const StreamVideoPlayerScreen({
    super.key,
    required this.messaging,
    required this.conversationKind,
    required this.conversationId,
    required this.initialMessage,
  });

  @override
  State<StreamVideoPlayerScreen> createState() =>
      _StreamVideoPlayerScreenState();
}

class _StreamVideoPlayerScreenState extends State<StreamVideoPlayerScreen> {
  late ChatMessage _message;
  VideoPlayerController? _controller;
  Future<void>? _initializeTask;
  String? _error;
  String? _notice;
  double _lastFailedProgress = -1;
  bool _isFullscreen = false;
  bool _fullscreenControlsVisible = true;
  bool _isLaunchingExternalPlayer = false;
  bool _hasPreferredExternalPlayer = false;
  Timer? _fullscreenControlsTimer;

  @override
  void initState() {
    super.initState();
    _message = widget.initialMessage;
    widget.messaging.addListener(_handleMessagingChanged);
    unawaited(_loadPreferredExternalPlayer());
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeInitialize());
  }

  @override
  void dispose() {
    widget.messaging.removeListener(_handleMessagingChanged);
    _fullscreenControlsTimer?.cancel();
    final transferId = _message.transferId;
    if (transferId != null && _message.isStreamOnly) {
      unawaited(
        widget.messaging.releaseStreamPlayback(
          transferId,
          cancelIfActive: _message.transferStatus != TransferStatus.saved,
        ),
      );
    }
    if (_isFullscreen) {
      unawaited(_restoreSystemUi());
    }
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_handleControllerChanged);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  bool get _isPlayerSupported {
    if (kIsWeb) return true;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  bool get _supportsExternalPlayer => ExternalVideoLauncher.isSupported;

  bool get _isTerminalFailure =>
      _message.transferStatus == TransferStatus.failed ||
      _message.transferStatus == TransferStatus.canceled ||
      _message.transferStatus == TransferStatus.rejected;

  bool get _isSaved => _message.transferStatus == TransferStatus.saved;

  String? get _playbackSource {
    final path = _message.localPath;
    if (path == null || path.isEmpty) return null;
    return path;
  }

  bool get _hasEnoughInitialBuffer {
    if (_isSaved) return true;
    final fileSize = _message.fileSize ?? 0;
    if (fileSize <= 0) return _message.transferProgress > 0;
    final bufferedBytes = (fileSize * _message.transferProgress).floor();
    final onePercentBytes =
        math.max(1, (fileSize * _streamStartupBufferFraction).ceil());
    final requiredBytes = math.min(
      fileSize,
      math.min(_streamStartupBufferBytes, onePercentBytes),
    );
    return bufferedBytes >= requiredBytes;
  }

  bool get _canOpenExternalPlayer =>
      _supportsExternalPlayer &&
      _playbackSource != null &&
      _hasEnoughInitialBuffer &&
      !_isTerminalFailure;

  double get _appBufferedFraction {
    if (_isSaved) return 1;
    return _message.transferProgress.clamp(0, 1).toDouble();
  }

  int get _bufferedBytes {
    final fileSize = _message.fileSize ?? 0;
    return (fileSize * _appBufferedFraction).floor();
  }

  double get _effectiveBufferedFraction {
    final controller = _controller;
    final value = controller?.value;
    var fraction = _appBufferedFraction;
    if (value != null &&
        value.isInitialized &&
        value.duration.inMilliseconds > 0) {
      for (final range in value.buffered) {
        fraction = math.max(
          fraction,
          range.end.inMilliseconds / value.duration.inMilliseconds,
        );
      }
    }
    return fraction.clamp(0, 1).toDouble();
  }

  Duration get _effectiveBufferedDuration {
    final controller = _controller;
    final value = controller?.value;
    if (value == null ||
        !value.isInitialized ||
        value.duration.inMilliseconds <= 0) {
      return Duration.zero;
    }
    return Duration(
      milliseconds:
          (value.duration.inMilliseconds * _effectiveBufferedFraction).floor(),
    );
  }

  void _handleMessagingChanged() {
    final latest = _latestMessage();
    if (latest != null) {
      _message = latest;
    }
    if (mounted) setState(() {});
    _maybeInitialize();
  }

  void _handleControllerChanged() {
    final controller = _controller;
    final value = controller?.value;
    if (controller != null && value?.hasError == true && _error == null) {
      unawaited(
        _handleInAppPlayerFailure(
          controller,
          value?.errorDescription ?? 'Video player error',
        ),
      );
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPreferredExternalPlayer() async {
    final hasPreferred = await ExternalVideoLauncher.hasPreferredPlayer();
    if (!mounted) return;
    setState(() => _hasPreferredExternalPlayer = hasPreferred);
  }

  ChatMessage? _latestMessage() {
    final transferId = widget.initialMessage.transferId;
    final history = switch (widget.conversationKind) {
      ConversationKind.peer =>
        widget.messaging.getHistory(widget.conversationId),
      ConversationKind.group =>
        widget.messaging.getGroupHistory(widget.conversationId),
    };
    for (final message in history) {
      if (transferId != null && message.transferId == transferId) {
        return message;
      }
      if (message.messageId == widget.initialMessage.messageId) {
        return message;
      }
    }
    return null;
  }

  void _maybeInitialize() {
    if (!_isPlayerSupported ||
        _isTerminalFailure ||
        _initializeTask != null ||
        _controller != null ||
        !_hasEnoughInitialBuffer) {
      return;
    }
    final source = _playbackSource;
    if (source == null) return;
    if (!_isSaved &&
        _error != null &&
        _message.transferProgress <= _lastFailedProgress + 0.01) {
      return;
    }

    _initializeTask = _initialize(source);
  }

  Future<void> _initialize(String source) async {
    _error = null;
    _notice = null;
    _lastFailedProgress = _message.transferProgress;
    if (mounted) setState(() {});

    final controller = _createController(source);
    controller.addListener(_handleControllerChanged);
    try {
      await controller.initialize().timeout(_playerStartupRetryDelay);
      await controller.setLooping(false);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _initializeTask = null;
      setState(() {});
      await controller.play();
    } on TimeoutException {
      controller.removeListener(_handleControllerChanged);
      await controller.dispose();
      if (!mounted) return;
      _initializeTask = null;
      _error = 'Still buffering the playable video header...';
      setState(() {});
    } on PlatformException catch (error) {
      controller.removeListener(_handleControllerChanged);
      await controller.dispose();
      if (!mounted) return;
      _initializeTask = null;
      _error = 'In-app player could not play this video. Try external player.';
      _notice = error.message ?? error.code;
      debugPrint('Video player PlatformException: $error');
      setState(() {});
    } catch (error) {
      controller.removeListener(_handleControllerChanged);
      await controller.dispose();
      if (!mounted) return;
      _initializeTask = null;
      _error = 'In-app player could not play this video. Try external player.';
      _notice = error.toString();
      debugPrint('Video player initialization failed: $error');
      setState(() {});
    }
  }

  Future<void> _handleInAppPlayerFailure(
    VideoPlayerController controller,
    Object error,
  ) async {
    controller.removeListener(_handleControllerChanged);
    if (_controller == controller) {
      _controller = null;
    }
    _initializeTask = null;
    try {
      await controller.dispose();
    } catch (_) {
      // Best effort; the platform player is already in an error state.
    }
    if (!mounted) return;
    setState(() {
      _error = 'In-app player could not play this video. Try external player.';
      _notice = error.toString();
    });
    debugPrint('Video player runtime failure: $error');
  }

  VideoPlayerController _createController(String source) {
    final uri = Uri.tryParse(source);
    final isHttp =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (isHttp) {
      return VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
    }
    return VideoPlayerController.file(
      File(source),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } on PlatformException catch (error) {
      await _handleInAppPlayerFailure(controller, error);
      return;
    } catch (error) {
      await _handleInAppPlayerFailure(controller, error);
      return;
    }
    if (_isFullscreen) {
      _scheduleFullscreenControlsHide();
    }
  }

  Future<void> _openDefaultExternalPlayer() {
    return _launchExternalPlayer(ExternalVideoLauncher.openDefault);
  }

  Future<void> _openPreferredExternalPlayer() {
    return _launchExternalPlayer(ExternalVideoLauncher.openPreferred);
  }

  Future<void> _chooseExternalPlayer() async {
    await _launchExternalPlayer(ExternalVideoLauncher.chooseAndOpen);
    await _loadPreferredExternalPlayer();
  }

  Future<void> _launchExternalPlayer(
    Future<ExternalVideoLaunchResult> Function(String source) launcher,
  ) async {
    final source = _playbackSource;
    if (source == null || _isLaunchingExternalPlayer) return;
    setState(() {
      _isLaunchingExternalPlayer = true;
      _notice = null;
    });

    ExternalVideoLaunchResult result;
    try {
      result = await launcher(source);
    } catch (error) {
      result = ExternalVideoLaunchResult.failure(error.toString());
    }
    if (!mounted) return;
    setState(() {
      _isLaunchingExternalPlayer = false;
      _notice = result.message;
    });
  }

  Future<void> _seekBy(Duration delta) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    final target = _clampSeekTarget(value.position + delta);
    try {
      await controller.seekTo(target);
    } catch (error) {
      await _handleInAppPlayerFailure(controller, error);
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    final target = Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
    final clamped = _clampSeekTarget(target);
    if (clamped < target && !_isSaved) {
      _notice = 'That part has not buffered yet.';
      setState(() {});
    }
    try {
      await controller.seekTo(clamped);
    } catch (error) {
      await _handleInAppPlayerFailure(controller, error);
    }
  }

  Duration _clampSeekTarget(Duration target) {
    final controller = _controller;
    final value = controller?.value;
    if (value == null || !value.isInitialized) return Duration.zero;
    var clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (clamped > value.duration) clamped = value.duration;
    if (!_isSaved && clamped > _effectiveBufferedDuration) {
      clamped = _effectiveBufferedDuration;
    }
    return clamped;
  }

  Future<void> _toggleFullscreen() => _setFullscreen(!_isFullscreen);

  Future<void> _setFullscreen(bool enabled) async {
    if (_isFullscreen == enabled) return;
    _fullscreenControlsTimer?.cancel();
    if (mounted) {
      setState(() {
        _isFullscreen = enabled;
        _fullscreenControlsVisible = true;
      });
    } else {
      _isFullscreen = enabled;
      _fullscreenControlsVisible = true;
    }

    if (enabled) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (_shouldRotateForFullscreen) {
        await SystemChrome.setPreferredOrientations(
          const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight
          ],
        );
      }
      _scheduleFullscreenControlsHide();
    } else {
      await _restoreSystemUi();
    }
  }

  bool get _shouldRotateForFullscreen {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _restoreSystemUi() async {
    if (_shouldRotateForFullscreen) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _toggleFullscreenControls() {
    if (!_isFullscreen) return;
    _fullscreenControlsTimer?.cancel();
    setState(() {
      _fullscreenControlsVisible = !_fullscreenControlsVisible;
    });
    if (_fullscreenControlsVisible) {
      _scheduleFullscreenControlsHide();
    }
  }

  void _scheduleFullscreenControlsHide() {
    _fullscreenControlsTimer?.cancel();
    final controller = _controller;
    if (!_isFullscreen ||
        controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }
    _fullscreenControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isFullscreen) {
        setState(() => _fullscreenControlsVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final value = controller?.value;
    final isReady = value?.isInitialized == true;
    final title = _message.fileName ?? 'Stream';

    return PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isFullscreen) {
          unawaited(_setFullscreen(false));
        }
      },
      child: _isFullscreen
          ? Scaffold(
              backgroundColor: Colors.black,
              body: _buildFullscreenPlayer(controller, value, isReady),
            )
          : Scaffold(
              backgroundColor: const Color(0xFF05070A),
              appBar: AppBar(
                title: Text(title, overflow: TextOverflow.ellipsis),
                backgroundColor: const Color(0xFF071827),
                actions: [
                  IconButton(
                    tooltip: 'Full screen',
                    onPressed: isReady ? _toggleFullscreen : null,
                    icon: const Icon(Icons.fullscreen),
                  ),
                ],
              ),
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _buildVideoSurface(controller, isReady),
                        ),
                      ),
                    ),
                    _buildControls(controller, value, isReady),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildFullscreenPlayer(
    VideoPlayerController? controller,
    VideoPlayerValue? value,
    bool isReady,
  ) {
    return Stack(
      children: [
        Positioned.fill(
          child: _buildVideoSurface(controller, isReady, fullscreen: true),
        ),
        if (_fullscreenControlsVisible) ...[
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Exit full screen',
                    onPressed: _toggleFullscreen,
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                  Expanded(
                    child: Text(
                      _message.fileName ?? 'Stream',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: _buildControls(
                controller,
                value,
                isReady,
                fullscreen: true,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVideoSurface(
    VideoPlayerController? controller,
    bool isReady, {
    bool fullscreen = false,
  }) {
    if (!_isPlayerSupported) {
      return _StatusPanel(
        icon: Icons.videocam_off_outlined,
        title: _supportsExternalPlayer
            ? 'Open stream in an installed player'
            : 'In-app playback is not available on this platform',
        subtitle: _supportsExternalPlayer
            ? _externalPlayerStatus
            : 'The progressive receiver is ready, but this Flutter video backend only supports Android, iOS, macOS, and web.',
        actions:
            _supportsExternalPlayer ? _buildExternalPlayerActions() : const [],
      );
    }

    if (isReady && controller != null) {
      final value = controller.value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: fullscreen ? _toggleFullscreenControls : _togglePlayback,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(fullscreen ? 0 : 8),
                child: VideoPlayer(controller),
              ),
            ),
            if (value.isBuffering)
              const DecoratedBox(
                decoration: BoxDecoration(color: Colors.black38),
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child:
                      CircularProgressIndicator(color: Colors.lightBlueAccent),
                ),
              ),
          ],
        ),
      );
    }

    return _StatusPanel(
      icon: _isTerminalFailure ? Icons.error_outline : Icons.slow_motion_video,
      title: _statusTitle,
      subtitle: _statusSubtitle,
      showSpinner: !_isTerminalFailure && _error == null,
      actions: _error != null && _supportsExternalPlayer
          ? _buildExternalPlayerActions()
          : const [],
    );
  }

  Widget _buildControls(
      VideoPlayerController? controller, VideoPlayerValue? value, bool isReady,
      {bool fullscreen = false}) {
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    final sliderMax =
        duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final sliderValue = math.min(
      position.inMilliseconds.toDouble(),
      sliderMax,
    );
    final bufferedPercent = (_effectiveBufferedFraction * 100).clamp(0, 100);
    final fileSize = _message.fileSize ?? 0;

    return Container(
      width: double.infinity,
      color: fullscreen ? Colors.black87 : const Color(0xFF071827),
      padding: fullscreen
          ? const EdgeInsets.fromLTRB(12, 8, 12, 10)
          : const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _effectiveBufferedFraction,
              minHeight: 5,
              backgroundColor: Colors.white12,
              color: Colors.lightBlueAccent,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_formatDuration(position)} / ${_formatDuration(duration)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                child: Text(
                  fileSize > 0
                      ? '${bufferedPercent.toStringAsFixed(0)}% buffered (${_formatBytes(_bufferedBytes)} / ${_formatBytes(fileSize)})'
                      : '${bufferedPercent.toStringAsFixed(0)}% buffered',
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ],
          ),
          Slider(
            value: sliderValue,
            max: sliderMax,
            onChanged: !isReady
                ? null
                : (value) {
                    _seekToFraction(value / sliderMax);
                  },
            activeColor: Colors.lightBlueAccent,
            inactiveColor: Colors.white24,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Back 10 seconds',
                onPressed: isReady
                    ? () => _seekBy(const Duration(seconds: -10))
                    : null,
                icon: const Icon(Icons.replay_10),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: isReady ? _togglePlayback : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(16),
                ),
                child: Icon(
                  value?.isPlaying == true ? Icons.pause : Icons.play_arrow,
                  size: 28,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Forward 10 seconds',
                onPressed:
                    isReady ? () => _seekBy(const Duration(seconds: 10)) : null,
                icon: const Icon(Icons.forward_10),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
                onPressed: isReady ? _toggleFullscreen : null,
                icon: Icon(
                  fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _notice ?? _statusSubtitle,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  String get _statusTitle {
    if (_isTerminalFailure) return _message.error ?? 'Stream stopped';
    if (_playbackSource == null) return 'Preparing stream session';
    if (!_hasEnoughInitialBuffer) return 'Buffering initial video';
    if (_initializeTask != null) return 'Opening in-app player';
    if (_error != null) return _error!;
    return 'Ready to play';
  }

  String get _statusSubtitle {
    if (_message.transferStatus == TransferStatus.saved) {
      if (_message.isStreamOnly) return 'Temporary stream is complete.';
      return 'Video saved locally.';
    }
    if (_message.transferStatus == TransferStatus.receiving) {
      return 'Receiving ${(_appBufferedFraction * 100).toStringAsFixed(0)}% at ${_formatBytes(_message.transferSpeedBytesPerSecond.round())}/s.';
    }
    if (_message.transferStatus == TransferStatus.paused) {
      return 'Stream paused at ${(_appBufferedFraction * 100).toStringAsFixed(0)}%.';
    }
    return 'Waiting for incoming video data.';
  }

  String get _externalPlayerStatus {
    if (_playbackSource == null) return 'Preparing the stream session.';
    if (!_hasEnoughInitialBuffer) {
      return 'Buffering enough video before opening an installed player.';
    }
    if (_isLaunchingExternalPlayer) return 'Opening video player...';
    if (ExternalVideoLauncher.usesAndroidIntent) {
      return 'Open this video with VLC or another installed player.';
    }
    return 'Use your default app, choose a player, or reuse the last selected player.';
  }

  List<Widget> _buildExternalPlayerActions() {
    final enabled = _canOpenExternalPlayer && !_isLaunchingExternalPlayer;
    if (ExternalVideoLauncher.usesAndroidIntent) {
      return <Widget>[
        ElevatedButton.icon(
          onPressed: enabled ? _openDefaultExternalPlayer : null,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open with installed player'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.lightBlueAccent,
            foregroundColor: Colors.black,
          ),
        ),
      ];
    }

    return <Widget>[
      OutlinedButton.icon(
        onPressed: enabled ? _openDefaultExternalPlayer : null,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Default app'),
      ),
      ElevatedButton.icon(
        onPressed: enabled ? _chooseExternalPlayer : null,
        icon: const Icon(Icons.video_library_outlined, size: 18),
        label: const Text('Choose app'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.lightBlueAccent,
          foregroundColor: Colors.black,
        ),
      ),
      if (_hasPreferredExternalPlayer)
        TextButton.icon(
          onPressed: enabled ? _openPreferredExternalPlayer : null,
          icon: const Icon(Icons.history, size: 18),
          label: const Text('Last player'),
        ),
    ];
  }
}

class _StatusPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool showSpinner;
  final List<Widget> actions;

  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.showSpinner = false,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF071827),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.lightBlueAccent),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (showSpinner) ...[
              const SizedBox(height: 18),
              const CircularProgressIndicator(color: Colors.lightBlueAccent),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
