import 'package:flutter/material.dart';

/// How long a notice stays at the bottom of the screen before it goes away
/// by itself — with or without an action such as Undo.
const kNoticeDuration = Duration(seconds: 5);

/// The bar for a notice: [message], plus an optional [action]. Flutter keeps
/// a bar with an action up until it is tapped, so `persist: false` makes
/// every notice leave after [kNoticeDuration] the same way.
SnackBar noticeBar(String message, {SnackBarAction? action}) => SnackBar(
  content: Text(message),
  action: action,
  duration: kNoticeDuration,
  persist: false,
);

/// The app's one way to show a short message at the bottom of the screen,
/// so they all behave alike: a new notice replaces the one on screen rather
/// than queueing behind it, and each goes away after [kNoticeDuration].
extension Notices on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showNotice(
    String message, {
    SnackBarAction? action,
  }) {
    hideCurrentSnackBar();
    return showSnackBar(noticeBar(message, action: action));
  }
}

/// [Notices.showNotice] on the messenger of [context].
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showNotice(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) => ScaffoldMessenger.of(context).showNotice(message, action: action);
