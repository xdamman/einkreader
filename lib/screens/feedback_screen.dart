import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/errors.dart';
import '../services/feedback_service.dart';
import '../services/nostr_service.dart';
import '../widgets/markdown_view.dart';
import 'nostr_profile_screen.dart';
import 'profile_screen.dart';

/// Public feedback about the app: Nostr notes addressed to einkreader's
/// official account, newest first. Anyone's notes show; posting, replying
/// and reacting use the reader's own profile key.
class FeedbackScreen extends StatefulWidget {
  /// Test seam: a fake service stands in for the relays.
  final FeedbackService? service;

  const FeedbackScreen({super.key, this.service});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late final FeedbackService _service = widget.service ?? FeedbackService();
  List<FeedbackNote>? _notes;
  Map<String, int> _replyCounts = {};
  String? _me;
  bool _canPost = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final canPost = await _service.canPost;
      final me = await _service.myPubkey;
      final result = await _service.feedback();
      if (!mounted) return;
      setState(() {
        _canPost = canPost;
        _me = me;
        _notes = result.notes;
        _replyCounts = result.replyCounts;
      });
      // Names and avatars fill in as they arrive.
      await NostrProfileCache.load(result.notes.map((n) => n.pubkey),
          nostr: _service.nostr);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, doing: 'loading feedback'));
    }
  }

  Future<void> _newFeedback() async {
    final note = await openNewFeedback(context, service: _service);
    if (note == null || !mounted) return;
    setState(() => _notes = [note, ...?_notes]);
  }

  Future<void> _openThread(FeedbackNote note) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FeedbackThreadScreen(
            root: note, service: _service)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Public notes to einkreader on Nostr. Report a bug, '
                    'suggest an idea, or reply to others.',
                    style: TextStyle(fontSize: 15, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('New feedback'),
                    style: OutlinedButton.styleFrom(
                        side: const BorderSide(width: 1.5)),
                    onPressed: _newFeedback,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
            else if (notes == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (notes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No feedback yet — be the first.'),
              )
            else
              for (final note in notes) ...[
                FeedbackNoteTile(
                  note: note,
                  me: _me,
                  canPost: _canPost,
                  service: _service,
                  replyCount: _replyCounts[note.id] ?? 0,
                  onTap: () => _openThread(note),
                  onReply: () => _openThread(note),
                  onChanged: () => setState(() {}),
                ),
                const Divider(height: 1),
              ],
          ],
        ),
      ),
    );
  }
}

/// A feedback note and its replies. Replying targets the root by default;
/// "Reply" on any reply answers that one instead.
class FeedbackThreadScreen extends StatefulWidget {
  final FeedbackNote root;
  final FeedbackService? service;

  const FeedbackThreadScreen({super.key, required this.root, this.service});

  @override
  State<FeedbackThreadScreen> createState() => _FeedbackThreadScreenState();
}

class _FeedbackThreadScreenState extends State<FeedbackThreadScreen> {
  late final FeedbackService _service = widget.service ?? FeedbackService();
  late List<FeedbackNote> _notes = [widget.root];
  late FeedbackNote _replyTo = widget.root;
  final _controller = TextEditingController();
  String? _me;
  bool _canPost = false;
  bool _sending = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final canPost = await _service.canPost;
      final me = await _service.myPubkey;
      final notes = await _service.thread(widget.root.id);
      if (!mounted) return;
      setState(() {
        _canPost = canPost;
        _me = me;
        if (notes.isNotEmpty) _notes = notes;
        _loading = false;
      });
      await NostrProfileCache.load(notes.map((n) => n.pubkey),
          nostr: _service.nostr);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'loading the thread'))));
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await _service.reply(_replyTo, text);
      // Fetched in the background: the reply shows at once.
      NostrProfileCache.load([note.pubkey], nostr: _service.nostr).then((_) {
        if (mounted) setState(() {});
      });
      _controller.clear();
      if (!mounted) return;
      setState(() {
        _notes = [..._notes, note];
        _replyTo = widget.root;
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'sending your reply'))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback thread')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final note in _notes) ...[
                  Padding(
                    // Answers to a reply (not to the root) sit indented.
                    padding: EdgeInsets.only(
                        left: note.id != widget.root.id &&
                                note.replyToId != widget.root.id
                            ? 28
                            : 0),
                    child: FeedbackNoteTile(
                      note: note,
                      me: _me,
                      canPost: _canPost,
                      service: _service,
                      large: note.id == widget.root.id,
                      replyingTo: note.id != widget.root.id &&
                              note.replyToId != widget.root.id
                          ? _notes
                              .where((n) => n.id == note.replyToId)
                              .firstOrNull
                              ?.pubkey
                          : null,
                      onReply: () async {
                        if (!await ensureCanPost(context, _service)) return;
                        setState(() {
                          _canPost = true;
                          _replyTo = note;
                        });
                      },
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const Divider(height: 1),
                ],
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _composer() {
    if (!_canPost) {
      return Container(
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(width: 1.5))),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Expanded(child: Text('Set up your profile to reply.')),
            OutlinedButton(
              onPressed: () async {
                if (await ensureCanPost(context, _service) && mounted) {
                  setState(() => _canPost = true);
                }
              },
              child: const Text('Set up'),
            ),
          ],
        ),
      );
    }
    final replyingToOther = _replyTo.id != widget.root.id;
    return Container(
      decoration:
          const BoxDecoration(border: Border(top: BorderSide(width: 1.5))),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (replyingToOther)
              Row(
                children: [
                  Expanded(
                    child: Text(
                        'Replying to ${nostrDisplayName(_replyTo.pubkey)}',
                        style: const TextStyle(fontSize: 13)),
                  ),
                  IconButton(
                    tooltip: 'Reply to the thread instead',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        setState(() => _replyTo = widget.root),
                  ),
                ],
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Write a reply…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                  onPressed: _sending ? null : _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One note: avatar and name (both open the author's profile), time, text,
/// emoji reactions (tap one to add yours) and actions.
class FeedbackNoteTile extends StatelessWidget {
  final FeedbackNote note;
  final String? me;
  final bool canPost;
  final FeedbackService service;
  final int? replyCount;
  final bool large;

  /// Pubkey of the reply's parent, shown as "replying to …" when the note
  /// answers a reply rather than the thread's root.
  final String? replyingTo;
  final VoidCallback? onTap;
  final VoidCallback onReply;
  final VoidCallback onChanged;

  const FeedbackNoteTile({
    super.key,
    required this.note,
    required this.me,
    required this.canPost,
    required this.service,
    required this.onReply,
    required this.onChanged,
    this.replyCount,
    this.large = false,
    this.replyingTo,
    this.onTap,
  });

  Future<void> _react(BuildContext context, String emoji) async {
    final mine = me != null && (note.reactions[emoji]?.contains(me) ?? false);
    if (mine) return;
    if (!await ensureCanPost(context, service)) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final myKey = me ?? await service.myPubkey;
    // Optimistic: the chip updates at once; undone if no relay accepts it.
    if (myKey != null) {
      note.reactions.putIfAbsent(emoji, () => <String>{}).add(myKey);
      onChanged();
    }
    try {
      await service.react(note, emoji);
    } catch (e) {
      if (myKey != null) {
        note.reactions[emoji]?.remove(myKey);
        if (note.reactions[emoji]?.isEmpty ?? false) {
          note.reactions.remove(emoji);
        }
        onChanged();
      }
      messenger.showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'sending your reaction'))));
    }
  }

  /// The emoji picker: a small menu at the button with the reader's most
  /// used emojis in one row, plus "Other…" for any emoji.
  Future<void> _pickReaction(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final emojis = await FeedbackService.quickEmojis();
    if (!buttonContext.mounted) return;
    final picked = await showMenu<String>(
      context: buttonContext,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      position: RelativeRect.fromRect(
          origin & box.size, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<String>(
          height: 52,
          child: Builder(
            builder: (menuContext) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final emoji in emojis)
                  InkWell(
                    onTap: () => Navigator.pop(menuContext, emoji),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(emoji, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const PopupMenuItem<String>(value: '', child: Text('Other…')),
      ],
    );
    if (picked == null || !buttonContext.mounted) return;
    var emoji = picked;
    if (emoji.isEmpty) {
      emoji = await composeNote(buttonContext,
              title: 'React with', hint: 'Any emoji', action: 'React',
              singleLine: true) ??
          '';
    }
    if (emoji.trim().isEmpty || !buttonContext.mounted) return;
    await _react(buttonContext, emoji.trim());
  }

  @override
  Widget build(BuildContext context) {
    final name = nostrDisplayName(note.pubkey);
    final sortedReactions = note.reactions.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openNostrProfile(context, note.pubkey),
              child: NostrAvatar(pubkey: note.pubkey, size: large ? 48 : 40),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => openNostrProfile(context, note.pubkey),
                        child: Text(name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      Text('  ·  ${relativeTime(note.createdAt)}',
                          style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                  if (replyingTo != null)
                    GestureDetector(
                      onTap: () => openNostrProfile(context, replyingTo!),
                      child: Text('replying to ${nostrDisplayName(replyingTo!)}',
                          style: const TextStyle(
                              fontSize: 13, fontStyle: FontStyle.italic)),
                    ),
                  const SizedBox(height: 4),
                  if (note.subject != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(note.subject!,
                          style: TextStyle(
                              fontSize: large ? 20 : 17,
                              fontWeight: FontWeight.w700)),
                    ),
                  if (note.displayText.isNotEmpty)
                    MarkdownView(
                        markdown: note.displayText,
                        fontSize: large ? 18 : 16),
                  for (final image in note.images)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: large ? 480 : 240),
                        child: Container(
                          decoration:
                              BoxDecoration(border: Border.all(width: 1)),
                          child: Image.network(image,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text('[screenshot: $image]',
                                        style:
                                            const TextStyle(fontSize: 13)),
                                  )),
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final entry in sortedReactions)
                        _ReactionChip(
                          emoji: entry.key,
                          count: entry.value.length,
                          mine: me != null && entry.value.contains(me),
                          onTap: () => _react(context, entry.key),
                        ),
                      Builder(
                        builder: (buttonContext) => IconButton(
                          tooltip: 'React',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_reaction_outlined,
                              size: 20),
                          onPressed: () => _pickReaction(buttonContext),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.reply, size: 18),
                        label: Text(replyCount == null || replyCount == 0
                            ? 'Reply'
                            : '$replyCount repl${replyCount == 1 ? 'y' : 'ies'}'),
                        onPressed: onReply,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          // Solid outline = you reacted with this one (no color on e-ink).
          border: Border.all(width: mine ? 2 : 1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text('$emoji $count',
            style: TextStyle(
                fontSize: 15,
                fontWeight: mine ? FontWeight.w700 : FontWeight.w400)),
      ),
    );
  }
}

/// Makes sure the reader has a Nostr identity before posting or reacting:
/// explains why one is needed and opens the profile setup when accepted.
Future<bool> ensureCanPost(
    BuildContext context, FeedbackService service) async {
  if (await service.canPost) return true;
  if (!context.mounted) return false;
  final setUp = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: const Text('Set up your profile first'),
      content: const Text(
          'Feedback is posted publicly on Nostr under your einkreader '
          'profile. It takes a few seconds to create one.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now')),
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Set up profile')),
      ],
    ),
  );
  if (setUp != true || !context.mounted) return false;
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
  return service.canPost;
}

/// A text dialog for writing a note (or typing an emoji). Returns the
/// trimmed text, or null when cancelled or empty.
Future<String?> composeNote(
  BuildContext context, {
  required String title,
  required String hint,
  required String action,
  bool singleLine = false,
}) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: singleLine ? 1 : 4,
          maxLines: singleLine ? 1 : 10,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(action)),
      ],
    ),
  );
  // Not disposed here: the dialog's field may still be animating out and
  // reading it; it is garbage-collected with the closure.
  return (text == null || text.isEmpty) ? null : text;
}


/// Opens the new-feedback form (after making sure the reader has a
/// profile to post with). [url] prefills the link, e.g. the article the
/// feedback is about. Returns the posted note, or null.
Future<FeedbackNote?> openNewFeedback(BuildContext context,
    {FeedbackService? service, String? url, String? subject}) async {
  final feedback = service ?? FeedbackService();
  if (!await ensureCanPost(context, feedback)) return null;
  if (!context.mounted) return null;
  return Navigator.of(context).push<FeedbackNote>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) =>
        NewFeedbackScreen(service: feedback, url: url, subject: subject),
  ));
}

/// The new-feedback form: subject, body, optional link and screenshot,
/// with a plain warning that everything posted is public and a clear
/// "Posting as" line naming the profile that signs it.
class NewFeedbackScreen extends StatefulWidget {
  final FeedbackService service;
  final String? url;
  final String? subject;

  /// Test seam: returns picked image bytes instead of the system picker.
  @visibleForTesting
  static Future<Uint8List?> Function()? debugPickImage;

  const NewFeedbackScreen(
      {super.key, required this.service, this.url, this.subject});

  @override
  State<NewFeedbackScreen> createState() => _NewFeedbackScreenState();
}

class _NewFeedbackScreenState extends State<NewFeedbackScreen> {
  late final _subject = TextEditingController(text: widget.subject ?? '');
  final _body = TextEditingController();
  late final _url = TextEditingController(text: widget.url ?? '');
  Uint8List? _screenshot;
  ({String name, String? address, String npub, String picture})? _identity;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    widget.service.identity().then((identity) {
      if (mounted) setState(() => _identity = identity);
    });
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pickScreenshot() async {
    final pick = NewFeedbackScreen.debugPickImage ??
        () async => (await FilePicker.platform
                .pickFiles(type: FileType.image, withData: true))
            ?.files
            .single
            .bytes;
    final bytes = await pick();
    if (bytes != null && mounted) setState(() => _screenshot = bytes);
  }

  Future<void> _post() async {
    if (_subject.text.trim().isEmpty && _body.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add a subject or a few words first')));
      return;
    }
    setState(() => _posting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final shot = _screenshot;
      final imageUrl =
          shot == null ? null : await widget.service.uploadScreenshot(shot);
      final note = await widget.service.post(_body.text,
          subject: _subject.text, url: _url.text, imageUrl: imageUrl);
      // Our own name and picture are already known: no relay round trip
      // before the form closes.
      final me = _identity;
      if (me != null) {
        NostrProfileCache.put(NostrProfile(
            pubkey: note.pubkey, name: me.name, picture: me.picture));
      }
      messenger.showSnackBar(
          const SnackBar(content: Text('Feedback posted — thank you!')));
      navigator.pop(note);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'posting feedback'))));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    final name = identity == null
        ? '…'
        : identity.name.isNotEmpty
            ? identity.name
            : 'your einkreader profile';
    final shortNpub = identity == null
        ? ''
        : '${identity.npub.substring(0, 12)}…'
            '${identity.npub.substring(identity.npub.length - 4)}';
    return Scaffold(
      appBar: AppBar(
        title: const Text('New feedback'),
        actions: [
          TextButton(
            onPressed: _posting ? null : _post,
            child: Text(_posting ? 'Posting…' : 'Post publicly',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(width: 1.5)),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.public, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Feedback is public: anyone can read it on Nostr, and '
                    'it can\'t be fully deleted once posted. Don\'t include '
                    'personal information — no email addresses, phone '
                    'numbers, home addresses or private messages — and '
                    'check your screenshot for any.',
                    style: TextStyle(fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Which identity signs this: the active profile.
          Row(
            children: [
              ClipOval(
                child: (identity?.picture ?? '').isEmpty
                    ? const Icon(Icons.account_circle_outlined, size: 40)
                    : Image.network(identity!.picture,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.account_circle_outlined,
                            size: 40)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Posting as $name',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    if (identity != null)
                      Text(
                          [
                            if (identity.address != null) identity.address!,
                            shortNpub,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Your profile name and picture show next to your feedback. '
            'Switch profiles from the profile icon on the home screen.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _subject,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Subject', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 12,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What happened, or what would you like?',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Link (optional)',
              hintText: 'The article or page this is about',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          if (_screenshot == null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Attach a screenshot'),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(width: 1.5)),
                onPressed: _pickScreenshot,
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(border: Border.all(width: 1)),
                  child: Image.memory(_screenshot!,
                      height: 160, fit: BoxFit.contain),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.close),
                  label: const Text('Remove'),
                  onPressed: () => setState(() => _screenshot = null),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
