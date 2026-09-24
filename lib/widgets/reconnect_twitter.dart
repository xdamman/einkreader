import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/add_source_screen.dart';
import '../services/errors.dart';
import '../services/outbox_service.dart';
import '../services/sync_service.dart';

/// Whether an error is one that reconnecting the Twitter account fixes (an
/// expired session, a connection made before posting was allowed). Every
/// such message tells the reader to reconnect, so wherever it is shown the
/// app must also offer the button that does it — never leave the reader to
/// work out where reconnecting lives.
bool needsTwitterReconnect(Object? error) =>
    error != null && error.toString().toLowerCase().contains('reconnect');

/// Reruns the Twitter OAuth flow in place, reusing the client id from the
/// original connection (falls back to the Add source screen, which asks
/// for one, when this install has none). On success, anything waiting in
/// the outbox — typically the post that failed — is sent right away.
/// Reports the outcome on [messenger]; returns true when connected.
Future<bool> reconnectTwitter({
  required ScaffoldMessengerState messenger,
  required NavigatorState navigator,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final clientId = prefs.getString('twitter_client_id') ?? '';
  if (clientId.isEmpty) {
    await navigator.push(
        MaterialPageRoute(builder: (_) => const AddSourceScreen()));
    return false;
  }
  try {
    final username = await SyncService.instance.twitter.connect(clientId);
    final (sent, _) = await OutboxService.instance.flush();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text('Reconnected as @$username'
            '${sent > 0 ? ' — sent $sent waiting item${sent == 1 ? '' : 's'}' : ''}')));
    return true;
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(friendlyError(e, doing: 'reconnecting Twitter'))));
    return false;
  }
}

/// A snackbar "Reconnect" action for a message that asks the reader to
/// reconnect Twitter.
SnackBarAction reconnectTwitterAction({
  required ScaffoldMessengerState messenger,
  required NavigatorState navigator,
}) =>
    SnackBarAction(
      label: 'Reconnect',
      onPressed: () =>
          reconnectTwitter(messenger: messenger, navigator: navigator),
    );
