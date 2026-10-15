# Feedback bot

Turns approved public feedback into releases. Every minute it asks Nostr
(with the `nostr` CLI from nostrcli.sh) for notes addressed to einkreader's
official account, `npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7`.

Feedback is **approved** when Xavier wrote it (xavier@einkreader.app or his
personal npub) or reacted to it with 👍. Nothing is released until Xavier
approves a **proposal**:

1. react 👀 to the feedback,
2. run Claude Code (Opus, headless) in a git worktree of its own
   (`~/.local/state/einkreader-feedback/worktrees/<id>`, branch
   `feedback/<id>`) to implement it, test it and take screenshots; nothing
   is pushed,
3. reply in the thread with the proposal and the screenshots,
4. Xavier 👍s the proposal, or replies in the thread with more details or
   other ideas: Claude reworks the branch and the bot posts an updated
   proposal, as many rounds as needed (only a 👍 on the latest proposal
   counts),
5. on the 👍, Claude rebases the branch and ships a patch release; the
   bot replies with what changed and a link to that version's GitHub
   release page (its notes, from the changelog files, and the APK).

Feedback that needs no change gets an answer right away and no proposal.

Xavier can also @mention the bot (`nostr:npub…` in the text) in any
thread, including someone else's: it reads the conversation and proposes a
change, or just answers. Mentions and replies from anyone else are ignored.

Everyone else's feedback waits for a 👍: the note text is untrusted input to
an agent that can commit and release.

## Setup

```sh
# the nostr CLI
gh release download -R xdamman/nostr-cli -p nostr_linux_amd64.tar.gz
tar xzf nostr_linux_amd64.tar.gz && install -m 755 nostr ~/.local/bin/

# the official account's key, so the bot can react and reply as it
nostr login --nsec <official nsec>
nostr relays add wss://relay.damus.io --account npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7
nostr relays add wss://nos.lol --account npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7

# the service (restarts on failure, starts at boot with lingering enabled)
ln -sf "$PWD/infra/feedback-bot/einkreader-feedback.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now einkreader-feedback
```

Until the official key is imported, reactions and replies are queued in the
state file and sent as soon as it is.

## Operating

- Logs: `journalctl --user -u einkreader-feedback -f`
- Each Claude run's full output: `~/.local/state/einkreader-feedback/runs/`
- State (handled notes, queued posts): `~/.local/state/einkreader-feedback/state.json`
- What it would do, without acting: `python3 infra/feedback-bot/bot.py --dry-run`
- To redo a feedback, delete its id from `handled` in the state file.
