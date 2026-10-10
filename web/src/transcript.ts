import type { RealtimeToken } from '@soniox/client'

// One caption block: a chunk of recognized speech plus its translation.
// Soniox finalizes source text in sentence-ish chunks and streams the
// translation of each chunk right after it, so a row is "source chunk(s) →
// translation". A new row starts when source text arrives after the current
// row already received translation, or after an endpoint (<end>).
export interface Row {
  id: number
  /** Wall-clock time (epoch ms) when the row's first word was finalized. */
  at: number
  source: string
  target: string
  closed: boolean
}

export interface TranscriptSnapshot {
  rows: readonly Row[]
  /** Non-final source text still being recognized (shown dimmed). */
  liveSource: string
  /** Non-final translation text, if the server sends any. */
  liveTarget: string
}

const CONTROL_TOKENS = new Set(['<end>', '<fin>'])

export class Transcript {
  private rows: Row[] = []
  private liveSource = ''
  private liveTarget = ''
  private nextId = 1
  private snapshot: TranscriptSnapshot = { rows: [], liveSource: '', liveTarget: '' }
  private listeners = new Set<() => void>()

  /** Apply one `result` message. Non-final tokens replace the previous ones. */
  apply(tokens: readonly RealtimeToken[], now = Date.now()): void {
    let liveSource = ''
    let liveTarget = ''
    for (const token of tokens) {
      if (CONTROL_TOKENS.has(token.text)) {
        if (token.text === '<end>') this.closeLastRow()
        continue
      }
      const isTranslation = token.translation_status === 'translation'
      if (!token.is_final) {
        if (isTranslation) liveTarget += token.text
        else liveSource += token.text
        continue
      }
      if (isTranslation) this.appendTarget(token.text, now)
      else this.appendSource(token.text, now)
    }
    this.liveSource = liveSource
    this.liveTarget = liveTarget
    this.publish()
  }

  /** Drop in-flight non-final text, e.g. when a new Soniox session starts. */
  clearLive(): void {
    if (!this.liveSource && !this.liveTarget) return
    // Whatever was mid-recognition is lost with the old session; make sure
    // the next session's text starts a fresh row instead of gluing onto it.
    this.liveSource = ''
    this.liveTarget = ''
    this.closeLastRow()
    this.publish()
  }

  /** Keep whatever non-final text is left when the session ends for good. */
  commitLive(now = Date.now()): void {
    if (!this.liveSource && !this.liveTarget) return
    if (this.liveSource) this.appendSource(this.liveSource, now)
    if (this.liveTarget) this.appendTarget(this.liveTarget, now)
    this.liveSource = ''
    this.liveTarget = ''
    this.closeLastRow()
    this.publish()
  }

  reset(): void {
    this.rows = []
    this.liveSource = ''
    this.liveTarget = ''
    this.publish()
  }

  get isEmpty(): boolean {
    return this.rows.length === 0
  }

  // useSyncExternalStore plumbing.
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = (): TranscriptSnapshot => this.snapshot

  private appendSource(text: string, now: number): void {
    let row = this.rows.at(-1)
    if (!row || row.closed || row.target) {
      row = { id: this.nextId++, at: now, source: '', target: '', closed: false }
      this.rows.push(row)
    }
    this.replaceLast({ ...row, source: row.source ? row.source + text : text.trimStart() })
  }

  private appendTarget(text: string, now: number): void {
    const row = this.rows.at(-1)
    if (!row) {
      this.rows.push({ id: this.nextId++, at: now, source: '', target: text.trimStart(), closed: false })
      return
    }
    this.replaceLast({ ...row, target: row.target ? row.target + text : text.trimStart() })
  }

  private closeLastRow(): void {
    const row = this.rows.at(-1)
    if (row && !row.closed) this.replaceLast({ ...row, closed: true })
  }

  // Rows are immutable so memoized row components only re-render on change.
  private replaceLast(row: Row): void {
    this.rows[this.rows.length - 1] = row
  }

  private publish(): void {
    this.snapshot = { rows: [...this.rows], liveSource: this.liveSource, liveTarget: this.liveTarget }
    for (const listener of this.listeners) listener()
  }
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

export function formatElapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  return `${pad(Math.floor(total / 3600))}:${pad(Math.floor((total % 3600) / 60))}:${pad(total % 60)}`
}

export function exportText(
  rows: readonly Row[],
  meta: { startedAt: number; sourceLang: string; targetLang: string },
): string {
  const start = new Date(meta.startedAt)
  const header =
    `Catchline transcript — ${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())} ` +
    `${pad(start.getHours())}:${pad(start.getMinutes())} (${meta.sourceLang} → ${meta.targetLang})`
  const body = rows
    .filter((row) => row.source || row.target)
    .map((row) => {
      const stamp = `[${formatElapsed(row.at - meta.startedAt)}]`
      const indent = ' '.repeat(stamp.length + 1)
      return row.target ? `${stamp} ${row.source}\n${indent}${row.target}` : `${stamp} ${row.source}`
    })
  return [header, '', ...body, ''].join('\n')
}
