// iOS API — no accounts. Callers prove they're our genuine app with App
// Attest, carry an anonymous user id (synced via iCloud Keychain), and
// optionally a StoreKit 2 signed transaction proving a subscription.
//
//   POST /api/attest/challenge   → { challenge }
//   POST /api/attest/register    { keyId, attestation, challenge, userId }
//   POST /api/session/status     (attested) → plan + remaining seconds
//   POST /api/session            (attested) → Soniox key for one lease
//   POST /api/session/end        (attested) → settle the open lease
//
// Metering: each Soniox key opens one stream capped at the lease length
// (≤ 10 min, ≤ remaining allowance). The server charges a lease by its own
// clock when it's ended or superseded, so the client can't under-report.
import { randomBytes } from 'node:crypto'
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda'
import { AttestError, verifyAssertion, verifyAttestation } from './appAttest.ts'
import { EntitlementVerifier, planFor, type Plan, type QuotaConfig } from './entitlement.ts'
import { mintTemporaryKey, SonioxError } from './soniox.ts'
import { getLongLivedKey } from './sonioxKey.ts'
import { leaseCharge, Store, type DeviceKey } from './store.ts'

const env = process.env
const APP_ID = `${env.TEAM_ID}.${env.BUNDLE_ID}`
const ALLOW_DEV_ATTEST = env.ALLOW_DEV_ATTEST === 'true'
const MAX_LEASE_SECONDS = 600
const MIN_LEASE_SECONDS = 10
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000
const quota: QuotaConfig = {
  freeDailySeconds: Number(env.FREE_DAILY_SECONDS),
  trialSeconds: Number(env.TRIAL_SECONDS),
  paidMonthlySeconds: Number(env.PAID_MONTHLY_SECONDS),
}

const store = new Store(env.TABLE_NAME!)
const entitlements = new EntitlementVerifier({
  bundleId: env.BUNDLE_ID!,
  productIds: env.PRODUCT_IDS!.split(','),
  appAppleId: env.APP_APPLE_ID ? Number(env.APP_APPLE_ID) : undefined,
})

class HttpError extends Error {
  readonly status: number
  readonly code: string
  readonly extra?: Record<string, unknown>
  constructor(status: number, code: string, extra?: Record<string, unknown>) {
    super(code)
    this.status = status
    this.code = code
    this.extra = extra
  }
}

function json(statusCode: number, body: unknown): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    body: JSON.stringify(body),
  }
}

function log(level: 'info' | 'warn' | 'error', msg: string, fields: Record<string, unknown>): void {
  console[level](JSON.stringify({ level, msg, ...fields }))
}

function rawBody(event: APIGatewayProxyEventV2): Buffer {
  if (!event.body) return Buffer.alloc(0)
  return event.isBase64Encoded ? Buffer.from(event.body, 'base64') : Buffer.from(event.body, 'utf8')
}

function parse<T>(body: Buffer): T {
  try {
    return JSON.parse(body.toString('utf8')) as T
  } catch {
    throw new HttpError(400, 'invalid_json')
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface AttestedBody {
  userId: string
  ts: number
  timeZone?: string
  /** StoreKit 2 `Transaction.jwsRepresentation` of the current entitlement. */
  entitlement?: string
}

/**
 * Verifies the App Attest assertion over the exact request bytes and
 * returns the device key + parsed body. The assertion counter makes every
 * signed request single-use.
 */
async function authenticate(event: APIGatewayProxyEventV2): Promise<{ key: DeviceKey; body: AttestedBody }> {
  const keyId = event.headers['x-attest-key-id']
  const assertion = event.headers['x-attest-assertion']
  if (!keyId || !assertion) throw new HttpError(401, 'attestation_required')
  const key = await store.getKey(keyId)
  if (!key) throw new HttpError(401, 'unknown_key') // app re-attests on this

  const bytes = rawBody(event)
  let counter: number
  try {
    counter = verifyAssertion({
      assertion: Buffer.from(assertion, 'base64'),
      clientData: bytes,
      publicKeyPem: key.publicKeyPem,
      previousCounter: key.counter,
      appId: APP_ID,
    })
  } catch (err) {
    log('warn', 'assertion rejected', { keyId, reason: (err as Error).message })
    throw new HttpError(401, 'invalid_assertion')
  }
  if (!(await store.advanceCounter(keyId, key.counter, counter))) throw new HttpError(401, 'invalid_assertion')

  const body = parse<AttestedBody>(bytes)
  if (body.userId?.toLowerCase() !== key.userId.toLowerCase()) throw new HttpError(403, 'user_mismatch')
  if (typeof body.ts !== 'number' || Math.abs(Date.now() - body.ts) > MAX_CLOCK_SKEW_MS) {
    throw new HttpError(401, 'stale_request')
  }
  return { key, body }
}

async function currentPlan(body: AttestedBody): Promise<Plan> {
  let tx = null
  try {
    tx = await entitlements.verify(body.entitlement, body.userId)
  } catch (err) {
    // Bad/forged JWS: treat as free rather than failing the request.
    log('warn', 'entitlement rejected', { userId: body.userId, reason: (err as Error).message })
  }
  return planFor(tx, quota, body.timeZone ?? 'UTC')
}

function planView(plan: Plan, usedSeconds: number) {
  const { bucket: _bucket, ...rest } = plan
  return { ...rest, usedSeconds, remainingSeconds: Math.max(0, plan.quotaSeconds - usedSeconds) }
}

/** Charges and removes the user's open lease, if any. */
async function settleLease(userId: string): Promise<void> {
  const lease = await store.takeLease(userId)
  if (lease) await store.addUsage(userId, lease.bucket, leaseCharge(lease))
}

// --- Routes -----------------------------------------------------------------

async function challenge(): Promise<APIGatewayProxyResultV2> {
  const value = randomBytes(32).toString('base64url')
  await store.putChallenge(value)
  return json(200, { challenge: value })
}

async function register(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const body = parse<{ keyId?: string; attestation?: string; challenge?: string; userId?: string }>(rawBody(event))
  const { keyId, attestation, challenge, userId } = body
  if (!keyId || !attestation || !challenge || !userId || !UUID.test(userId)) throw new HttpError(400, 'invalid_request')
  if (!(await store.consumeChallenge(challenge))) throw new HttpError(400, 'invalid_challenge')

  let verified
  try {
    verified = verifyAttestation({
      attestation: Buffer.from(attestation, 'base64'),
      clientData: Buffer.from(challenge, 'utf8'),
      keyId,
      appId: APP_ID,
    })
  } catch (err) {
    if (err instanceof AttestError) {
      log('warn', 'attestation rejected', { keyId, reason: err.message })
      throw new HttpError(401, 'invalid_attestation')
    }
    throw err
  }
  if (verified.environment === 'development' && !ALLOW_DEV_ATTEST) throw new HttpError(401, 'development_attestation')

  await store.putKey({ keyId, publicKeyPem: verified.publicKeyPem, counter: 0, userId, environment: verified.environment })
  log('info', 'device key registered', { keyId, userId, environment: verified.environment })
  return json(200, { ok: true })
}

async function status(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const { body } = await authenticate(event)
  const plan = await currentPlan(body)
  let used = await store.usedSeconds(body.userId, plan.bucket)
  const lease = await store.getLease(body.userId)
  if (lease?.bucket === plan.bucket) used += leaseCharge(lease)
  return json(200, { plan: planView(plan, used) })
}

async function startSession(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const { body } = await authenticate(event)
  const plan = await currentPlan(body)

  // A new lease supersedes the previous one (stream ended or reconnecting).
  await settleLease(body.userId)
  const used = await store.usedSeconds(body.userId, plan.bucket)
  const remaining = plan.quotaSeconds - used
  if (remaining < MIN_LEASE_SECONDS) {
    log('info', 'quota exhausted', { userId: body.userId, plan: plan.kind })
    throw new HttpError(402, 'quota_exhausted', { plan: planView(plan, used) })
  }

  const leaseSeconds = Math.min(remaining, MAX_LEASE_SECONDS)
  const key = await mintTemporaryKey(await getLongLivedKey(), body.userId, leaseSeconds)
  await store.putLease(body.userId, { bucket: plan.bucket, issuedAt: Date.now(), seconds: leaseSeconds })
  log('info', 'session lease issued', { userId: body.userId, plan: plan.kind, leaseSeconds, remaining })
  return json(200, { apiKey: key.apiKey, expiresAt: key.expiresAt, leaseSeconds, plan: planView(plan, used) })
}

async function endSession(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const { body } = await authenticate(event)
  await settleLease(body.userId)
  const plan = await currentPlan(body)
  const used = await store.usedSeconds(body.userId, plan.bucket)
  return json(200, { plan: planView(plan, used) })
}

const routes: Record<string, (event: APIGatewayProxyEventV2) => Promise<APIGatewayProxyResultV2>> = {
  'POST /api/attest/challenge': challenge,
  'POST /api/attest/register': register,
  'POST /api/session/status': status,
  'POST /api/session': startSession,
  'POST /api/session/end': endSession,
}

export async function handler(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const route = routes[event.routeKey]
  if (!route) return json(404, { error: 'not_found' })
  try {
    return await route(event)
  } catch (err) {
    if (err instanceof HttpError) return json(err.status, { error: err.code, ...err.extra })
    const upstream = err instanceof SonioxError
    log('error', 'request failed', {
      route: event.routeKey,
      requestId: event.requestContext.requestId,
      upstreamStatus: upstream ? err.status : undefined,
      error: err instanceof Error ? err.message : String(err),
    })
    return upstream ? json(502, { error: 'upstream_error' }) : json(500, { error: 'internal_error' })
  }
}
