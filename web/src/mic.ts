import { AudioDeviceError, AudioPermissionError, AudioUnavailableError } from '@soniox/client'

// Raw 16 kHz mono little-endian Int16 PCM, the same format the iOS app sends.
// Raw PCM (not MediaRecorder's Opus) so we can measure loudness, keep a
// pre-roll and start a new Soniox stream at any chunk boundary.
export const SAMPLE_RATE = 16_000

// Same as the SDK's MicrophoneSource defaults: Soniox prefers unprocessed audio.
const CONSTRAINTS: MediaTrackConstraints = {
  echoCancellation: false,
  noiseSuppression: false,
  autoGainControl: false,
  channelCount: 1,
}

// Collects ~100 ms of input per message instead of one per 128-frame quantum.
const WORKLET = `
class Tap extends AudioWorkletProcessor {
  constructor() { super(); this.buf = new Float32Array(Math.round(sampleRate / 10)); this.n = 0 }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0]
    if (ch) for (let i = 0; i < ch.length; i++) {
      this.buf[this.n++] = ch[i]
      if (this.n === this.buf.length) { this.port.postMessage(this.buf.slice()); this.n = 0 }
    }
    return true
  }
}
registerProcessor('catchline-tap', Tap)
`

/** Microphone → 16 kHz Int16 PCM chunks (~100 ms each). */
export class Mic {
  private context: AudioContext | null = null
  private stream: MediaStream | null = null
  private onChunk: ((chunk: ArrayBuffer) => void) | null = null
  // Resampler state carried across chunks.
  private position = 0
  private carry: Float32Array = new Float32Array(0)

  /** Call from a user gesture the first time (iOS needs it for the mic and AudioContext). */
  async start(onChunk: (chunk: ArrayBuffer) => void): Promise<void> {
    this.stop()
    if (!navigator.mediaDevices?.getUserMedia || typeof AudioWorkletNode === 'undefined') {
      throw new AudioUnavailableError('This browser can’t capture audio')
    }
    // Created before any await so it counts as started by the gesture.
    const context = new AudioContext()
    this.context = context
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: CONSTRAINTS })
    } catch (err) {
      this.stop()
      const name = err instanceof DOMException ? err.name : ''
      if (name === 'NotAllowedError') throw new AudioPermissionError('Microphone access denied', err)
      if (name === 'NotFoundError' || name === 'NotReadableError') throw new AudioDeviceError('No usable microphone', err)
      throw new AudioUnavailableError(err instanceof Error ? err.message : 'Microphone unavailable', err)
    }
    if (this.context !== context) {
      stream.getTracks().forEach((t) => t.stop()) // stopped meanwhile
      return
    }
    this.stream = stream
    this.onChunk = onChunk
    this.position = 0
    this.carry = new Float32Array(0)

    const url = URL.createObjectURL(new Blob([WORKLET], { type: 'application/javascript' }))
    try {
      await context.audioWorklet.addModule(url)
    } finally {
      URL.revokeObjectURL(url)
    }
    const tap = new AudioWorkletNode(context, 'catchline-tap')
    tap.port.onmessage = (e: MessageEvent<Float32Array>) => this.emit(e.data, context.sampleRate)
    context.createMediaStreamSource(stream).connect(tap)
    if (context.state !== 'running') await context.resume()
    // iOS leaves it suspended outside a gesture (e.g. restarting after the background).
    if (context.state !== 'running') {
      this.stop()
      throw new AudioPermissionError('Audio needs a tap to resume')
    }
  }

  stop(): void {
    this.onChunk = null
    this.stream?.getTracks().forEach((t) => t.stop())
    this.stream = null
    void this.context?.close().catch(() => {})
    this.context = null
  }

  /** Downsample (box filter over each output sample's span) and convert to Int16. */
  private emit(input: Float32Array, inputRate: number): void {
    if (!this.onChunk) return
    const ratio = inputRate / SAMPLE_RATE
    const samples = new Float32Array(this.carry.length + input.length)
    samples.set(this.carry)
    samples.set(input, this.carry.length)
    const count = Math.floor((samples.length - this.position) / ratio)
    const out = new Int16Array(count)
    for (let i = 0; i < count; i++) {
      const start = this.position + i * ratio
      const from = Math.floor(start)
      const to = Math.max(from + 1, Math.floor(start + ratio))
      let sum = 0
      for (let j = from; j < to; j++) sum += samples[j]
      const value = sum / (to - from)
      out[i] = Math.max(-32768, Math.min(32767, Math.round(value * 32767)))
    }
    const consumed = this.position + count * ratio
    const keep = Math.floor(consumed)
    this.carry = samples.slice(keep)
    this.position = consumed - keep
    if (count > 0) this.onChunk(out.buffer)
  }
}

/** Root mean square of 16-bit PCM, full scale 1.0. */
export function rms(chunk: ArrayBuffer): number {
  const samples = new Int16Array(chunk)
  if (samples.length === 0) return 0
  let sum = 0
  for (const sample of samples) {
    const x = sample / 32768
    sum += x * x
  }
  return Math.sqrt(sum / samples.length)
}
