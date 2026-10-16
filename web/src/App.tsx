import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react'
import { authEnabled, signOut } from './auth'
import { Captioner, type CaptionerStatus } from './captioner'
import {
  answerSourceTip,
  AUTO,
  FONT_SCALE_MAX,
  FONT_SCALE_MIN,
  LANGUAGES,
  languageName,
  loadSettings,
  parseTerms,
  saveSettings,
  sourceTipAnswered,
  type Settings,
} from './settings'
import { exportText, formatElapsed, Transcript, type Row } from './transcript'
import { keepScreenOn } from './wakeLock'

const STATUS_LABEL: Record<CaptionerStatus, string> = {
  idle: '未开始',
  starting: '连接中…',
  live: '实时',
  waiting: '等待说话',
  reconnecting: '重连中…',
  stopping: '收尾中…',
  'needs-tap': '已暂停',
  error: '出错了',
}

const ACTIVE: CaptionerStatus[] = ['starting', 'live', 'waiting', 'reconnecting', 'needs-tap']

export default function App() {
  const [settings, setSettings] = useState<Settings>(loadSettings)
  const [status, setStatus] = useState<CaptionerStatus>('idle')
  const [message, setMessage] = useState<string>()
  const [startedAt, setStartedAt] = useState<number | null>(null)
  const [endedAt, setEndedAt] = useState<number | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  /** Detected language offered as the listening language after an auto-detect session. */
  const [suggestedSource, setSuggestedSource] = useState<string>()
  const now = useNow(startedAt !== null && endedAt === null)

  const transcriptRef = useRef<Transcript>(null)
  transcriptRef.current ??= new Transcript()
  const transcript = transcriptRef.current
  const snapshot = useSyncExternalStore(transcript.subscribe, transcript.getSnapshot)

  const captionerRef = useRef<Captioner>(null)
  useEffect(() => {
    const captioner = new Captioner({
      onTokens: (tokens) => transcript.apply(tokens),
      onSessionRestart: () => transcript.clearLive(),
      onStatus: (next, msg) => {
        setStatus(next)
        setMessage(msg)
      },
    })
    captionerRef.current = captioner
    return () => captioner.dispose()
  }, [transcript])

  useEffect(() => saveSettings(settings), [settings])

  const active = ACTIVE.includes(status)
  useEffect(() => {
    keepScreenOn(active)
  }, [active])

  const start = () => {
    if (!transcript.isEmpty && !window.confirm('开始新会话会清空当前字幕。确定吗？（可以先导出）')) return
    transcript.reset()
    setStartedAt(Date.now())
    setEndedAt(null)
    setShowSettings(false)
    setSuggestedSource(undefined)
    const terms = parseTerms(settings.terms)
    const background = settings.background.trim()
    captionerRef.current?.start({
      sourceLang: settings.sourceLang,
      targetLang: settings.targetLang,
      context:
        terms.length || background
          ? { ...(terms.length ? { terms } : {}), ...(background ? { text: background } : {}) }
          : undefined,
    })
  }

  const stop = async () => {
    await captionerRef.current?.stop()
    transcript.commitLive()
    setEndedAt(Date.now())
    const detected = transcript.dominantSpokenLanguage()
    if (settings.sourceLang === AUTO && !sourceTipAnswered() && detected && detected !== settings.targetLang) {
      setSuggestedSource(detected)
    }
  }

  const answerTip = (use: boolean) => {
    if (use && suggestedSource) setSettings((s) => ({ ...s, sourceLang: suggestedSource }))
    answerSourceTip()
    setSuggestedSource(undefined)
  }

  const download = () => {
    if (startedAt === null) return
    const text = exportText(snapshot.rows, {
      startedAt,
      sourceLang: settings.sourceLang,
      targetLang: settings.targetLang,
    })
    const d = new Date(startedAt)
    const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `catchline-${stamp}.txt`
    a.click()
    setTimeout(() => URL.revokeObjectURL(url), 10_000)
  }

  const setFontScale = (delta: number) =>
    setSettings((s) => ({
      ...s,
      fontScale: Math.round(Math.min(FONT_SCALE_MAX, Math.max(FONT_SCALE_MIN, s.fontScale + delta)) * 10) / 10,
    }))

  const elapsed = startedAt === null ? 0 : (endedAt ?? now) - startedAt
  const hasCaptions = snapshot.rows.length > 0 || snapshot.liveSource !== ''
  const settingsOpen = !active && status !== 'stopping' && (showSettings || (!hasCaptions && startedAt === null))

  return (
    <div className="app">
      <header className="bar">
        <div className="brand">CatchLine</div>
        <div className={`status status-${status}`} title={message}>
          <span className="dot" />
          {STATUS_LABEL[status]}
          {startedAt !== null && <span className="timer">{formatElapsed(elapsed)}</span>}
        </div>
        <div className="bar-actions">
          <button className="icon" onClick={() => setFontScale(-0.1)} aria-label="缩小字号">
            A−
          </button>
          <button className="icon" onClick={() => setFontScale(0.1)} aria-label="放大字号">
            A+
          </button>
          <button
            className="icon"
            onClick={() => setShowSettings((v) => !v)}
            disabled={active}
            aria-label="设置"
            aria-pressed={settingsOpen}
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
              <path d="M4 7h10M18 7h2M4 17h4M12 17h8" />
              <circle cx="16" cy="7" r="2" />
              <circle cx="10" cy="17" r="2" />
            </svg>
          </button>
        </div>
      </header>

      {settingsOpen ? (
        <SettingsPanel settings={settings} onChange={setSettings} />
      ) : (
        <Captions
          rows={snapshot.rows}
          liveSource={snapshot.liveSource}
          liveTarget={snapshot.liveTarget}
          fontScale={settings.fontScale}
          waiting={status === 'live' && !hasCaptions}
        />
      )}

      {message && <div className={`banner banner-${status}`}>{message}</div>}
      {suggestedSource && (
        <div className="banner tip">
          <p>刚才听到的大部分是{languageName(suggestedSource)}。设为要听的语言，字幕会更准确？</p>
          <div className="tip-actions">
            <button className="primary small" onClick={() => answerTip(true)}>
              使用{languageName(suggestedSource)}
            </button>
            <button className="secondary small" onClick={() => answerTip(false)}>
              暂不
            </button>
          </div>
        </div>
      )}

      <footer className="controls">
        {status === 'needs-tap' ? (
          <>
            <button className="primary" onClick={() => captionerRef.current?.resume()}>
              继续
            </button>
            <button className="secondary" onClick={stop}>
              停止
            </button>
          </>
        ) : active || status === 'stopping' ? (
          <button className="primary stop" onClick={stop} disabled={status === 'stopping'}>
            停止
          </button>
        ) : (
          <>
            <button className="primary" onClick={start}>
              {hasCaptions ? '新会话' : '开始'}
            </button>
            {hasCaptions && (
              <button className="secondary" onClick={download}>
                导出 .txt
              </button>
            )}
          </>
        )}
      </footer>
    </div>
  )
}

function SettingsPanel({ settings, onChange }: { settings: Settings; onChange: (s: Settings) => void }) {
  const set = <K extends keyof Settings>(key: K, value: Settings[K]) => onChange({ ...settings, [key]: value })
  return (
    <main className="settings">
      <div className="lang-row">
        <label>
          <span>要听的语言</span>
          <select value={settings.sourceLang} onChange={(e) => set('sourceLang', e.target.value)}>
            <option value={AUTO}>自动识别</option>
            {LANGUAGES.map((l) => (
              <option key={l.code} value={l.code}>
                {l.label}
              </option>
            ))}
          </select>
        </label>
        <button
          className="icon swap"
          onClick={() => onChange({ ...settings, sourceLang: settings.targetLang, targetLang: settings.sourceLang })}
          disabled={settings.sourceLang === AUTO || settings.sourceLang === settings.targetLang}
          aria-label="互换语言"
        >
          ⇄
        </button>
        <label>
          <span>翻译成</span>
          <select value={settings.targetLang} onChange={(e) => set('targetLang', e.target.value)}>
            {LANGUAGES.map((l) => (
              <option key={l.code} value={l.code}>
                {l.label}
              </option>
            ))}
          </select>
        </label>
      </div>
      <p className="hint">
        {settings.sourceLang === settings.targetLang
          ? '相同语言：只显示字幕，不翻译。'
          : '要听的语言可选。选了字幕更准确；自动识别支持任何语言，混着说也行。'}
      </p>
      <label className="field">
        <span>关键词：人名、公司、术语（逗号或换行分隔）</span>
        <textarea
          rows={3}
          value={settings.terms}
          placeholder="Mark Johnson, Acme Corp, ACH transfer, W-2"
          onChange={(e) => set('terms', e.target.value)}
        />
      </label>
      <label className="field">
        <span>背景说明（可选）</span>
        <textarea
          rows={3}
          value={settings.background}
          placeholder="和房东通电话，讨论续租和维修。"
          onChange={(e) => set('background', e.target.value)}
        />
      </label>
      <p className="hint">关键词和背景会传给识别引擎，能明显提高专有名词的准确率。开始后不可修改。</p>
      {authEnabled() && (
        <button className="link" onClick={() => void signOut()}>
          退出登录
        </button>
      )}
    </main>
  )
}

const STICK_THRESHOLD_PX = 48

function Captions(props: {
  rows: readonly Row[]
  liveSource: string
  liveTarget: string
  fontScale: number
  waiting: boolean
}) {
  const { rows, liveSource, liveTarget, fontScale, waiting } = props
  const scrollRef = useRef<HTMLElement>(null)
  const [stick, setStick] = useState(true)

  const onScroll = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    setStick(el.scrollHeight - el.scrollTop - el.clientHeight < STICK_THRESHOLD_PX)
  }, [])

  const scrollToEnd = useCallback(() => {
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [])

  useLayoutEffect(() => {
    if (stick) scrollToEnd()
  }, [rows, liveSource, liveTarget, fontScale, stick, scrollToEnd])

  const last = rows.at(-1)
  // Live text continues the last row unless that row is already finished.
  const liveInLast = last !== undefined && !last.closed && !last.hasTranslation
  const liveRowNeeded = !liveInLast && (liveSource || liveTarget)

  return (
    <main className="captions" ref={scrollRef} onScroll={onScroll} style={{ '--scale': fontScale } as React.CSSProperties}>
      {rows.length === 0 && !liveSource && (
        <p className="empty">{waiting ? '正在听…开始说话吧' : '字幕会显示在这里'}</p>
      )}
      {rows.map((row) => (
        <RowView
          key={row.id}
          row={row}
          liveSource={row === last && liveInLast ? liveSource : ''}
          liveTarget={row === last && liveInLast ? liveTarget : ''}
        />
      ))}
      {liveRowNeeded && (
        <div className="row">
          <p className="src">
            <span className="live">{liveSource.trimStart()}</span>
          </p>
          {liveTarget && (
            <p className="tgt">
              <span className="live">{liveTarget.trimStart()}</span>
            </p>
          )}
        </div>
      )}
      {!stick && (
        <button
          className="jump"
          onClick={() => {
            setStick(true)
            scrollToEnd()
          }}
        >
          回到最新 ↓
        </button>
      )}
    </main>
  )
}

const RowView = memo(function RowView({ row, liveSource, liveTarget }: { row: Row; liveSource: string; liveTarget: string }) {
  return (
    <div className="row">
      <p className="src">
        {row.source}
        {liveSource && <span className="live">{row.source ? liveSource : liveSource.trimStart()}</span>}
      </p>
      {(row.target || liveTarget) && (
        <p className="tgt">
          {row.target}
          {liveTarget && <span className="live">{liveTarget}</span>}
        </p>
      )}
    </div>
  )
})

function useNow(running: boolean): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!running) return
    setNow(Date.now())
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [running])
  return now
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}
