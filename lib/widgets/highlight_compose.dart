import 'package:flutter/material.dart';

/// What the reader decided in the highlight dialog.
class HighlightComposeResult {
  final String comment;

  /// Publish to the public profile (default off: a highlight is private).
  final bool shareToProfile;

  /// Additionally open the tweet composer (only offered while sharing).
  final bool shareToTwitter;

  const HighlightComposeResult({
    this.comment = '',
    this.shareToProfile = false,
    this.shareToTwitter = false,
  });
}

/// Dialog shown when saving a highlight: the selected passage, an optional
/// comment, and — Instagram-style — a primary "share to profile" toggle with
/// cross-post toggles under it. Everything defaults to private: plain Save
/// keeps the highlight (and comment) as a local note.
class HighlightComposeDialog extends StatefulWidget {
  final String selection;

  /// Whether the share toggles are available at all.
  final bool profileEnabled;
  final bool twitterConnected;

  const HighlightComposeDialog({
    super.key,
    required this.selection,
    required this.profileEnabled,
    required this.twitterConnected,
  });

  static Future<HighlightComposeResult?> show(
    BuildContext context, {
    required String selection,
    required bool profileEnabled,
    required bool twitterConnected,
  }) =>
      showDialog<HighlightComposeResult>(
        context: context,
        builder: (context) => HighlightComposeDialog(
          selection: selection,
          profileEnabled: profileEnabled,
          twitterConnected: twitterConnected,
        ),
      );

  @override
  State<HighlightComposeDialog> createState() =>
      _HighlightComposeDialogState();
}

class _HighlightComposeDialogState extends State<HighlightComposeDialog> {
  final _comment = TextEditingController();
  bool _shareToProfile = false;
  bool _shareToTwitter = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: const Text('Highlight'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.only(left: 12),
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(width: 3)),
                ),
                child: Text(
                  widget.selection,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _comment,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Add a comment (optional)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              if (widget.profileEnabled) ...[
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Share to profile'),
                  subtitle: const Text(
                      'Off: stays a private note on this device'),
                  value: _shareToProfile,
                  onChanged: (v) => setState(() {
                    _shareToProfile = v;
                    if (!v) _shareToTwitter = false;
                  }),
                ),
                if (_shareToProfile && widget.twitterConnected)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Also share on Twitter'),
                    value: _shareToTwitter,
                    onChanged: (v) => setState(() => _shareToTwitter = v),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(HighlightComposeResult(
            comment: _comment.text.trim(),
            shareToProfile: _shareToProfile,
            shareToTwitter: _shareToTwitter,
          )),
          child: Text(_shareToProfile ? 'Save & share' : 'Save',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
