// POST /api/temporary-api-key
// API Gateway's JWT authorizer has already verified the Cognito access token,
// so the caller's identity (`sub`) is trusted here.
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyResultV2 } from 'aws-lambda'
import { mintTemporaryKey, SonioxError } from './soniox.ts'
import { getLongLivedKey } from './sonioxKey.ts'

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
