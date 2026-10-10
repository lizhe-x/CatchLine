import assert from 'node:assert/strict'
import { test } from 'node:test'
import { localDay, planFor } from '../src/entitlement.ts'
import { leaseCharge } from '../src/store.ts'

const quota = { freeDailySeconds: 180, trialSeconds: 10800, paidMonthlySeconds: 144000 }
const now = new Date('2026-10-10T23:30:00Z')

test('free plan uses the caller’s local day', () => {
  const shanghai = planFor(null, quota, 'Asia/Shanghai', now)
  assert.equal(shanghai.kind, 'free')
  assert.equal(shanghai.bucket, 'free#2026-10-11') // already the 11th in Shanghai
  assert.equal(shanghai.resetsAt, '2026-10-11T16:00:00.000Z')
  assert.equal(planFor(null, quota, 'America/New_York', now).bucket, 'free#2026-10-10')
  assert.equal(planFor(null, quota, 'Not/AZone', now).bucket, 'free#2026-10-10') // UTC fallback
})

test('trial vs paid from the transaction', () => {
  const base = { originalTransactionId: '2000', productId: 'com.deskfox.catchline.monthly', expiresDate: now.getTime() + 86400000 }
  const trial = planFor({ ...base, offerType: 1, offerDiscountType: 'FREE_TRIAL' } as never, quota, 'UTC', now)
  assert.equal(trial.kind, 'trial')
  assert.equal(trial.bucket, 'trial#2000')
  assert.equal(trial.quotaSeconds, 10800)
  const paid = planFor(base as never, quota, 'UTC', now)
  assert.equal(paid.kind, 'paid')
  assert.equal(paid.bucket, 'paid#2000#2026-10')
  assert.equal((paid as { resetsAt: string }).resetsAt, '2026-11-01T00:00:00.000Z')
})

test('lease charge: server time, per second rounded down, capped at the lease', () => {
  const lease = { bucket: 'b', issuedAt: 1_000_000, seconds: 600 }
  assert.equal(leaseCharge(lease, 1_000_000 + 42_900), 42)
  assert.equal(leaseCharge(lease, 1_000_000 + 3_600_000), 600)
  assert.equal(leaseCharge(lease, 999_000), 0)
  assert.equal(localDay(now, 'UTC').date, '2026-10-10')
})
