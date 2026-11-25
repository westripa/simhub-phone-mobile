import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/phone_models.dart';

/// Local persistence for call history. The native SIP core can outlive the
/// Flutter UI, so the UI records calls while it is attached; replacing this
/// with service-side recording is a separate step.
abstract class CallHistoryStore {
  Future<List<CallRecord>> load();
  Future<void> save(List<CallRecord> records);
}

/// Uses the existing native bridge. Keeping the JSON in Android
/// SharedPreferences avoids adding a Flutter plugin and its Gradle downloads.
class NativeCallHistoryStore implements CallHistoryStore {
  static const _channel = MethodChannel('simhub.phone/core');

  @override
  Future<List<CallRecord>> load() async {
    try {
      final raw = await _channel.invokeMethod<String>('loadHistory');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((item) => CallRecord.fromJson(Map<String, Object?>.from(item)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<CallRecord> records) async {
    try {
      await _channel.invokeMethod<void>('saveHistory', {
        'json': jsonEncode(records.map((record) => record.toJson()).toList()),
      });
    } catch (_) {
      // The prototype should keep working if local storage is unavailable.
    }
  }
}
