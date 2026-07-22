// Minimal relay query over native WebSocket (Node 22+).
export const DEFAULT_RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
];

function queryOne(url, filter, timeoutMs) {
  return new Promise((resolve) => {
    const events = [];
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        ws.close();
      } catch {}
      resolve(events);
    };
    const timer = setTimeout(finish, timeoutMs);
    let ws;
    try {
      ws = new WebSocket(url);
    } catch {
      clearTimeout(timer);
      return resolve(events);
    }
    ws.onopen = () => ws.send(JSON.stringify(['REQ', 'q', filter]));
    ws.onmessage = (message) => {
      try {
        const decoded = JSON.parse(message.data);
        if (decoded[0] === 'EVENT') events.push(decoded[2]);
        else if (decoded[0] === 'EOSE' || decoded[0] === 'CLOSED') finish();
      } catch {}
    };
    ws.onerror = finish;
    ws.onclose = finish;
  });
}

/// One REQ to every relay; events deduplicated by id.
export async function queryRelays(filter, { timeoutMs = 5000 } = {}) {
  const results = await Promise.all(DEFAULT_RELAYS.map((relay) =>
      queryOne(relay, filter, timeoutMs)));
  const byId = new Map();
  for (const events of results) {
    for (const event of events) {
      if (event?.id && !byId.has(event.id)) byId.set(event.id, event);
    }
  }
  return [...byId.values()];
}
