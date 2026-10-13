import type { RealtimeToken } from '@soniox/client'

// One caption block: a chunk of recognized speech plus its translation.
// Soniox finalizes source text in sentence-ish chunks and streams the
// translation of each chunk right after it, so a row is "source chunk(s) →
// translation". A new row starts when source text to translate arrives after
// the current row already received translation, or after an endpoint (<end>).
//
// Speech already in the target language ("Hi hello 小朋友" → zh) comes back
// marked `none` and is never translated, so it's kept as-is in the
// translation line, in spoken order: "你好你好，小朋友".
export interface Segment {
  /** True: speech to translate, `text` is its translation so far. False: already in the target language. */
  translated: boolean
  text: string
  /** No more translation goes here (a later segment has started receiving it). */
  done: boolean
}

export interface Row {
  id: number
  /** Wall-clock time (epoch ms) when the row's first word was finalized. */
  at: number
  source: string
  /** The translation line (empty when it would just repeat the source). */
  target: string
  segments: readonly Segment[]
  /** Whether any translation arrived (the next source text starts a new row). */
  hasTranslation: boolean
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

/**
 * The translation line: segments in spoken order. Stops before a segment whose
 * translation hasn't arrived yet, so the line only ever grows at the end.
 */
function targetText(segments: readonly Segment[], closed: boolean): string {
  if (!segments.some((s) => s.translated)) return ''
  let out = ''
  for (const segment of segments) {
    if (segment.translated && !segment.text && !closed) break
    out += segment.text
  }
  return out.trimStart()
}

export class Transcript {
  private rows: Row[] = []
  private liveSource = ''
  private liveTarget = ''
  private nextId = 1
  /** Characters of finalized, translated speech per detected language. */
  private spoken = new Map<string, number>()
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
      if (isTranslation) {
        this.appendTarget(token.text, now)
      } else {
        const untranslated = token.translation_status === 'none'
        this.appendSource(token.text, untranslated, now)
        if (!untranslated && token.language) {
          this.spoken.set(token.language, (this.spoken.get(token.language) ?? 0) + token.text.length)
        }
      }
    }
    this.sealFilledSegments()
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
    if (this.liveSource) this.appendSource(this.liveSource, false, now)
    if (this.liveTarget) this.appendTarget(this.liveTarget, now)
    this.liveSource = ''
    this.liveTarget = ''
    this.closeLastRow()
    this.publish()
  }

  /** The language most translated speech was in, if it clearly dominated (≥ 80%) a reasonably long session. */
  dominantSpokenLanguage(minCharacters = 60): string | undefined {
    let total = 0
    let top: [string, number] | undefined
    for (const entry of this.spoken) {
      total += entry[1]
      if (!top || entry[1] > top[1]) top = entry
    }
    return top && total >= minCharacters && top[1] >= total * 0.8 ? top[0] : undefined
  }

  reset(): void {
    this.rows = []
    this.spoken.clear()
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

  private appendSource(text: string, untranslated: boolean, now: number): void {
    let row = this.rows.at(-1)
    // Speech that won't be translated can't break source → translation
    // pairing, so it stays with the sentence it followed ("Hi hello 小朋友").
    if (!row || row.closed || (row.hasTranslation && !untranslated)) {
      row = { id: this.nextId++, at: now, source: '', target: '', segments: [], hasTranslation: false, closed: false }
      this.rows.push(row)
    }
    const segments = [...row.segments]
    const last = segments.at(-1)
    if (last && last.translated === !untranslated) {
      // Same kind as the previous run: grow it (passthrough keeps the words).
      if (untranslated) segments[segments.length - 1] = { ...last, text: last.text + text }
    } else {
      segments.push({ translated: !untranslated, text: untranslated ? text : '', done: false })
    }
    this.replaceLast({ ...row, source: row.source ? row.source + text : text.trimStart(), segments })
  }

  private appendTarget(text: string, now: number): void {
    let row = this.rows.at(-1)
    if (!row) {
      row = { id: this.nextId++, at: now, source: '', target: '', segments: [], hasTranslation: false, closed: false }
      this.rows.push(row)
    }
    const segments = [...row.segments]
    // Translation fills the earliest translatable segment still open.
    const i = segments.findIndex((s) => s.translated && !s.done)
    if (i >= 0) segments[i] = { ...segments[i], text: segments[i].text + text }
    else segments.push({ translated: true, text, done: false })
    this.replaceLast({ ...row, segments, hasTranslation: true })
  }

  /**
   * Soniox sends each chunk's translation together, so at the end of a message
   * a segment that got translation is complete — if a later segment is waiting
   * for its own. (Otherwise more of it may follow.)
   */
  private sealFilledSegments(): void {
    const row = this.rows.at(-1)
    if (!row) return
    let changed = false
    const segments = row.segments.map((s, j) => {
      if (s.translated && !s.done && s.text && row.segments.slice(j + 1).some((n) => n.translated)) {
        changed = true
        return { ...s, done: true }
      }
      return s
    })
    if (changed) this.replaceLast({ ...row, segments })
  }

  private closeLastRow(): void {
    const row = this.rows.at(-1)
    if (row && !row.closed) this.replaceLast({ ...row, closed: true })
  }

  // Rows are immutable so memoized row components only re-render on change.
  private replaceLast(row: Row): void {
    this.rows[this.rows.length - 1] = { ...row, target: targetText(row.segments, row.closed) }
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
    `CatchLine transcript — ${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())} ` +
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
