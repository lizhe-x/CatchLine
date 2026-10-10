// Keeps the screen on while captioning. Browsers drop the lock whenever the
// page is hidden, so we re-acquire it on return.
let sentinel: WakeLockSentinel | null = null
let wanted = false

async function acquire(): Promise<void> {
  if (!wanted || sentinel || !('wakeLock' in navigator) || document.visibilityState !== 'visible') return
  try {
    sentinel = await navigator.wakeLock.request('screen')
    sentinel.addEventListener('release', () => {
      sentinel = null
    })
  } catch (err) {
    console.warn('[wakeLock]', err)
  }
}

document.addEventListener('visibilitychange', () => void acquire())

export function keepScreenOn(on: boolean): void {
  wanted = on
  if (on) void acquire()
  else void sentinel?.release()
}
