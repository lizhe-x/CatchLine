// Decides what a request is entitled to: free, trial, or paid — from a
// StoreKit 2 signed transaction (JWS) the app sends along.
import {
  Environment,
  OfferDiscountType,
  OfferType,
  SignedDataVerifier,
  type JWSTransactionDecodedPayload,
} from '@apple/app-store-server-library'
import { APPLE_ROOT_CA_G3_DER_BASE64 } from './appleCerts.ts'

export interface QuotaConfig {
  freeDailySeconds: number
  trialSeconds: number
  paidMonthlySeconds: number
}

export type Plan =
  | { kind: 'free'; bucket: string; quotaSeconds: number; resetsAt: string }
  | { kind: 'trial'; bucket: string; quotaSeconds: number; productId: string; endsAt: string }
  | { kind: 'paid'; bucket: string; quotaSeconds: number; productId: string; resetsAt: string }

const ROOTS = [Buffer.from(APPLE_ROOT_CA_G3_DER_BASE64, 'base64')]

export class EntitlementVerifier {
  private readonly sandbox: SignedDataVerifier
  private readonly production?: SignedDataVerifier
  private readonly bundleId: string
  private readonly productIds: Set<string>

  /** `appAppleId` (numeric App Store ID) is required to accept Production transactions. */
  constructor(opts: { bundleId: string; productIds: string[]; appAppleId?: number }) {
    this.bundleId = opts.bundleId
    this.productIds = new Set(opts.productIds)
    this.sandbox = new SignedDataVerifier(ROOTS, false, Environment.SANDBOX, opts.bundleId)
    if (opts.appAppleId) {
      this.production = new SignedDataVerifier(ROOTS, false, Environment.PRODUCTION, opts.bundleId, opts.appAppleId)
    }
  }

  /**
   * Returns the active subscription transaction, or null if the JWS is
   * absent, invalid, expired, revoked, or belongs to another user.
   */
  async verify(jws: string | undefined, userId: string, now = Date.now()): Promise<JWSTransactionDecodedPayload | null> {
    if (!jws) return null
    // Pick the verifier by the claimed environment; the signature check that
    // follows is what makes it trustworthy.
    const claimed = peekEnvironment(jws)
    const verifier = claimed === Environment.PRODUCTION ? this.production : claimed === Environment.SANDBOX ? this.sandbox : undefined
    if (!verifier) return null
    const tx = await verifier.verifyAndDecodeTransaction(jws)
    if (tx.bundleId !== this.bundleId) return null
    if (!tx.productId || !this.productIds.has(tx.productId)) return null
    if (tx.revocationDate) return null
    if (!tx.expiresDate || tx.expiresDate <= now) return null
    // Purchases carry our anonymous user id; a JWS lifted from someone else's
    // device doesn't match the attested caller.
    if (tx.appAccountToken && tx.appAccountToken.toLowerCase() !== userId.toLowerCase()) return null
    return tx
  }
}

export function planFor(
  tx: JWSTransactionDecodedPayload | null,
  quota: QuotaConfig,
  timeZone: string,
  now = new Date(),
): Plan {
  if (tx) {
    const isTrial = tx.offerType === OfferType.INTRODUCTORY_OFFER && tx.offerDiscountType === OfferDiscountType.FREE_TRIAL
    if (isTrial) {
      return {
        kind: 'trial',
        bucket: `trial#${tx.originalTransactionId}`,
        quotaSeconds: quota.trialSeconds,
        productId: tx.productId!,
        endsAt: new Date(tx.expiresDate!).toISOString(),
      }
    }
    // Paid: the allowance resets each calendar month (UTC), for monthly and
    // yearly plans alike.
    const month = now.toISOString().slice(0, 7)
    const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
    return {
      kind: 'paid',
      bucket: `paid#${tx.originalTransactionId}#${month}`,
      quotaSeconds: quota.paidMonthlySeconds,
      productId: tx.productId!,
      resetsAt: next.toISOString(),
    }
  }
  const { date, nextMidnight } = localDay(now, timeZone)
  return { kind: 'free', bucket: `free#${date}`, quotaSeconds: quota.freeDailySeconds, resetsAt: nextMidnight.toISOString() }
}

function peekEnvironment(jws: string): string | undefined {
  try {
    const payload = JSON.parse(Buffer.from(jws.split('.')[1] ?? '', 'base64url').toString()) as { environment?: string }
    return payload.environment
  } catch {
    return undefined
  }
}

/** The user's calendar day, so "3 minutes a day" resets at their midnight. */
export function localDay(now: Date, timeZone: string): { date: string; nextMidnight: Date } {
  let tz = 'UTC'
  try {
    new Intl.DateTimeFormat('en-US', { timeZone })
    tz = timeZone
  } catch {
    // Unknown zone from the client: fall back to UTC.
  }
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(now)
      .map((p) => [p.type, p.value]),
  )
  const date = `${parts.year}-${parts.month}-${parts.day}`
  const secondsIntoDay = Number(parts.hour) * 3600 + Number(parts.minute) * 60 + Number(parts.second)
  const nextMidnight = new Date(now.getTime() + (86400 - secondsIntoDay) * 1000)
  nextMidnight.setUTCMilliseconds(0)
  return { date, nextMidnight }
}
