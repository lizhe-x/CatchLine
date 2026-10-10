import assert from 'node:assert/strict'
import { createHash, generateKeyPairSync, sign } from 'node:crypto'
import { test } from 'node:test'
import { encode } from 'cbor-x'
import { verifyAssertion } from '../src/appAttest.ts'

const APP_ID = 'GZ4LT9W9H9.com.deskfox.catchline'
const sha256 = (...b: Buffer[]) => b.reduce((h, x) => h.update(x), createHash('sha256')).digest()

// Simulates what DCAppAttestService.generateAssertion produces.
function makeAssertion(privateKey: Parameters<typeof sign>[2], clientData: Buffer, counter: number, appId = APP_ID) {
  const authData = Buffer.alloc(37)
  sha256(Buffer.from(appId)).copy(authData, 0)
  authData[32] = 0x40
  authData.writeUInt32BE(counter, 33)
  const nonce = sha256(authData, sha256(clientData))
  const signature = sign('sha256', nonce, privateKey)
  return Buffer.from(encode({ signature, authenticatorData: authData }))
}

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
const publicKeyPem = publicKey.export({ format: 'pem', type: 'spki' }).toString()
const body = Buffer.from(JSON.stringify({ userId: 'u', ts: 1 }))

test('accepts a valid assertion and returns its counter', () => {
  const counter = verifyAssertion({ assertion: makeAssertion(privateKey, body, 5), clientData: body, publicKeyPem, previousCounter: 4, appId: APP_ID })
  assert.equal(counter, 5)
})

test('rejects a replayed counter', () => {
  assert.throws(() => verifyAssertion({ assertion: makeAssertion(privateKey, body, 5), clientData: body, publicKeyPem, previousCounter: 5, appId: APP_ID }), /replayed/)
})

test('rejects a tampered body', () => {
  const tampered = Buffer.from(JSON.stringify({ userId: 'someone-else', ts: 1 }))
  assert.throws(() => verifyAssertion({ assertion: makeAssertion(privateKey, body, 6), clientData: tampered, publicKeyPem, previousCounter: 5, appId: APP_ID }), /signature/)
})

test('rejects another app', () => {
  assert.throws(() => verifyAssertion({ assertion: makeAssertion(privateKey, body, 6, 'XXXX.com.evil'), clientData: body, publicKeyPem, previousCounter: 5, appId: APP_ID }), /app id/)
})

test('rejects a different key', () => {
  const other = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  assert.throws(() => verifyAssertion({ assertion: makeAssertion(other.privateKey, body, 6), clientData: body, publicKeyPem, previousCounter: 5, appId: APP_ID }), /signature/)
})
