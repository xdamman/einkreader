import 'dart:async';
import 'dart:io';

import 'app_log.dart';

/// Turns an exception into a message a reader can act on. The full error
/// goes to the debug log for advanced users; the screen only says whether
/// it's a connection problem or something to report.
String friendlyError(Object error, {required String doing}) {
  // Fire-and-forget: logging must never block or break the message.
  AppLogService.instance.warn('Error while $doing: $error');
  if (looksOffline(error)) {
    return "You're offline — $doing needs a connection. "
        'It will work again once you are back online.';
  }
  return 'Something went wrong while $doing — '
      'details are in the debug log.';
}

/// Whether an error (or error string) is a network-connectivity failure.
bool looksOffline(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable') ||
      text.contains('Connection refused') ||
      text.contains('Connection reset') ||
      text.contains('Connection closed') ||
      text.contains('TimeoutException');
}
