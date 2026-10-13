import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import type { RealtimeToken } from '@soniox/client'
import { Transcript } from '../src/transcript.ts'

const tok = (text: string, status: 'original' | 'translation' | 'none' = 'original'): RealtimeToken =>
  ({ text, is_final: true, translation_status: status, confidence: 1 }) as RealtimeToken

test('speech already in the target language stays in the translation line', () => {
  const t = new Transcript()
  t.apply([tok('Hi'), tok(' hello')])
  t.apply([tok('你好你好，', 'translation')])
  t.apply([tok(' 小朋友', 'none')])
  const { rows } = t.getSnapshot()
  assert.deepEqual(rows.map((r) => r.source), ['Hi hello 小朋友'])
  assert.deepEqual(rows.map((r) => r.target), ['你好你好， 小朋友'])
})

test('untranslated speech waits for the translation before it, in order', () => {
  const t = new Transcript()
  t.apply([tok('OK,'), tok(' 你听', 'none'), tok(' stop here.')])
  assert.equal(t.getSnapshot().rows[0].target, '')
  t.apply([tok('好，', 'translation')])
  assert.equal(t.getSnapshot().rows[0].target, '好， 你听')
  t.apply([tok(' 停在这里。', 'translation')])
  assert.equal(t.getSnapshot().rows[0].target, '好， 你听 停在这里。')
})

test('a row entirely in the target language has no translation line', () => {
  const t = new Transcript()
  t.apply([tok('然后我们去吃饭。', 'none'), tok('<end>', 'none')])
  assert.deepEqual(t.getSnapshot().rows.map((r) => r.target), [''])
})

// Same recording as the iOS test: real mixed English/Chinese session (→ zh), 2026-10-13.
test('real mixed session fixture', () => {
  const messages = JSON.parse(readFileSync(new URL('./soniox-mixed-session.json', import.meta.url), 'utf8')) as RealtimeToken[][]
  const t = new Transcript()
  for (const tokens of messages) t.apply(tokens)
  const { rows } = t.getSnapshot()
  assert.deepEqual(rows.map((r) => r.source), [
    'Hi.', 'Hello. 小朋友。', 'Today we have a meeting', 'with the client. 然后我们一起去吃饭。',
    'I think the budget is too high. 你觉得呢？',
  ])
  assert.deepEqual(rows.map((r) => r.target), [
    '你好。', '你好。 小朋友。', '今天我们有个会议，', '和客户见面。 然后我们一起去吃饭。',
    '我觉得预算太高了。 你觉得呢？',
  ])
  assert.equal(t.dominantSpokenLanguage(20), 'en')
})
