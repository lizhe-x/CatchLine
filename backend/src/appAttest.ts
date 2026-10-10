// Server-side App Attest verification.
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
//
// Attestation (once per device key): proves the key lives in the Secure
// Enclave of a real device running our genuine, signed app.
// Assertion (every request): proves the request was signed by that key.
import { createHash, createPublicKey, verify as verifySignature, X509Certificate } from 'node:crypto'
import { decode as decodeCbor } from 'cbor-x'
import { APPLE_APP_ATTESTATION_ROOT_CA_PEM } from './appleCerts.ts'

const ROOT = new X509Certificate(APPLE_APP_ATTESTATION_ROOT_CA_PEM)
// OID 1.2.840.113635.100.8.2 (Apple App Attest nonce extension), DER-encoded.
const NONCE_OID = Buffer.from([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02])
const AAGUID_PRODUCTION = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)])
const AAGUID_DEVELOPMENT = Buffer.from('appattestdevelop')

export type AttestEnvironment = 'production' | 'development'

export class AttestError extends Error {}

function sha256(...parts: Buffer[]): Buffer {
  const h = createHash('sha256')
  for (const p of parts) h.update(p)
  return h.digest()
}

interface AuthData {
  rpIdHash: Buffer
  counter: number
  aaguid?: Buffer
  credentialId?: Buffer
}

function parseAuthData(buf: Buffer, withCredential: boolean): AuthData {
  if (buf.length < 37) throw new AttestError('authData too short')
  const rpIdHash = buf.subarray(0, 32)
  const counter = buf.readUInt32BE(33)
  if (!withCredential) return { rpIdHash, counter }
  if (buf.length < 55) throw new AttestError('authData missing credential')
  const aaguid = buf.subarray(37, 53)
  const idLength = buf.readUInt16BE(53)
  const credentialId = buf.subarray(55, 55 + idLength)
  return { rpIdHash, counter, aaguid, credentialId }
}

/** Reads one DER TLV at `offset`; returns content bounds and the next offset. */
function readTlv(buf: Buffer, offset: number): { start: number; end: number; next: number } {
  let len = buf[offset + 1]
  let start = offset + 2
  if (len & 0x80) {
    const n = len & 0x7f
    len = 0
    for (let i = 0; i < n; i++) len = (len << 8) | buf[start + i]
    start += n
  }
  return { start, end: start + len, next: start + len }
}

/** The 32-byte nonce from the credential certificate's Apple extension. */
function extractNonce(cert: X509Certificate): Buffer {
  const der = cert.raw
  const at = der.indexOf(NONCE_OID)
  if (at < 0) throw new AttestError('nonce extension missing')
  // Extension ::= SEQUENCE { extnID OID, critical BOOLEAN OPTIONAL, extnValue OCTET STRING }
  let tlv = readTlv(der, at)
  if (der[tlv.next] === 0x01) tlv = readTlv(der, tlv.next) // skip `critical`
  if (der[tlv.next] !== 0x04) throw new AttestError('nonce extension malformed')
  const octets = readTlv(der, tlv.next)
  // extnValue: SEQUENCE { [1] EXPLICIT OCTET STRING (32 bytes) } — the nonce is its tail.
  if (octets.end - octets.start < 32) throw new AttestError('nonce too short')
  return der.subarray(octets.end - 32, octets.end)
}

/** Raw uncompressed P-256 point (65 bytes) from a certificate's public key. */
function rawPublicKey(cert: X509Certificate): Buffer {
  const spki = cert.publicKey.export({ format: 'der', type: 'spki' })
  return spki.subarray(spki.length - 65)
}

export interface VerifiedAttestation {
  publicKeyPem: string
  environment: AttestEnvironment
}

export function verifyAttestation(params: {
  attestation: Buffer
  /** The exact bytes the app hashed as clientData (our server challenge). */
  clientData: Buffer
  keyId: string // base64
  appId: string // "<TeamID>.<bundleID>"
  now?: Date
}): VerifiedAttestation {
  const { attestation, clientData, keyId, appId } = params
  const now = params.now ?? new Date()
  const obj = decodeCbor(attestation) as {
    fmt: string
    attStmt: { x5c: Uint8Array[]; receipt: Uint8Array }
    authData: Uint8Array
  }
  if (obj?.fmt !== 'apple-appattest') throw new AttestError('unexpected attestation format')

  // 1. Certificate chain: credential cert ← intermediate ← Apple App Attestation Root.
  const [credCert, intermediate] = obj.attStmt.x5c.map((der) => new X509Certificate(Buffer.from(der)))
  if (!credCert || !intermediate) throw new AttestError('certificate chain incomplete')
  for (const [cert, issuer] of [
    [credCert, intermediate],
    [intermediate, ROOT],
  ] as const) {
    if (!cert.checkIssued(issuer) || !cert.verify(issuer.publicKey)) throw new AttestError('certificate chain invalid')
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) throw new AttestError('certificate expired')
  }

  // 2-4. nonce = SHA256(authData ‖ SHA256(clientData)) must match the cert extension.
  const authDataBuf = Buffer.from(obj.authData)
  const nonce = sha256(authDataBuf, sha256(clientData))
  if (!nonce.equals(extractNonce(credCert))) throw new AttestError('nonce mismatch')

  // 5. Key identifier = SHA256 of the public key.
  const keyIdBytes = Buffer.from(keyId, 'base64')
  if (!sha256(rawPublicKey(credCert)).equals(keyIdBytes)) throw new AttestError('key id mismatch')

  // 6-9. authData: our app, fresh key, known environment, matching credential.
  const auth = parseAuthData(authDataBuf, true)
  if (!auth.rpIdHash.equals(sha256(Buffer.from(appId)))) throw new AttestError('app id mismatch')
  if (auth.counter !== 0) throw new AttestError('counter must start at 0')
  let environment: AttestEnvironment
  if (auth.aaguid!.equals(AAGUID_PRODUCTION)) environment = 'production'
  else if (auth.aaguid!.equals(AAGUID_DEVELOPMENT)) environment = 'development'
  else throw new AttestError('unknown aaguid')
  if (!auth.credentialId!.equals(keyIdBytes)) throw new AttestError('credential id mismatch')

  return {
    publicKeyPem: credCert.publicKey.export({ format: 'pem', type: 'spki' }).toString(),
    environment,
  }
}

/** Verifies a per-request assertion; returns the new counter to store. */
export function verifyAssertion(params: {
  assertion: Buffer
  clientData: Buffer
  publicKeyPem: string
  previousCounter: number
  appId: string
}): number {
  const obj = decodeCbor(params.assertion) as { signature: Uint8Array; authenticatorData: Uint8Array }
  if (!obj?.signature || !obj.authenticatorData) throw new AttestError('assertion malformed')
  const authData = Buffer.from(obj.authenticatorData)
  const nonce = sha256(authData, sha256(params.clientData))
  const ok = verifySignature('sha256', nonce, createPublicKey(params.publicKeyPem), Buffer.from(obj.signature))
  if (!ok) throw new AttestError('assertion signature invalid')

  const auth = parseAuthData(authData, false)
  if (!auth.rpIdHash.equals(sha256(Buffer.from(params.appId)))) throw new AttestError('app id mismatch')
  // Strictly increasing counter defeats replay of a captured request.
  if (auth.counter <= params.previousCounter) throw new AttestError('assertion counter replayed')
  return auth.counter
}
