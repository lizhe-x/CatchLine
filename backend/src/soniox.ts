// Mints short-lived Soniox keys for browsers. Shared by the Lambda handler and
// the local Vite dev mock so both paths behave identically.
// API: https://soniox.com/docs/api-reference/auth/create_temporary_api_key

const SONIOX_TEMP_KEY_URL = 'https://api.soniox.com/v1/auth/temporary-api-key';

// The key only needs to live long enough for the browser to open the stream.
const EXPIRES_IN_SECONDS = 120;
// Each stream is capped; the client transparently reconnects with a fresh key.
const MAX_SESSION_DURATION_SECONDS = 2 * 60 * 60;

export interface TemporaryKey {
  apiKey: string;
  expiresAt: string;
}

export class SonioxError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export async function mintTemporaryKey(
  longLivedKey: string,
  clientReferenceId: string,
): Promise<TemporaryKey> {
  const res = await fetch(SONIOX_TEMP_KEY_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${longLivedKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      usage_type: 'transcribe_websocket',
      expires_in_seconds: EXPIRES_IN_SECONDS,
      single_use: true,
      max_session_duration_seconds: MAX_SESSION_DURATION_SECONDS,
      client_reference_id: clientReferenceId.slice(0, 256),
    }),
    signal: AbortSignal.timeout(8000),
  });

  if (!res.ok) {
    // Body may echo request details; keep only a short prefix and never the key.
    const detail = (await res.text()).slice(0, 300);
    throw new SonioxError(res.status, `Soniox temporary key request failed: ${res.status} ${detail}`);
  }

  const body = (await res.json()) as { api_key: string; expires_at: string };
  return { apiKey: body.api_key, expiresAt: body.expires_at };
}
