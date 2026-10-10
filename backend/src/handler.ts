// POST /api/temporary-api-key
// API Gateway's JWT authorizer has already verified the Cognito access token,
// so the caller's identity (`sub`) is trusted here.
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm'
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyResultV2 } from 'aws-lambda'
import { mintTemporaryKey, SonioxError } from './soniox.ts'

const ssm = new SSMClient({})
const PARAMETER_NAME = process.env.SONIOX_KEY_PARAMETER!

// Read once per container. On failure, drop the cached promise so the next
// invocation retries instead of serving a cached error forever.
let longLivedKey: Promise<string> | undefined
function getLongLivedKey(): Promise<string> {
  longLivedKey ??= ssm
    .send(new GetParameterCommand({ Name: PARAMETER_NAME, WithDecryption: true }))
    .then((res) => {
      const value = res.Parameter?.Value
      if (!value) throw new Error(`SSM parameter ${PARAMETER_NAME} is empty`)
      return value
    })
    .catch((err: unknown) => {
      longLivedKey = undefined
      throw err
    })
  return longLivedKey
}

function json(statusCode: number, body: unknown): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    body: JSON.stringify(body),
  }
}

// Structured logs for CloudWatch Logs Insights. Never pass keys in here.
function log(level: 'info' | 'error', msg: string, fields: Record<string, unknown>): void {
  console[level](JSON.stringify({ level, msg, ...fields }))
}

export async function handler(event: APIGatewayProxyEventV2WithJWTAuthorizer): Promise<APIGatewayProxyResultV2> {
  const requestId = event.requestContext.requestId
  const sub = event.requestContext.authorizer?.jwt.claims.sub
  if (typeof sub !== 'string' || !sub) {
    // Unreachable behind the authorizer; defensive in case the route changes.
    return json(401, { error: 'unauthorized' })
  }

  try {
    const key = await mintTemporaryKey(await getLongLivedKey(), sub)
    log('info', 'temporary key issued', { requestId, sub, expiresAt: key.expiresAt })
    return json(200, key)
  } catch (err) {
    const upstream = err instanceof SonioxError
    log('error', 'temporary key failed', {
      requestId,
      sub,
      upstreamStatus: upstream ? err.status : undefined,
      error: err instanceof Error ? err.message : String(err),
    })
    return upstream
      ? json(502, { error: 'upstream_error', message: 'Speech service rejected the request' })
      : json(500, { error: 'internal_error' })
  }
}
