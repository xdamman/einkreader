// Sends one email through Resend. Throws with the status on failure.
export async function sendEmail(message) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) throw new Error('sending not configured');
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(message),
  });
  if (!res.ok) throw new Error(`send failed (${res.status})`);
  return res.json();
}

export const DIGEST_FROM = 'digest@einkreader.app';
