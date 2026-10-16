import assert from 'node:assert/strict'
import { test } from 'node:test'
import { rms } from '../src/mic.ts'

// 100 ms of a 440 Hz sine at 16 kHz.
function chunk(amplitude: number): ArrayBuffer {
  const samples = new Int16Array(1600)
  for (let i = 0; i < samples.length; i++) samples[i] = Math.round(amplitude * 32767 * Math.sin((2 * Math.PI * 440 * i) / 16_000))
  return samples.buffer
}

test('silence is zero', () => {
  assert.equal(rms(new ArrayBuffer(3200)), 0)
  assert.equal(rms(new ArrayBuffer(0)), 0)
})

test('sine RMS is amplitude over root two', () => {
  assert.ok(Math.abs(rms(chunk(0.5)) - 0.5 / Math.SQRT2) < 0.001)
})

test('a soft voice counts as sound, a quiet room does not', () => {
  assert.ok(rms(chunk(0.014)) > 0.006) // about -40 dBFS
  assert.ok(rms(chunk(0.0025)) < 0.006) // about -55 dBFS
})
