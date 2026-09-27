# Feedback bot

Turns approved public feedback into releases. Every minute it asks Nostr
(with the `nostr` CLI from nostrcli.sh) for notes addressed to einkreader's
official account, `npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7`.

Feedback is **approved** when Xavier wrote it (xavier@einkreader.app or his
personal npub) or reacted to it with 👍. For each approved feedback, once:

1. react 👀 as the official account,
2. run Claude Code (Opus, headless) in this repo to implement it, test it and
   ship a release,
3. reply to the feedback as the official account with what changed.

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
