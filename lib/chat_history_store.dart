import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

const _historyBoxName = 'lancom.chat_history.v1';
const _persistenceBoxName = 'lancom.chat_persistence.v1';
const _persistentKeysEntry = 'persistent_keys';

class ChatHistoryStore {
  static Future<void>? _hiveInitialization;

  Box<dynamic>? _historyBox;
  Box<dynamic>? _persistenceBox;

  Future<void> initialize() async {
    await ensureHiveInitialized();
    _historyBox ??= await Hive.openBox<dynamic>(_historyBoxName);
    _persistenceBox ??= await Hive.openBox<dynamic>(_persistenceBoxName);
  }

  static Future<void> ensureHiveInitialized() {
    return _hiveInitialization ??= _initializeHive();
  }

  static Future<void> _initializeHive() async {
    if (kIsWeb) return;
    try {
      final directory = await getApplicationSupportDirectory();
      Hive.init('${directory.path}${Platform.pathSeparator}hive');
    } catch (_) {
      final directory = await Directory.systemTemp.createTemp('lancom_hive_');
      Hive.init(directory.path);
    }
  }

  Future<Set<String>> loadPersistentKeys() async {
    await initialize();
    final raw = _persistenceBox?.get(_persistentKeysEntry);
    if (raw is List) {
      return raw.map((entry) => entry.toString()).toSet();
    }
    return <String>{};
  }

  Future<void> setPersistent(String conversationKey, bool enabled) async {
    await initialize();
    final keys = await loadPersistentKeys();
    if (enabled) {
      keys.add(conversationKey);
    } else {
      keys.remove(conversationKey);
    }
    await _persistenceBox?.put(
      _persistentKeysEntry,
      keys.toList(growable: false),
    );
  }

  Future<List<Map<String, dynamic>>> loadMessages(
      String conversationKey) async {
    await initialize();
    final raw = _historyBox?.get(conversationKey);
    if (raw is! List) return const <Map<String, dynamic>>[];

    final messages = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        messages.add(entry);
      } else if (entry is Map) {
        messages.add(Map<String, dynamic>.from(entry));
      }
    }
    return messages;
  }

  Future<void> saveMessages(
    String conversationKey,
    List<Map<String, dynamic>> messages,
  ) async {
    await initialize();
    await _historyBox?.put(conversationKey, messages);
  }

  Future<void> clearMessages(String conversationKey) async {
    await initialize();
    await _historyBox?.delete(conversationKey);
  }
}
