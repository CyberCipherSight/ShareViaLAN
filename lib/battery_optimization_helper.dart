import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_platform_channel.dart';

enum BatteryOptimizationPromptReason { setup, activeTransfer, connectionLost }

class BatteryOptimizationHelper {
  static const _dontAskKey = 'lancom.battery_optimization.dont_ask';
  static const _hasPromptedKey = 'lancom.battery_optimization.has_prompted';
  static const _lastPromptedAtKey =
      'lancom.battery_optimization.last_prompted_at';

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static Future<bool> isOptimizationEnabled() async {
    if (!isAndroid) return false;
    try {
      return !await LanPlatformChannel.isIgnoringAndroidBatteryOptimizations();
    } catch (error) {
      debugPrint('Battery optimization platform check failed: $error');
      return false;
    }
  }

  static Future<bool> shouldShowPrompt(
    BatteryOptimizationPromptReason reason,
  ) async {
    if (!isAndroid || !await isOptimizationEnabled()) return false;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_dontAskKey) == true) return false;

    final hasPrompted = prefs.getBool(_hasPromptedKey) ?? false;
    final lastPromptedAtMs = prefs.getInt(_lastPromptedAtKey);
    final lastPromptedAt = lastPromptedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastPromptedAtMs);
    final now = DateTime.now();

    return switch (reason) {
      BatteryOptimizationPromptReason.setup => !hasPrompted,
      BatteryOptimizationPromptReason.activeTransfer =>
        !hasPrompted ||
            lastPromptedAt == null ||
            now.difference(lastPromptedAt) >= const Duration(days: 7),
      BatteryOptimizationPromptReason.connectionLost =>
        lastPromptedAt == null ||
            now.difference(lastPromptedAt) >= const Duration(days: 1),
    };
  }

  static Future<void> markPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasPromptedKey, true);
    await prefs.setInt(
      _lastPromptedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<void> dontAskAgain() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dontAskKey, true);
    await markPromptShown();
  }

  static Future<bool> openBatterySettings() async {
    if (!isAndroid) return false;
    await markPromptShown();

    try {
      return await LanPlatformChannel.openAndroidBatteryOptimizationSettings();
    } catch (error) {
      debugPrint('Battery optimization settings open failed: $error');
      return false;
    }
  }
}

class BatteryOptimizationBanner extends StatefulWidget {
  final BatteryOptimizationPromptReason reason;
  final VoidCallback? onDismissed;

  const BatteryOptimizationBanner({
    super.key,
    required this.reason,
    this.onDismissed,
  });

  @override
  State<BatteryOptimizationBanner> createState() =>
      _BatteryOptimizationBannerState();
}

class _BatteryOptimizationBannerState extends State<BatteryOptimizationBanner> {
  bool _visible = false;
  bool _openingSettings = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant BatteryOptimizationBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reason != widget.reason) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final visible = await BatteryOptimizationHelper.shouldShowPrompt(
      widget.reason,
    );
    if (!mounted) return;
    setState(() => _visible = visible);
    if (visible) {
      unawaited(BatteryOptimizationHelper.markPromptShown());
    }
  }

  Future<void> _openSettings() async {
    if (_openingSettings) return;
    setState(() => _openingSettings = true);
    final opened = await BatteryOptimizationHelper.openBatterySettings();
    if (!mounted) return;
    setState(() => _openingSettings = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? 'Battery settings opened.'
              : 'Could not open battery settings on this device.',
        ),
      ),
    );
  }

  Future<void> _dontAskAgain() async {
    await BatteryOptimizationHelper.dontAskAgain();
    if (!mounted) return;
    setState(() => _visible = false);
    widget.onDismissed?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.battery_saver_outlined, color: Colors.amberAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'For stable transfers while screen is off, allow ShareViaLAN to run in background.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _openingSettings ? null : _openSettings,
                icon: _openingSettings
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.settings_outlined, size: 18),
                label: const Text('Open Battery Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                ),
              ),
              TextButton(
                onPressed: _dontAskAgain,
                child: const Text("Don't ask again"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
