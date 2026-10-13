// Per-device preferences, persisted in localStorage.

export interface Settings {
  sourceLang: string
  targetLang: string
  fontScale: number
  /** Names, companies, jargon — comma or newline separated. */
  terms: string
  /** Free-form background about the call. */
  background: string
}

/** `sourceLang` value for "detect automatically". */
export const AUTO = 'auto'

/** Every language `stt-rt-v5` supports (GET https://api.soniox.com/v1/models, 2026-10); same list as the iOS app. */
const SONIOX_CODES = [
  'af', 'sq', 'ar', 'az', 'eu', 'be', 'bn', 'bs', 'bg', 'ca', 'zh', 'hr', 'cs', 'da', 'nl', 'en',
  'et', 'fi', 'fr', 'gl', 'de', 'el', 'gu', 'he', 'hi', 'hu', 'id', 'it', 'ja', 'kn', 'kk', 'ko',
  'lv', 'lt', 'mk', 'ms', 'ml', 'mr', 'no', 'fa', 'pl', 'pt', 'pa', 'ro', 'ru', 'sr', 'sk', 'sl',
  'es', 'sw', 'sv', 'tl', 'ta', 'te', 'th', 'tr', 'uk', 'ur', 'vi', 'cy',
]

const names = new Intl.DisplayNames(['zh-Hans'], { type: 'language' })

/** Name in Chinese (the web UI language), e.g. "日语". */
export function languageName(code: string): string {
  return names.of(code) ?? code
}

/** All languages with labels like "日语 · 日本語", sorted by Chinese name. */
export const LANGUAGES: { code: string; label: string }[] = SONIOX_CODES.map((code) => {
  const name = languageName(code)
  const native = new Intl.DisplayNames([code], { type: 'language' }).of(code) ?? code
  return { code, label: name === native ? name : `${name} · ${native}` }
}).sort((a, b) => a.label.localeCompare(b.label, 'zh-Hans'))

/** Soniox code for a browser language tag ("zh-TW" → "zh", "nb" → "no"), if supported. */
export function sonioxCode(tag: string): string | undefined {
  const base = tag.toLowerCase().split('-')[0]
  const code = ({ nb: 'no', nn: 'no', fil: 'tl', iw: 'he', in: 'id' } as Record<string, string>)[base] ?? base
  return SONIOX_CODES.includes(code) ? code : undefined
}

function browserLanguages(): readonly string[] {
  return typeof navigator === 'undefined' ? [] : navigator.languages
}

/** Translate into the browser's language; English if Soniox doesn't have it. */
export function systemTarget(): string {
  return sonioxCode(browserLanguages()[0] ?? '') ?? 'en'
}

/** Hints for automatic detection: the target plus English and the browser's languages. */
export function autoHints(target: string): string[] {
  const codes = [target, 'en', ...browserLanguages().map(sonioxCode)].filter((c): c is string => !!c)
  return [...new Set(codes)].slice(0, 4)
}

export const FONT_SCALE_MIN = 0.8
export const FONT_SCALE_MAX = 2.2

const KEY = 'catchline.settings.v1'

const KEY_TIP = 'catchline.sourceTipAnswered'

const DEFAULTS: Settings = {
  sourceLang: AUTO,
  targetLang: systemTarget(),
  fontScale: 1,
  terms: '',
  background: '',
}

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    return raw ? { ...DEFAULTS, ...(JSON.parse(raw) as Partial<Settings>) } : DEFAULTS
  } catch {
    return DEFAULTS
  }
}

export function saveSettings(settings: Settings): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(settings))
  } catch {
    // Private mode / storage disabled: preferences just won't persist.
  }
}

/** The "mostly Spanish detected — set it?" tip was answered; don't ask again. */
export function sourceTipAnswered(): boolean {
  try {
    return localStorage.getItem(KEY_TIP) === '1'
  } catch {
    return false
  }
}

export function answerSourceTip(): void {
  try {
    localStorage.setItem(KEY_TIP, '1')
  } catch {
    // Storage disabled: the tip may show again next time.
  }
}

export function parseTerms(terms: string): string[] {
  return [...new Set(terms.split(/[,，\n]/).map((t) => t.trim()).filter(Boolean))]
}
