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

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '..', '')
  // `npm run dev:lan` serves HTTPS on the LAN so iPad/iPhone can use the mic
  // (getUserMedia requires a secure context off localhost).
  const lan = process.env.CATCHLINE_LAN === '1'
  return {
    plugins: [react(), devTemporaryKeyApi(env.SONIOX_API_KEY), ...(lan ? [basicSsl()] : [])],
    server: { host: lan },
  }
})
