import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'app_log.dart';
import 'sync_service.dart';
import 'twitter_service.dart';

/// Queue of tweets that couldn't be posted (offline, expired token, API
/// error). Nothing is ever dropped silently: a failed post lands here, the
/// home screen shows an outbox icon while anything is pending, and items are
/// retried on each sync or on demand.
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  final _db = AppDatabase.instance;

  /// Test seam; defaults to the app's Twitter client.
  @visibleForTesting
  TwitterService? debugTwitter;

  TwitterService get _twitter =>
      debugTwitter ?? SyncService.instance.twitter;

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
        await _twitter.postTweet(item.text,
            quoteTweetId: item.quoteTweetId);
        await _db.deleteOutboxItem(item.id!);
        sent++;
      } catch (e) {
        await _db.recordOutboxAttempt(item.id!, '$e');
        await AppLogService.instance
            .warn('Twitter: outbox retry failed for #${item.id}: $e');
      }
    }
    await refreshCount();
    if (queued.isNotEmpty) {
      await AppLogService.instance.info(
          'Twitter: outbox flush sent $sent of ${queued.length}');
    }
    return (sent, queued.length - sent);
  }
}
