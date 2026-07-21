import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'app_log.dart';
import 'nostr_service.dart';
import 'sync_service.dart';
import 'twitter_service.dart';

/// Queue for every outgoing event that couldn't be sent (offline, expired
/// token, API error, no relay reachable): tweets and signed Nostr events
/// alike. Nothing is ever dropped silently: a failed send lands here, the
/// home screen shows an outbox icon while anything is pending, and items are
/// retried on each sync or on demand.
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  final _db = AppDatabase.instance;

  /// Test seams; default to the app's real clients.
  @visibleForTesting
  TwitterService? debugTwitter;
  @visibleForTesting
  Future<int> Function(Map<String, dynamic> event)? debugNostrPublish;

  TwitterService get _twitter =>
      debugTwitter ?? SyncService.instance.twitter;

  Future<int> _publishNostr(Map<String, dynamic> event) =>
      (debugNostrPublish ?? NostrService().publish)(event);

  /// Number of queued items, for the home screen's outbox badge.
  final ValueNotifier<int> pending = ValueNotifier(0);

  Future<List<OutboxItem>> items() => _db.outboxItems();

  Future<void> refreshCount() async {
    try {
      pending.value = (await _db.outboxItems()).length;
    } catch (_) {
      // Database unavailable; keep the previous count.
    }
  }

  /// Queues a tweet whose post just failed.
  Future<void> enqueueTweet(String text,
      {String? quoteTweetId, required String error}) async {
    await _db.insertOutboxItem(OutboxItem(
      text: text,
      quoteTweetId: quoteTweetId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      attempts: 1,
      lastError: error,
    ));
    await AppLogService.instance
        .info('Twitter: tweet saved to outbox after failure: $error');
    await refreshCount();
  }

  /// Queues a signed Nostr event (profile update, shared highlight) that no
  /// relay accepted. Signed events stay valid, so they re-send verbatim.
  Future<void> enqueueNostrEvent(Map<String, dynamic> event,
      {required String description, required String error}) async {
    await _db.insertOutboxItem(OutboxItem(
      kind: 'nostr',
      text: description,
      payload: jsonEncode(event),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      attempts: 1,
      lastError: error,
    ));
    await AppLogService.instance
        .info('Nostr: event saved to outbox after failure: $error');
    await refreshCount();
  }

  Future<void> delete(int id) async {
    await _db.deleteOutboxItem(id);
    await refreshCount();
  }

  /// Tries to send everything queued. Returns (sent, stillPending).
  Future<(int, int)> flush() async {
    final queued = await _db.outboxItems();
    var sent = 0;
    for (final item in queued) {
      try {
        if (item.kind == 'nostr') {
          final event =
              jsonDecode(item.payload!) as Map<String, dynamic>;
          final accepted = await _publishNostr(event);
          if (accepted == 0) {
            throw Exception('no relay accepted the event');
          }
        } else {
          await _twitter.postTweet(item.text,
              quoteTweetId: item.quoteTweetId);
        }
        await _db.deleteOutboxItem(item.id!);
        sent++;
      } catch (e) {
        await _db.recordOutboxAttempt(item.id!, '$e');
        await AppLogService.instance
            .warn('Outbox: retry failed for ${item.kind} #${item.id}: $e');
      }
    }
    await refreshCount();
    if (queued.isNotEmpty) {
      await AppLogService.instance
          .info('Outbox: flush sent $sent of ${queued.length}');
    }
    return (sent, queued.length - sent);
  }
}
