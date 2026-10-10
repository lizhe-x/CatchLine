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

export const LANGUAGES: { code: string; label: string }[] = [
  { code: 'en', label: 'English' },
  { code: 'zh', label: '中文' },
  { code: 'ja', label: '日本語' },
  { code: 'ko', label: '한국어' },
  { code: 'es', label: 'Español' },
  { code: 'fr', label: 'Français' },
  { code: 'de', label: 'Deutsch' },
  { code: 'pt', label: 'Português' },
  { code: 'ru', label: 'Русский' },
  { code: 'vi', label: 'Tiếng Việt' },
]

export const FONT_SCALE_MIN = 0.8
export const FONT_SCALE_MAX = 2.2

const KEY = 'catchline.settings.v1'

const DEFAULTS: Settings = {
  sourceLang: 'en',
  targetLang: 'zh',
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

export function parseTerms(terms: string): string[] {
  return [...new Set(terms.split(/[,，\n]/).map((t) => t.trim()).filter(Boolean))]
}
