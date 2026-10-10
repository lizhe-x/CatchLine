// DynamoDB single-table storage for the iOS API.
//
//   PK                SK            what
//   CHAL#<challenge>  -             one-time App Attest challenge (TTL 5 min)
//   KEY#<keyId>       -             attested device key: public key, counter, userId
//   USER#<userId>     B#<bucket>    seconds used in a quota bucket (free day / trial / paid month)
//   USER#<userId>     LEASE         the open streaming lease, if any
import { ConditionalCheckFailedException, DynamoDBClient } from '@aws-sdk/client-dynamodb'
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb'

const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}))
const nowSeconds = () => Math.floor(Date.now() / 1000)

export interface DeviceKey {
  keyId: string
  publicKeyPem: string
  counter: number
  userId: string
  environment: string
}

export interface Lease {
  bucket: string
  issuedAt: number // epoch ms
  seconds: number
}

export class Store {
  private readonly table: string
  constructor(table: string) {
    this.table = table
  }

  async putChallenge(challenge: string): Promise<void> {
    await doc.send(
      new PutCommand({ TableName: this.table, Item: { PK: `CHAL#${challenge}`, SK: '-', ttl: nowSeconds() + 300 } }),
    )
  }

  /** True once per issued, unexpired challenge (delete-on-read). */
  async consumeChallenge(challenge: string): Promise<boolean> {
    const res = await doc.send(
      new DeleteCommand({ TableName: this.table, Key: { PK: `CHAL#${challenge}`, SK: '-' }, ReturnValues: 'ALL_OLD' }),
    )
    const ttl = res.Attributes?.ttl as number | undefined
    return ttl !== undefined && ttl > nowSeconds()
  }

  async putKey(key: DeviceKey): Promise<void> {
    await doc.send(
      new PutCommand({
        TableName: this.table,
        Item: { PK: `KEY#${key.keyId}`, SK: '-', ...key, createdAt: new Date().toISOString() },
        ConditionExpression: 'attribute_not_exists(PK)',
      }),
    )
  }

  async getKey(keyId: string): Promise<DeviceKey | undefined> {
    const res = await doc.send(new GetCommand({ TableName: this.table, Key: { PK: `KEY#${keyId}`, SK: '-' } }))
    return res.Item as DeviceKey | undefined
  }

  /** Advances the assertion counter; false if a concurrent request got there first. */
  async advanceCounter(keyId: string, from: number, to: number): Promise<boolean> {
    try {
      await doc.send(
        new UpdateCommand({
          TableName: this.table,
          Key: { PK: `KEY#${keyId}`, SK: '-' },
          UpdateExpression: 'SET #c = :to',
          ConditionExpression: '#c = :from',
          ExpressionAttributeNames: { '#c': 'counter' },
          ExpressionAttributeValues: { ':from': from, ':to': to },
        }),
      )
      return true
    } catch (err) {
      if (err instanceof ConditionalCheckFailedException) return false
      throw err
    }
  }

  async usedSeconds(userId: string, bucket: string): Promise<number> {
    const res = await doc.send(new GetCommand({ TableName: this.table, Key: { PK: `USER#${userId}`, SK: `B#${bucket}` } }))
    return (res.Item?.used as number | undefined) ?? 0
  }

  async addUsage(userId: string, bucket: string, seconds: number): Promise<void> {
    if (seconds <= 0) return
    await doc.send(
      new UpdateCommand({
        TableName: this.table,
        Key: { PK: `USER#${userId}`, SK: `B#${bucket}` },
        UpdateExpression: 'ADD used :s SET updatedAt = :t',
        ExpressionAttributeValues: { ':s': seconds, ':t': new Date().toISOString() },
      }),
    )
  }

  async getLease(userId: string): Promise<Lease | undefined> {
    const res = await doc.send(new GetCommand({ TableName: this.table, Key: { PK: `USER#${userId}`, SK: 'LEASE' } }))
    return res.Item as Lease | undefined
  }

  async putLease(userId: string, lease: Lease): Promise<void> {
    await doc.send(new PutCommand({ TableName: this.table, Item: { PK: `USER#${userId}`, SK: 'LEASE', ...lease } }))
  }

  /** Removes and returns the open lease (atomic, so it's only charged once). */
  async takeLease(userId: string): Promise<Lease | undefined> {
    const res = await doc.send(
      new DeleteCommand({ TableName: this.table, Key: { PK: `USER#${userId}`, SK: 'LEASE' }, ReturnValues: 'ALL_OLD' }),
    )
    return res.Attributes as Lease | undefined
  }
}

/**
 * Seconds to charge for a lease, by the server's clock (never the client's).
 * Billed per second, rounded *down*: partial seconds are on us.
 */
export function leaseCharge(lease: Lease, now = Date.now()): number {
  return Math.min(lease.seconds, Math.max(0, Math.floor((now - lease.issuedAt) / 1000)))
}
