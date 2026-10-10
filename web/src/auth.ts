import { InMemoryWebStorage, UserManager, WebStorageStateStore } from 'oidc-client-ts'

// Cognito OAuth 2.0 Authorization Code + PKCE via oidc-client-ts.
// Settings come from /config.json, written by CDK at deploy time. Local dev
// has no config.json: login is skipped and the Vite mock issues keys.

interface WebConfig {
  authority: string
  cognitoDomain: string
  clientId: string
  redirectUri: string
  logoutUri: string
}

let config: WebConfig | null = null
let manager: UserManager | null = null

const CALLBACK_PATH = '/auth/callback'

/**
 * Resolves true when the app may render (signed in, or auth disabled).
 * Resolves false when the page is navigating away to the login screen.
 */
export async function initAuth(): Promise<boolean> {
  config = await loadConfig()
  if (!config) return true

  manager = new UserManager({
    authority: config.authority,
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    post_logout_redirect_uri: config.logoutUri,
    response_type: 'code',
    scope: 'openid email profile',
    // Tokens stay in memory only (XSS can't lift them from storage). A reload
    // re-runs the redirect, which is instant while the Cognito session lasts.
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    automaticSilentRenew: true,
  })

  if (location.pathname === CALLBACK_PATH) {
    try {
      await manager.signinRedirectCallback()
      history.replaceState(null, '', '/')
      return true
    } catch (err) {
      console.error('[auth] callback failed', err)
      // Stale/replayed callback URL: start over.
    }
  }

  const user = await manager.getUser()
  if (user && !user.expired) return true
  await manager.signinRedirect()
  return false
}

export function authEnabled(): boolean {
  return manager !== null
}

export async function getAccessToken(): Promise<string | null> {
  if (!manager) return null
  let user = await manager.getUser()
  if (!user || user.expired) {
    try {
      user = await manager.signinSilent() // uses the refresh token
    } catch {
      await manager.signinRedirect()
      return null
    }
  }
  return user?.access_token ?? null
}

export async function signOut(): Promise<void> {
  if (!manager || !config) return
  await manager.removeUser()
  // Cognito's logout endpoint isn't in its OIDC discovery doc; build it by hand.
  const url = new URL('/logout', config.cognitoDomain)
  url.searchParams.set('client_id', config.clientId)
  url.searchParams.set('logout_uri', config.logoutUri)
  location.assign(url.toString())
}

async function loadConfig(): Promise<WebConfig | null> {
  try {
    const res = await fetch('/config.json', { cache: 'no-cache' })
    if (!res.ok || !res.headers.get('content-type')?.includes('json')) return null
    return (await res.json()) as WebConfig
  } catch {
    return null
  }
}
