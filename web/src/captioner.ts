import {
  AudioPermissionError,
  AuthError,
  BadRequestError,
  SonioxClient,
  type RealtimeToken,
  type Recording,
  type TranscriptionContext,
} from '@soniox/client'
import { getAccessToken } from './auth'
import { AUTO, autoHints } from './settings'

// Current real-time model per GET https://api.soniox.com/v1/models (2026-10).
// Bump here when Soniox ships a newer one.
const MODEL = 'stt-rt-v5'

export type CaptionerStatus =
  | 'idle'
  | 'starting' // fetching key / opening mic / connecting
  | 'live'
  | 'reconnecting'
  | 'stopping'
  | 'needs-tap' // browser refused to reopen the mic without a user gesture
  | 'error'

export interface SessionConfig {
  /** A Soniox code, or AUTO. */
  sourceLang: string
  targetLang: string
  context?: TranscriptionContext
}

export interface CaptionerEvents {
  onTokens(tokens: readonly RealtimeToken[]): void
  /** A fresh Soniox stream started; any non-final text is gone. */
  onSessionRestart(): void
  onStatus(status: CaptionerStatus, message?: string): void
}

/** Thrown from the key fetcher so we can tell "log in again" from flaky network. */
export class KeyFetchError extends Error {
  readonly status: number
  constructor(status: number) {
    super(`Temporary key request failed (${status})`)
    this.status = status
  }
}

async function fetchTemporaryKey(): Promise<string> {
  const token = await getAccessToken()
  const res = await fetch('/api/temporary-api-key', {
    method: 'POST',
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  })
  if (!res.ok) throw new KeyFetchError(res.status)
  const body = (await res.json()) as { apiKey: string }
  return body.apiKey
}

const MAX_BACKOFF_MS = 15_000

/**
 * Keeps one live captioning stream running until stop() is called.
 *
 * The SDK already reconnects on transient network errors. This layer covers
 * what it treats as fatal but we don't: the per-stream duration cap (413),
 * an expired temporary key, exhausting the SDK's retry budget during a long
 * outage, and iOS suspending the mic while the page is in the background.
 * Transcript state lives outside, so restarts never lose captions.
 */
export class Captioner {
  private readonly client = new SonioxClient({ api_key: fetchTemporaryKey })
  private recording: Recording | null = null
  private config: SessionConfig | null = null
  private wantRunning = false
  private restartTimer: number | undefined
  private failures = 0
  private hiddenAt: number | null = null
  private readonly events: CaptionerEvents

  constructor(events: CaptionerEvents) {
    this.events = events
    document.addEventListener('visibilitychange', this.onVisibilityChange)
    window.addEventListener('online', this.onOnline)
  }

  /** Must be called from a user gesture (iOS mic permission). */
  start(config: SessionConfig): void {
    this.config = config
    this.wantRunning = true
    this.failures = 0
    this.open()
  }

  async stop(): Promise<void> {
    this.wantRunning = false
    window.clearTimeout(this.restartTimer)
    const recording = this.recording
    if (!recording) {
      this.events.onStatus('idle')
      return
    }
    this.events.onStatus('stopping')
    // stop() waits for the server to flush final tokens (still delivered via
    // `result` while this.recording points at it); don't hang forever.
    await Promise.race([recording.stop().catch(() => {}), new Promise((r) => setTimeout(r, 5000))])
    recording.cancel()
    if (this.recording === recording) this.recording = null
    this.events.onStatus('idle')
  }

  /** Retry after `needs-tap`; call from a user gesture. */
  resume(): void {
    if (!this.config) return
    this.wantRunning = true
    this.open()
  }

  dispose(): void {
    document.removeEventListener('visibilitychange', this.onVisibilityChange)
    window.removeEventListener('online', this.onOnline)
    this.wantRunning = false
    window.clearTimeout(this.restartTimer)
    this.recording?.cancel()
  }

  private open(): void {
    const config = this.config
    if (!config) return
    window.clearTimeout(this.restartTimer)
    this.recording?.cancel()

    this.events.onStatus(this.failures > 0 ? 'reconnecting' : 'starting')
    const recording = this.client.realtime.record({
      model: MODEL,
      language_hints: config.sourceLang === AUTO ? autoHints(config.targetLang) : [config.sourceLang],
      enable_endpoint_detection: true,
      // Tags tokens with their language (for the "set as listening language" tip).
      enable_language_identification: true,
      // Same language on both sides: captions only.
      translation:
        config.sourceLang === config.targetLang ? undefined : { type: 'one_way', target_language: config.targetLang },
      context: config.context,
      auto_reconnect: true,
      max_reconnect_attempts: 4,
    })
    this.recording = recording

    // Ignore events from recordings we've already replaced.
    const current = () => this.recording === recording

    recording.on('result', (result) => {
      if (current()) this.events.onTokens(result.tokens)
    })
    recording.on('session_restart', () => {
      if (current()) this.events.onSessionRestart()
    })
    recording.on('state_change', ({ new_state }) => {
      if (!current() || !this.wantRunning) return
      if (new_state === 'recording') {
        this.failures = 0
        this.events.onStatus('live')
      } else if (new_state === 'reconnecting') {
        this.events.onStatus('reconnecting')
      }
    })
    recording.on('finished', () => {
      // Server ended the stream without us asking (e.g. duration cap).
      if (current() && this.wantRunning) this.scheduleRestart()
    })
    recording.on('error', (error) => {
      if (current()) this.handleError(error)
    })
  }

  private handleError(error: Error): void {
    if (!this.wantRunning) return
    console.warn('[captioner]', error)

    if (error instanceof AudioPermissionError) {
      // First start: user said no. Later: iOS wants a fresh tap to reopen the mic.
      this.recording = null
      this.events.onStatus('needs-tap', '需要麦克风权限，点击继续')
      return
    }
    if (error instanceof KeyFetchError && (error.status === 401 || error.status === 403)) {
      this.fail('登录已过期，请重新登录')
      return
    }
    if (error instanceof AuthError || error instanceof BadRequestError) {
      // Not fixable by retrying (bad config or key rejected at connect).
      this.fail(error.message)
      return
    }
    // Everything else (network, 408/5xx, 413 duration cap, expired temp key,
    // SDK retries exhausted): keep trying with backoff.
    this.scheduleRestart()
  }

  private fail(message: string): void {
    this.wantRunning = false
    this.recording?.cancel()
    this.recording = null
    this.events.onStatus('error', message)
  }

  private scheduleRestart(delayMs?: number): void {
    window.clearTimeout(this.restartTimer)
    this.failures++
    const delay = delayMs ?? Math.min(MAX_BACKOFF_MS, 500 * 2 ** (this.failures - 1))
    this.events.onStatus('reconnecting')
    this.restartTimer = window.setTimeout(() => {
      if (this.wantRunning) this.open()
    }, delay)
  }

  private onVisibilityChange = (): void => {
    if (document.visibilityState === 'hidden') {
      this.hiddenAt = Date.now()
      return
    }
    const hiddenFor = this.hiddenAt === null ? 0 : Date.now() - this.hiddenAt
    this.hiddenAt = null
    // iOS Safari stops the mic (and often the socket) in the background.
    // A quick blip is fine; after a real absence, rebuild the whole pipeline.
    if (this.wantRunning && hiddenFor > 1500) {
      this.failures = Math.max(this.failures, 1)
      this.open()
    }
  }

  private onOnline = (): void => {
    if (this.wantRunning && this.recording?.state !== 'recording') this.scheduleRestart(0)
  }
}
