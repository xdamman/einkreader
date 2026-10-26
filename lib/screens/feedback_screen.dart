import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/errors.dart';
import '../services/feedback_service.dart';
import '../services/nostr_service.dart';
import '../widgets/filter_pill.dart';
import '../widgets/markdown_view.dart';
import '../widgets/notice.dart';
import '../widgets/profile_switcher.dart';
import 'nostr_profile_screen.dart';
import 'profile_screen.dart';

/// Public feedback about the app (Nostr notes addressed to einkreader's
/// official account), newest first. Anyone's notes show; posting, replying
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

  /// Thread root id → replies and reactions to the reader's notes they
  /// haven't seen (opening the thread clears it).
  Map<String, int> _unseen = {};
  String? _me;
  bool _canPost = false;
  String? _error;

  /// A refresh from the relays is running (the app-bar icon spins).
  bool _loading = false;

  /// Only feedback tagged with this kind; null shows all.
  FeedbackKind? _kind;

  /// Newest feedback keeps arriving while the screen is open.
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Shows what's stored locally at once, then asks the relays only for
  /// newer events and updates the list.
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final canPost = await _service.canPost;
      final me = await _service.myPubkey;
      final cached = await _service.cachedFeedback();
      final unseenCached = await _service.unseenByThread();
      await NostrProfileCache.load(cached.notes.map((n) => n.pubkey),
          nostr: _service.nostr);
      if (!mounted) return;
      setState(() {
        _unseen = unseenCached;
        _canPost = canPost;
        _me = me;
        if (cached.notes.isNotEmpty || _notes == null) {
          _notes = cached.notes;
          _replyCounts = cached.replyCounts;
        }
      });
      var fresh = await _service.feedback();
      // Right after opening, relays can be slow to answer and come back
      // empty: try again a couple of times before saying there's nothing.
      for (var attempt = 1; fresh.notes.isEmpty && attempt <= 2; attempt++) {
        await Future<void>.delayed(Duration(seconds: 3 * attempt));
        if (!mounted) return;
        fresh = await _service.feedback();
      }
      final unseen = await _service.unseenByThread();
      await NostrProfileCache.load(fresh.notes.map((n) => n.pubkey),
          nostr: _service.nostr);
      if (!mounted) return;
      setState(() {
        _unseen = unseen;
        _notes = fresh.notes;
        _replyCounts = fresh.replyCounts;
      });
    } catch (e) {
      if (!mounted) return;
      final message = friendlyError(e, doing: 'loading feedback');
      if (_notes?.isNotEmpty ?? false) {
        // Keep showing what we have; just say the refresh failed.
        showNotice(context, message);
      } else {
        setState(() => _error = message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newFeedback() async {
    final posting = await openNewFeedback(context, service: _service);
    if (posting == null || !mounted) return;
    final draft = posting.draft;
    setState(() => _notes = [draft, ...?_notes]);
    // The draft becomes the real note (openable, reactable) once sent.
    final sent = await posting.sent;
    if (!mounted) return;
    setState(() => _notes = [
          for (final n in _notes ?? const <FeedbackNote>[])
            n.id == draft.id ? sent.note : n
        ]);
  }

  Future<void> _openThread(FeedbackNote note) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FeedbackThreadScreen(
            root: note, service: _service)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = _notes;
    final counts = {
      for (final kind in FeedbackKind.values)
        kind: all?.where((n) => n.tags.contains(kind.tag)).length ?? 0,
    };
    final notes = _kind == null
        ? all
        : all?.where((n) => n.tags.contains(_kind!.tag)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback'),
        // No refresh button: the list fetches what's new on opening and
        // every minute while open.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: const Text('New feedback',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              onPressed: _newFeedback,
            ),
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
                    'Public feedback about einkreader. Report a bug, '
                    'suggest an idea, or reply to others.',
                    style: TextStyle(fontSize: 15, height: 1.4),
                  ),
                ],
              ),
            ),
            // The same pills as on the form: tap one to see only that
            // kind, again (or All) to see everything.
            if (counts.values.any((c) => c > 0))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterPill(
                      label: 'All',
                      selected: _kind == null,
                      onTap: () => setState(() => _kind = null),
                    ),
                    for (final kind in FeedbackKind.values)
                      if (counts[kind]! > 0 || _kind == kind)
                        FilterPill(
                          label: '${kind.label} ${counts[kind]}',
                          selected: _kind == kind,
                          onTap: () => setState(
                              () => _kind = _kind == kind ? null : kind),
                        ),
                  ],
                ),
              ),
            const Divider(height: 1),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
            else if (notes == null || (notes.isEmpty && _loading))
              // Loading is shown by the app-bar icon, not a big spinner.
              const SizedBox.shrink()
            else if (notes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_kind == null
                    ? 'No feedback yet — be the first.'
                    : 'No ${_kind!.label.toLowerCase()} yet.'),
              )
            else
              for (final note in notes) ...[
                FeedbackNoteTile(
                  note: note,
                  me: _me,
                  canPost: _canPost,
                  service: _service,
                  replyCount: _replyCounts[note.id] ?? 0,
                  newCount: _unseen[note.id] ?? 0,
                  compact: true,
                  onTap: note.sending ? null : () => _openThread(note),
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

  /// "@Name" picked from the suggestions → pubkey (hex); sent as NIP-27
  /// mentions.
  final Map<String, String> _picked = {};

  /// What follows the "@" being typed, or null when not typing a mention.
  String? _mentionQuery;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _restoreDraft();
    _load();
  }

  /// Brings back the reply left unsent in this thread (on going back, or
  /// when the app was closed).
  Future<void> _restoreDraft() async {
    final draft = await FeedbackService.replyDraft(widget.root.id);
    // Not over something typed meanwhile.
    if (draft == null || !mounted || _controller.text.isNotEmpty) return;
    _picked.addAll(draft.picked);
    _controller.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length));
  }

  /// The text last kept as this thread's draft.
  String _savedDraft = '';

  /// Every change is kept at once: the app can be closed at any moment.
  void _saveDraft() {
    final text = _controller.text;
    if (text == _savedDraft) return;
    _savedDraft = text;
    FeedbackService.saveReplyDraft(widget.root.id, text, picked: _picked);
  }

  void _onTextChanged() {
    _saveDraft();
    final value = _controller.value;
    final cursor = value.selection.baseOffset;
    String? query;
    if (cursor >= 0 && cursor <= value.text.length) {
      final m = RegExp(r'(?:^|\s)@([^\s@]{0,30})$')
          .firstMatch(value.text.substring(0, cursor));
      query = m?.group(1);
    }
    if (query != _mentionQuery) setState(() => _mentionQuery = query);
  }

  /// People to @mention for [query]: those in this thread first, then
  /// everyone else known; names starting with the query before the rest.
  List<NostrProfile> _mentionCandidates(String query) {
    final q = query.toLowerCase();
    final inThread = {
      for (final n in _notes) n.pubkey,
      ..._notes.expand((n) => n.mentioned),
    };
    final seen = <String>{};
    final matches = [
      for (final pubkey in inThread)
        if (NostrProfileCache.get(pubkey) case final p?) p,
      ...NostrProfileCache.all,
    ].where((p) =>
        p.pubkey != _me &&
        p.name.trim().isNotEmpty &&
        p.name.toLowerCase().contains(q) &&
        seen.add(p.pubkey));
    final list = matches.toList();
    final starts = list.where((p) => p.name.toLowerCase().startsWith(q));
    return [...starts, ...list.where((p) => !starts.contains(p))]
        .take(5)
        .toList();
  }

  void _pickMention(NostrProfile profile) {
    final value = _controller.value;
    final cursor = value.selection.baseOffset;
    final before = value.text.substring(0, cursor);
    final at = before.lastIndexOf('@');
    final name = profile.name.trim();
    final inserted = '@$name ';
    final text =
        before.substring(0, at) + inserted + value.text.substring(cursor);
    _picked[name] = profile.pubkey;
    _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: at + inserted.length));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final canPost = await _service.canPost;
      final me = await _service.myPubkey;
      // Stored replies first (instant), then whatever is new.
      final cached = await _service.cachedThread(widget.root.id);
      await NostrProfileCache.load(
          cached.expand((n) => [n.pubkey, ...n.mentioned]),
          nostr: _service.nostr);
      if (!mounted) return;
      setState(() {
        _canPost = canPost;
        _me = me;
        if (cached.isNotEmpty) _notes = cached;
      });
      final notes = await _service.thread(widget.root.id);
      await NostrProfileCache.load(
          notes.expand((n) => [n.pubkey, ...n.mentioned]),
          nostr: _service.nostr);
      if (!mounted) return;
      setState(() {
        if (notes.isNotEmpty) _notes = notes;
        _loading = false;
      });
      // Everything in the thread is now on screen: clear its badge.
      await _service.markThreadSeen(widget.root.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showNotice(context, friendlyError(e, doing: 'loading the thread'));
    }
  }

  Future<void> _send() async {
    final typed = _controller.text.trim();
    if (typed.isEmpty) return;
    final text = FeedbackNote.encodeMentions(typed, _picked);
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await _service.reply(_replyTo, text);
      _picked.clear();
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
      messenger.showNotice(friendlyError(e, doing: 'sending your reply'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Opens the thread in the reader's Nostr app (Primal, Amethyst…) to reply
  /// or react there; without one, in the browser, which offers them all.
  Future<void> _openInNostrApp() async {
    final note = NostrService.noteEncode(widget.root.id);
    try {
      if (await launchUrl(Uri.parse('nostr:$note'),
          mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {}
    await launchUrl(Uri.parse('https://njump.me/$note'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback thread'),
        actions: [
          IconButton(
            tooltip: 'Open in a Nostr app',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openInNostrApp,
          ),
          RefreshAction(loading: _loading, onPressed: _load),
        ],
      ),
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
            if (_mentionQuery != null)
              for (final profile in _mentionCandidates(_mentionQuery!))
                InkWell(
                  onTap: () => _pickMention(profile),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        NostrAvatar(pubkey: profile.pubkey, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(profile.name.trim(),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16)),
                        ),
                      ],
                    ),
                  ),
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
                      hintText: 'Write a reply… (@ to mention)',
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

  /// New replies and reactions to the reader's notes in this thread.
  final int newCount;
  final bool large;

  /// In the list: the text is cut to a few lines and images are left out,
  /// so more feedback fits on the screen; the thread shows it all.
  final bool compact;

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
    this.newCount = 0,
    this.large = false,
    this.compact = false,
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
      note.addReaction(emoji, myKey, DateTime.now());
      onChanged();
    }
    try {
      await service.react(note, emoji);
    } catch (e) {
      if (myKey != null) {
        note.removeReaction(emoji, myKey);
        onChanged();
      }
      messenger.showNotice(friendlyError(e, doing: 'sending your reaction'));
    }
  }

  /// Long press on a reaction: who reacted with it and when, newest
  /// first; tapping someone opens their profile.
  Future<void> _showReactors(BuildContext context, String emoji) async {
    final times = note.reactedAt[emoji] ?? const <String, DateTime>{};
    final people = (note.reactions[emoji] ?? const <String>{}).toList()
      ..sort((a, b) =>
          (times[b] ?? DateTime(0)).compareTo(times[a] ?? DateTime(0)));
    // Names from the store at once; unknown ones fetched (briefly).
    await NostrProfileCache.load(people, nostr: service.nostr)
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                  people.length == 1
                      ? '$emoji  1 reaction'
                      : '$emoji  ${people.length} reactions',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final pubkey in people)
              ListTile(
                leading: NostrAvatar(pubkey: pubkey, size: 36),
                title: Text(pubkey == me
                    ? '${nostrDisplayName(pubkey)} (you)'
                    : nostrDisplayName(pubkey)),
                trailing: times[pubkey] == null
                    ? null
                    : Text(relativeTime(times[pubkey]!),
                        style: const TextStyle(fontSize: 13)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  openNostrProfile(context, pubkey, me: me);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openLink(BuildContext context, String url) {
    final mention = FeedbackNote.mentionPattern.matchAsPrefix(url);
    if (mention != null) {
      openNostrProfile(context, NostrService.decodeNpub(mention.group(1)!),
          me: me);
      return;
    }
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
              onTap: () => openNostrProfile(context, note.pubkey, me: me),
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
                        onTap: () => openNostrProfile(context, note.pubkey, me: me),
                        child: Text(name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      Text('  ·  ${relativeTime(note.createdAt)}',
                          style: const TextStyle(fontSize: 13)),
                      // Its kinds, as tagged when written.
                      for (final kind in FeedbackKind.values)
                        if (note.tags.contains(kind.tag))
                          Text('  ·  ${kind.label}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  if (replyingTo != null)
                    GestureDetector(
                      onTap: () => openNostrProfile(context, replyingTo!, me: me),
                      child: Text('replying to ${nostrDisplayName(replyingTo!)}',
                          style: const TextStyle(
                              fontSize: 13, fontStyle: FontStyle.italic)),
                    ),
                  const SizedBox(height: 4),
                  if (note.subject != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(note.subject!,
                          maxLines: compact ? 2 : null,
                          overflow: compact ? TextOverflow.ellipsis : null,
                          style: TextStyle(
                              fontSize: large ? 20 : 17,
                              fontWeight: FontWeight.w700)),
                    ),
                  if (compact) ...[
                    if (note.displayText.isNotEmpty)
                      Text(
                          plainPreview(FeedbackNote.linkMentions(
                              note.displayText, nostrDisplayName)),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, height: 1.4)),
                    if (note.images.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.image_outlined, size: 16),
                            const SizedBox(width: 4),
                            Text(
                                note.images.length == 1
                                    ? 'Screenshot'
                                    : '${note.images.length} images',
                                style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                  ] else if (note.displayText.isNotEmpty)
                    MarkdownView(
                        markdown: FeedbackNote.linkMentions(
                            note.displayText, nostrDisplayName),
                        fontSize: large ? 18 : 16,
                        onLinkTap: (url, _, __) => _openLink(context, url)),
                  if (!compact && note.images.length == 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: large ? 480 : 240),
                        child: _NoteImage(
                            images: note.images, index: 0, fit: BoxFit.contain),
                      ),
                    )
                  else if (!compact && note.images.length > 1)
                    // Side by side, scrolled sideways: a few pictures don't
                    // push the replies screens away.
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: ImageStrip(
                        height: large ? 260 : 180,
                        count: note.images.length,
                        itemBuilder: (i) =>
                            _NoteImage(images: note.images, index: i),
                      ),
                    ),
                  if (note.sending)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('Sending…',
                          style: TextStyle(
                              fontSize: 13, fontStyle: FontStyle.italic)),
                    )
                  else
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
                            onLongPress: () =>
                                _showReactors(context, entry.key),
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
                        if (newCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('$newCount new',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
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

/// Where note images come from. Test seam: screenshot tests have no
/// network.
@visibleForTesting
ImageProvider Function(String url) noteImageProvider = NetworkImage.new;

/// One of a note's images, outlined; a tap opens them all in the viewer at
/// this one.
class _NoteImage extends StatelessWidget {
  final List<String> images;
  final int index;
  final BoxFit fit;

  const _NoteImage(
      {required this.images, required this.index, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final image = images[index];
    return Container(
      decoration: BoxDecoration(border: Border.all(width: 1)),
      child: GestureDetector(
        onTap: () => showImageGallery(context, [
          for (final url in images)
            Image(
                image: noteImageProvider(url),
                errorBuilder: (_, __, ___) => Text('[screenshot: $url]',
                    style: const TextStyle(fontSize: 13))),
        ], initial: index),
        child: Image(
            image: noteImageProvider(image),
            fit: fit,
            errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('[screenshot: $image]',
                      style: const TextStyle(fontSize: 13)),
                )),
      ),
    );
  }
}

/// Pictures in a row, scrolled sideways with a visible scrollbar (e-ink
/// readers need to see there's more), each [height] tall and 3:4 wide.
class ImageStrip extends StatefulWidget {
  final double height;
  final int count;
  final Widget Function(int index) itemBuilder;

  const ImageStrip(
      {super.key,
      required this.height,
      required this.count,
      required this.itemBuilder});

  @override
  State<ImageStrip> createState() => _ImageStripState();
}

class _ImageStripState extends State<ImageStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height + 14,
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 14),
          itemCount: widget.count,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => SizedBox(
            width: widget.height * 0.75,
            height: widget.height,
            child: widget.itemBuilder(i),
          ),
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

  /// Shows who reacted, and when.
  final VoidCallback onLongPress;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
          'Feedback is posted publicly under your einkreader profile, '
          'with your name and picture. It takes a few seconds to '
          'create one.'),
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
/// feedback is about; [screenshot] (the screen it was opened from) is
/// attached by default and can be removed in one tap. Returns the
/// feedback being sent (the form closes at once), or null.
Future<SentFeedback?> openNewFeedback(BuildContext context,
    {FeedbackService? service,
    String? url,
    String? subject,
    Uint8List? screenshot}) async {
  final feedback = service ?? FeedbackService();
  if (!await ensureCanPost(context, feedback)) return null;
  if (!context.mounted) return null;
  return Navigator.of(context).push<SentFeedback>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => NewFeedbackScreen(
        service: feedback,
        url: url,
        subject: subject,
        screenshot: screenshot),
  ));
}

/// The new-feedback form: subject, body, optional link and screenshot,
/// with a short note that everything posted is public and a "Posting as"
/// line naming the profile that signs it. Switching profiles opens a menu
/// over the form, so whatever was written stays.
class NewFeedbackScreen extends StatefulWidget {
  final FeedbackService service;
  final String? url;
  final String? subject;
  final Uint8List? screenshot;

  /// Test seam: stands in for the profile switcher menu.
  @visibleForTesting
  static Future<void> Function(BuildContext context)? debugSwitchProfile;

  /// Test seam: stands in for the system file picker ("Add images").
  @visibleForTesting
  static Future<List<Uint8List>> Function()? debugPickImages;

  const NewFeedbackScreen(
      {super.key,
      required this.service,
      this.url,
      this.subject,
      this.screenshot});

  @override
  State<NewFeedbackScreen> createState() => _NewFeedbackScreenState();
}

class _NewFeedbackScreenState extends State<NewFeedbackScreen> {
  late final _subject = TextEditingController(text: widget.subject ?? '');
  final _body = TextEditingController();
  late final _url = TextEditingController(text: widget.url ?? '');
  /// Off by default: the page is captured just in case, and attached only
  /// when the reader asks (instantly — it's already there).
  bool _includeScreenshot = false;

  /// Pictures the reader added from the device, in the order picked.
  final List<Uint8List> _images = [];

  /// What it's about (bug, feature request, rendering issue), any number.
  final Set<FeedbackKind> _kinds = {};
  ({String name, String? address, String npub, String picture})? _identity;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _url.addListener(() => setState(() {}));
    _loadIdentity();
  }

  void _loadIdentity() {
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

  Future<void> _switchProfile(BuildContext anchor) async {
    await (NewFeedbackScreen.debugSwitchProfile ?? showProfileSwitcherMenu)(
        anchor);
    if (mounted) _loadIdentity();
  }

  Future<void> _addImages() async {
    final picked = await (NewFeedbackScreen.debugPickImages ?? _pickImages)();
    if (picked.isEmpty || !mounted) return;
    setState(() => _images.addAll(picked));
  }

  static Future<List<Uint8List>> _pickImages() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.image, allowMultiple: true, withData: true);
    return [
      for (final file in result?.files ?? const <PlatformFile>[])
        if (file.bytes case final bytes?) bytes
    ];
  }

  Future<void> _post() async {
    if (_subject.text.trim().isEmpty && _body.text.trim().isEmpty) {
      showNotice(context, 'Add a subject or a few words first');
      return;
    }
    // The profile may have been switched to an empty one meanwhile.
    if (!await ensureCanPost(context, widget.service) || !mounted) return;
    setState(() => _posting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      // Signed locally: the form closes right away while the screenshot
      // uploads and the relays answer in the background.
      final posting = await widget.service.submit(_body.text,
          subject: _subject.text,
          url: _url.text,
          screenshot: _includeScreenshot ? widget.screenshot : null,
          images: _images,
          kinds: _kinds);
      // Our own name and picture are already known: no relay round trip.
      final me = await widget.service.identity();
      NostrProfileCache.put(NostrProfile(
          pubkey: posting.draft.pubkey, name: me.name, picture: me.picture));
      messenger.showNotice('Feedback posted — thank you!');
      posting.sent.then((sent) {
        if (!sent.queued) return;
        messenger.showNotice('No connection — your feedback waits in the '
            'outbox and goes out on the next sync');
      });
      navigator.pop(posting);
    } catch (e) {
      messenger.showNotice(friendlyError(e, doing: 'posting feedback'));
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
    final screenshot = widget.screenshot;
    return Scaffold(
      appBar: AppBar(title: const Text('New feedback')),
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
                    'Feedback is public so we can improve this app together '
                    'as a community. Don\'t include personal information or '
                    'anything that shouldn\'t be public (also in the '
                    'screenshot).',
                    style: TextStyle(fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Which identity signs this: the active profile. The avatar and
          // "switch profile" open the switcher on top of the form.
          Builder(
            builder: (anchor) => Row(
              children: [
                GestureDetector(
                  onTap: () => _switchProfile(anchor),
                  child: ClipOval(
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
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text('Posting as $name',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => _switchProfile(anchor),
                  child: const Text('switch profile',
                      style: TextStyle(
                          fontSize: 14,
                          decoration: TextDecoration.underline)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // One tap tags it; tap again to untag.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in FeedbackKind.values)
                FilterPill(
                  label: kind.label,
                  selected: _kinds.contains(kind),
                  onTap: () => setState(() => _kinds.contains(kind)
                      ? _kinds.remove(kind)
                      : _kinds.add(kind)),
                ),
            ],
          ),
          const SizedBox(height: 16),
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
            decoration: InputDecoration(
              labelText: 'Link (optional)',
              hintText: 'The article or page this is about',
              border: const OutlineInputBorder(),
              suffixIcon: _url.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Remove the link',
                      icon: const Icon(Icons.close),
                      onPressed: _url.clear,
                    ),
            ),
          ),
          if (screenshot != null) ...[
            const SizedBox(height: 14),
            if (_includeScreenshot)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => showImageViewer(
                        context, Image.memory(screenshot)),
                    child: Container(
                      decoration:
                          BoxDecoration(border: Border.all(width: 1)),
                      child: Image.memory(screenshot,
                          height: 160, fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Remove screenshot'),
                    onPressed: () =>
                        setState(() => _includeScreenshot = false),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Include a screenshot of the page'),
                  onPressed: () => setState(() => _includeScreenshot = true),
                ),
              ),
          ],
          const SizedBox(height: 14),
          if (_images.isNotEmpty) ...[
            ImageStrip(
              height: 140,
              count: _images.length,
              itemBuilder: (i) => Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: () => showImageGallery(
                        context, [for (final b in _images) Image.memory(b)],
                        initial: i),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(width: 1)),
                      child: Image.memory(_images[i], fit: BoxFit.cover),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(width: 1)),
                      child: IconButton(
                        tooltip: 'Remove image',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _images.removeAt(i)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(_images.isEmpty ? 'Add images' : 'Add more images'),
              onPressed: _addImages,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: _posting ? null : _post,
            style: OutlinedButton.styleFrom(
                side: const BorderSide(width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: Text(_posting ? 'Posting…' : 'Post feedback',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// A note's text as one plain paragraph for the list preview: markdown
/// marks dropped, links reduced to their text, lines joined.
String plainPreview(String markdown) => markdown
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(
        RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\*{1,3}|`+|~~'), '')
    .replaceAll(RegExp(r'\s*\n+\s*'), ' ')
    .trim();


/// The app-bar refresh button, doubling as the loading indicator: it spins
/// while a refresh runs (same as the home screen's sync icon) instead of a
/// large spinner in the middle of the page.
class RefreshAction extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;

  const RefreshAction(
      {super.key, required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: loading ? 'Refreshing…' : 'Refresh',
      icon: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.sync),
      onPressed: loading ? null : onPressed,
    );
  }
}


/// Shows an image (a feedback screenshot) almost full screen, zoomable;
/// tap anywhere or the close button to dismiss.
Future<void> showImageViewer(BuildContext context, Image image) =>
    showImageGallery(context, [image]);

/// Shows [images] almost full screen, starting at [initial]: swipe, the
/// arrow buttons or the keyboard's left/right arrows go to the previous or
/// next one (wrapping around). Zoomable; tap or the close button dismisses.
Future<void> showImageGallery(BuildContext context, List<Image> images,
    {int initial = 0}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      child: _ImageGallery(images: images, initial: initial),
    ),
  );
}

class _ImageGallery extends StatefulWidget {
  final List<Image> images;
  final int initial;

  const _ImageGallery({required this.images, required this.initial});

  @override
  State<_ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<_ImageGallery> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// One step left or right, wrapping around; no sliding animation (it
  /// smears on e-ink).
  void _go(int delta) {
    final count = widget.images.length;
    _pages.jumpToPage((_index + delta + count) % count);
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.images.length > 1;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.images.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => InteractiveViewer(
                  maxScale: 5,
                  child: Center(child: widget.images[i]),
                ),
              ),
            ),
            if (many) ...[
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _GalleryButton(
                      tooltip: 'Previous image',
                      icon: Icons.chevron_left,
                      onPressed: () => _go(-1)),
                ),
              ),
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _GalleryButton(
                      tooltip: 'Next image',
                      icon: Icons.chevron_right,
                      onPressed: () => _go(1)),
                ),
              ),
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    color: Colors.white,
                    child: Text('${_index + 1} / ${widget.images.length}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Close image',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round, outlined arrow over the picture, readable on any image.
class _GalleryButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _GalleryButton(
      {required this.tooltip, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(width: 1.5),
      ),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 30),
        onPressed: onPressed,
      ),
    );
  }
}
