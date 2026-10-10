import basicSsl from '@vitejs/plugin-basic-ssl'
import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv, type Plugin } from 'vite'
import { mintTemporaryKey, SonioxError } from '../backend/src/soniox.ts'

// Local stand-in for `POST /api/temporary-api-key` (API Gateway + Lambda in
// production). Reads the long-lived key from the repo-root .env, which is
// gitignored. No auth here: it only binds to your machine / LAN in dev.
function devTemporaryKeyApi(longLivedKey: string | undefined): Plugin {
  return {
    name: 'catchline-dev-temporary-key',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/api/temporary-api-key', async (req, res) => {
        res.setHeader('Content-Type', 'application/json')
        if (req.method !== 'POST') {
          res.statusCode = 405
          res.end(JSON.stringify({ error: 'method_not_allowed' }))
          return
        }
        if (!longLivedKey) {
          res.statusCode = 500
          res.end(JSON.stringify({ error: 'SONIOX_API_KEY missing from .env' }))
          return
        }
        try {
          const key = await mintTemporaryKey(longLivedKey, 'local-dev')
          res.end(JSON.stringify(key))
        } catch (err) {
          const status = err instanceof SonioxError ? 502 : 500
          server.config.logger.error(`[temporary-api-key] ${(err as Error).message}`)
          res.statusCode = status
          res.end(JSON.stringify({ error: 'temporary_key_failed' }))
        }
      })
    },
  }
}

// Local stand-in for the iOS API (/api/session*). No App Attest or StoreKit:
// everyone is on a "free" plan metered in memory, so the simulator can
// exercise lease renewal and quota exhaustion. Tunables (env):
// MOCK_QUOTA_SECONDS (default 180), MOCK_LEASE_SECONDS (default 600).
function devSessionApi(longLivedKey: string | undefined): Plugin {
  const quota = Number(process.env.MOCK_QUOTA_SECONDS ?? 180)
  const maxLease = Number(process.env.MOCK_LEASE_SECONDS ?? 600)
  let used = 0
  let lease: { issuedAt: number; seconds: number } | null = null
  const settle = () => {
    if (lease) used += Math.min(lease.seconds, Math.floor((Date.now() - lease.issuedAt) / 1000))
    lease = null
  }
  const plan = () => ({
    kind: 'free',
    quotaSeconds: quota,
    usedSeconds: used,
    remainingSeconds: Math.max(0, quota - used),
    resetsAt: new Date(Date.now() + 86_400_000).toISOString(),
  })
  return {
    name: 'catchline-dev-session',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/api/session', async (req, res) => {
        res.setHeader('Content-Type', 'application/json')
        const send = (status: number, body: unknown) => {
          res.statusCode = status
          res.end(JSON.stringify(body))
        }
        if (req.method !== 'POST') return send(405, { error: 'method_not_allowed' })
        const route = req.url?.split('?')[0] ?? '/'
        if (route === '/status') {
          const open = lease ? Math.min(lease.seconds, Math.floor((Date.now() - lease.issuedAt) / 1000)) : 0
          return send(200, { plan: { ...plan(), usedSeconds: used + open, remainingSeconds: Math.max(0, quota - used - open) } })
        }
        if (route === '/end') {
          settle()
          return send(200, { plan: plan() })
        }
        settle()
        const remaining = quota - used
        if (remaining < 10) return send(402, { error: 'quota_exhausted', plan: plan() })
        if (!longLivedKey) return send(500, { error: 'SONIOX_API_KEY missing from .env' })
        const seconds = Math.min(remaining, maxLease)
        try {
          const key = await mintTemporaryKey(longLivedKey, 'local-dev', seconds)
          const current = plan()
          lease = { issuedAt: Date.now(), seconds }
          server.config.logger.info(`[session] lease ${seconds}s, remaining ${remaining}s`)
          send(200, { apiKey: key.apiKey, expiresAt: key.expiresAt, leaseSeconds: seconds, plan: current })
        } catch (err) {
          server.config.logger.error(`[session] ${(err as Error).message}`)
          send(502, { error: 'upstream_error' })
        }
      })
    },
  }
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '..', '')
  // `npm run dev:lan` serves HTTPS on the LAN so iPad/iPhone can use the mic
  // (getUserMedia requires a secure context off localhost).
  const lan = process.env.CATCHLINE_LAN === '1'
  return {
    plugins: [react(), devTemporaryKeyApi(env.SONIOX_API_KEY), devSessionApi(env.SONIOX_API_KEY), ...(lan ? [basicSsl()] : [])],
    server: { host: lan },
  }
})
