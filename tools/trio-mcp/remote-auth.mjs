import fs from 'node:fs'
import path from 'node:path'
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import express from 'express'
import { createOAuthMetadata, mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js'
import {
  InvalidClientMetadataError, InvalidGrantError, InvalidRequestError,
  InvalidScopeError, InvalidTargetError, InvalidTokenError, TooManyRequestsError
} from '@modelcontextprotocol/sdk/server/auth/errors.js'

const SECOND = 1000
const DAY = 86400 * SECOND
const ACCESS_TTL = 3600 * SECOND
const REFRESH_TTL = 30 * DAY
const PENDING_TTL = 5 * 60 * SECOND
const CODE_TTL = 60 * SECOND
const MAX_CLIENTS = 100
const MAX_TOKENS = 4096
const MAX_PENDING = 64
const COOKIE = '__Host-trio-consent'
const hash = value => createHash('sha256').update(value).digest('hex')
const random = () => randomBytes(32).toString('base64url')
const escape = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]))
const sameHash = (value, digest) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(digest) && timingSafeEqual(Buffer.from(hash(value), 'hex'), Buffer.from(digest, 'hex'))

function publicOrigin(value) {
  if (typeof value !== 'string' || /[\s\\\x00-\x1f\x7f]/.test(value)) throw new Error('A canonical HTTPS public origin is required')
  const url = new URL(value)
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/' || ![url.origin, `${url.origin}/`].includes(value)) {
    throw new Error('A canonical HTTPS public origin is required')
  }
  return url.origin
}

function redirectAllowed(value, extra) {
  if (typeof value !== 'string' || value.length > 2048 || /[\s\\]/.test(value)) return false
  try {
    const url = new URL(value)
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.href !== value) return false
    return value === 'https://claude.ai/api/mcp/auth_callback' ||
      value === 'https://chatgpt.com/connector_platform_oauth_redirect' ||
      (url.origin === 'https://chatgpt.com' && /^\/connector\/oauth\/[A-Za-z0-9_-]{1,200}$/.test(url.pathname)) || extra.has(value)
  } catch { return false }
}

// This module owns OAuth state only. It never imports or opens Trio's therapy storage.
export function createRemoteAuth({ publicUrl, ownerKeyHash, stateFile, allowedRedirects = [] }) {
  const origin = publicOrigin(publicUrl)
  const resourceUrl = new URL('/mcp', origin)
  const scope = 'trio'
  if (!/^[a-f0-9]{64}$/.test(ownerKeyHash)) throw new Error('ownerKeyHash must be a SHA-256 hex digest')
  if (typeof stateFile !== 'string' || !path.isAbsolute(stateFile)) throw new Error('An absolute private OAuth state file is required')
  if (!Array.isArray(allowedRedirects) || allowedRedirects.length > 20) throw new Error('Invalid redirect allowlist')
  const extra = new Set(allowedRedirects)
  if (allowedRedirects.some(url => !redirectAllowed(url, extra))) throw new Error('Allowlisted callbacks must be canonical HTTPS URLs without query or fragment')
  let state = { version: 1, origin, ownerKeyHash, clients: {}, tokens: {} }
  if (fs.existsSync(stateFile)) {
    const stat = fs.lstatSync(stateFile)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 2 * 1024 * 1024) throw new Error('Invalid OAuth state file')
    const saved = JSON.parse(fs.readFileSync(stateFile, 'utf8'))
    if (saved.version !== 1 || saved.origin !== origin || saved.ownerKeyHash !== ownerKeyHash ||
      !saved.clients || !saved.tokens || typeof saved.clients !== 'object' || typeof saved.tokens !== 'object' || Array.isArray(saved.clients) || Array.isArray(saved.tokens) ||
      Object.keys(saved.clients).length > MAX_CLIENTS || Object.keys(saved.tokens).length > MAX_TOKENS) throw new Error('OAuth state does not match this server configuration')
    for (const [id, entry] of Object.entries(saved.clients)) {
      if (!entry || entry.client?.client_id !== id || (entry.expiresAt !== null && !Number.isFinite(entry.expiresAt)) ||
        entry.client.token_endpoint_auth_method !== 'none' || entry.client.client_secret ||
        !Array.isArray(entry.client.redirect_uris) || !entry.client.redirect_uris.length ||
        entry.client.redirect_uris.some(url => !redirectAllowed(url, extra))) throw new Error('Invalid saved OAuth client')
    }
    for (const [digest, token] of Object.entries(saved.tokens)) {
      if (!/^[a-f0-9]{64}$/.test(digest) || !token || !['access', 'refresh'].includes(token.kind) ||
        !Number.isFinite(token.expiresAt) || typeof token.clientId !== 'string' || typeof token.family !== 'string' ||
        token.resource !== resourceUrl.href || token.scope !== scope || typeof token.used !== 'boolean') throw new Error('Invalid saved OAuth token')
    }
    fs.chmodSync(stateFile, 0o600)
    state = saved
  }
  const pending = new Map()
  const codes = new Map()
  let consentWindow = { start: Date.now(), count: 0 }
  const prune = () => {
    const now = Date.now()
    for (const [id, entry] of Object.entries(state.clients)) if (entry.expiresAt !== null && entry.expiresAt <= now) delete state.clients[id]
    for (const [id, token] of Object.entries(state.tokens)) if (token.expiresAt <= now || !state.clients[token.clientId]) delete state.tokens[id]
    for (const map of [pending, codes]) for (const [id, item] of map) if (item.expiresAt <= now) map.delete(id)
  }
  const save = () => {
    fs.mkdirSync(path.dirname(stateFile), { recursive: true, mode: 0o700 })
    const temporary = `${stateFile}.${random()}.tmp`
    try {
      fs.writeFileSync(temporary, JSON.stringify(state), { mode: 0o600, flag: 'wx' })
      fs.renameSync(temporary, stateFile)
    } finally { fs.rmSync(temporary, { force: true }) }
  }
  const scopes = values => {
    if (values !== undefined && values.length && (values.length !== 1 || values[0] !== scope)) throw new InvalidScopeError('Only the trio scope is supported')
    return [scope]
  }
  const resource = value => {
    if (value !== undefined && value.href !== resourceUrl.href) throw new InvalidTargetError('Invalid MCP resource')
    return resourceUrl.href
  }
  const codeFor = (client, raw) => {
    prune()
    const code = typeof raw === 'string' ? codes.get(hash(raw)) : undefined
    if (!code || code.clientId !== client.client_id || !state.clients[client.client_id]) throw new InvalidGrantError('Invalid or expired authorization code')
    return code
  }
  const removeFamily = family => {
    for (const [key, token] of Object.entries(state.tokens)) if (token.family === family) delete state.tokens[key]
  }
  const issue = (clientId, family = random()) => {
    prune()
    if (Object.keys(state.tokens).length + 2 > MAX_TOKENS) throw new TooManyRequestsError('Too many active grants; revoke an existing connection')
    const access = random()
    const refresh = random()
    const now = Date.now()
    for (const [kind, raw, ttl] of [['access', access, ACCESS_TTL], ['refresh', refresh, REFRESH_TTL]]) {
      state.tokens[hash(raw)] = { kind, clientId, family, resource: resourceUrl.href, scope, expiresAt: now + ttl, used: false }
    }
    // Chat clients retain their registered client ID even when all tokens have expired.
    state.clients[clientId].expiresAt = null
    save()
    return { access_token: access, token_type: 'Bearer', expires_in: ACCESS_TTL / SECOND, refresh_token: refresh, scope }
  }
  const provider = {
    clientsStore: {
      async getClient(id) { prune(); return state.clients[id]?.client },
      async registerClient(input) {
        prune()
        if (typeof input.client_id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(input.client_id)) throw new InvalidClientMetadataError('Invalid generated client identifier')
        const method = input.token_endpoint_auth_method
        if (method !== undefined && method !== 'none') throw new InvalidClientMetadataError('Only public PKCE clients (none) are supported')
        if (!Array.isArray(input.redirect_uris) || !input.redirect_uris.length || input.redirect_uris.length > 5 ||
          input.redirect_uris.some(url => !redirectAllowed(url, extra))) throw new InvalidClientMetadataError('Redirect URI is not allowed')
        if ((input.grant_types && (!input.grant_types.includes('authorization_code') || input.grant_types.some(grant => !['authorization_code', 'refresh_token'].includes(grant)))) ||
          (input.response_types && (input.response_types.length !== 1 || input.response_types[0] !== 'code')) ||
          (input.scope !== undefined && input.scope !== scope)) throw new InvalidClientMetadataError('Unsupported OAuth grant, response type or scope')
        if (Object.keys(state.clients).length >= MAX_CLIENTS) throw new TooManyRequestsError('Client registration limit reached')
        const client = {
          client_id: input.client_id, client_id_issued_at: Math.floor(Date.now() / SECOND),
          client_name: typeof input.client_name === 'string' ? input.client_name.slice(0, 120) : 'MCP-Client',
          redirect_uris: [...new Set(input.redirect_uris)], token_endpoint_auth_method: 'none',
          grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'], scope
        }
        state.clients[client.client_id] = { client, expiresAt: Date.now() + DAY }
        save()
        return client
      }
    },
    async authorize(client, params, res) {
      prune()
      scopes(params.scopes)
      resource(params.resource)
      if (!client.redirect_uris.includes(params.redirectUri) || !redirectAllowed(params.redirectUri, extra)) throw new InvalidRequestError('Invalid redirect URI')
      if (!/^[A-Za-z0-9_-]{43}$/.test(params.codeChallenge) || (params.state !== undefined && params.state.length > 512)) throw new InvalidRequestError('Invalid PKCE challenge or state')
      if (pending.size >= MAX_PENDING) throw new TooManyRequestsError('Too many pending authorizations')
      const ticket = random()
      const cookie = random()
      const item = { clientId: client.client_id, clientName: client.client_name, redirectUri: params.redirectUri,
        state: params.state, codeChallenge: params.codeChallenge, resource: resourceUrl.href,
        cookieHash: hash(cookie), attempts: 0, expiresAt: Date.now() + PENDING_TTL }
      pending.set(hash(ticket), item)
      res.cookie(COOKIE, cookie, { secure: true, httpOnly: true, sameSite: 'strict', path: '/', maxAge: PENDING_TTL })
      res.type('html').send(consentPage(ticket, item))
    },
    async challengeForAuthorizationCode(client, raw) { return codeFor(client, raw).codeChallenge },
    async exchangeAuthorizationCode(client, raw, _verifier, redirectUri, requestedResource) {
      const code = codeFor(client, raw)
      if (redirectUri !== code.redirectUri) throw new InvalidGrantError('Authorization redirect URI does not match')
      if (resource(requestedResource) !== code.resource) throw new InvalidGrantError('Authorization resource does not match')
      codes.delete(hash(raw))
      return issue(client.client_id)
    },
    async exchangeRefreshToken(client, raw, requestedScopes, requestedResource) {
      prune()
      scopes(requestedScopes)
      resource(requestedResource)
      const token = typeof raw === 'string' ? state.tokens[hash(raw)] : undefined
      if (!token || token.kind !== 'refresh' || token.clientId !== client.client_id) throw new InvalidGrantError('Invalid or expired refresh token')
      if (token.used) { removeFamily(token.family); save(); throw new InvalidGrantError('Refresh token was already used; authorize again') }
      if (Object.keys(state.tokens).length + 2 > MAX_TOKENS) throw new TooManyRequestsError('Too many active grants')
      token.used = true
      for (const [key, member] of Object.entries(state.tokens)) if (member.family === token.family && member.kind === 'access') delete state.tokens[key]
      return issue(client.client_id, token.family)
    },
    async verifyAccessToken(raw) {
      prune()
      const token = typeof raw === 'string' && raw.length === 43 ? state.tokens[hash(raw)] : undefined
      if (!token || token.kind !== 'access' || token.used) throw new InvalidTokenError('Invalid or expired access token')
      return { token: raw, clientId: token.clientId, scopes: [scope], expiresAt: Math.floor(token.expiresAt / SECOND), resource: new URL(token.resource) }
    },
    async revokeToken(client, request) {
      prune()
      const token = state.tokens[hash(request.token)]
      if (token?.clientId === client.client_id) { removeFamily(token.family); save() }
    }
  }
  const router = express.Router()
  router.use((req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'" })
    next()
  })
  router.post('/consent', express.urlencoded({ extended: false, limit: '8kb', parameterLimit: 5 }), (req, res) => {
    prune()
    const reject = (status, message) => res.status(status).type('text').send(message)
    if (req.get('origin') !== origin) return reject(403, 'Ungültiger Ursprung. Bitte die Verbindung erneut starten.')
    if (Date.now() - consentWindow.start >= 15 * 60 * SECOND) consentWindow = { start: Date.now(), count: 0 }
    if (++consentWindow.count > 15) return reject(429, 'Zu viele Versuche. Bitte später erneut versuchen.')
    const { ticket, ownerKey, decision } = req.body || {}
    const item = typeof ticket === 'string' ? pending.get(hash(ticket)) : undefined
    const cookies = (req.get('cookie') || '').split(';').map(part => part.trim()).filter(part => part.startsWith(`${COOKIE}=`))
    const cookie = cookies.length === 1 ? cookies[0].slice(COOKIE.length + 1) : undefined
    if (!item || !sameHash(cookie, item.cookieHash) || !['allow', 'deny'].includes(decision)) return reject(403, 'Ungültige oder abgelaufene Anmeldung. Bitte die Verbindung erneut starten.')
    if (decision === 'allow' && (typeof ownerKey !== 'string' || ownerKey.length > 512 || !sameHash(ownerKey, ownerKeyHash))) {
      if (++item.attempts >= 3) pending.delete(hash(ticket))
      return reject(403, 'Anmeldeschlüssel ungültig. Bitte die Verbindung erneut starten.')
    }
    pending.delete(hash(ticket))
    res.clearCookie(COOKIE, { secure: true, httpOnly: true, sameSite: 'strict', path: '/' })
    const redirect = new URL(item.redirectUri)
    if (item.state !== undefined) redirect.searchParams.set('state', item.state)
    if (decision === 'deny') redirect.searchParams.set('error', 'access_denied')
    else {
      if (codes.size >= MAX_PENDING || !state.clients[item.clientId]) return reject(429, 'Bitte die Verbindung später erneut starten.')
      const code = random()
      codes.set(hash(code), { ...item, expiresAt: Date.now() + CODE_TTL })
      redirect.searchParams.set('code', code)
    }
    return res.redirect(302, redirect.href)
  })
  const options = { provider, issuerUrl: new URL(origin), resourceServerUrl: resourceUrl, scopesSupported: [scope], resourceName: 'Trio MCP' }
  // The SDK advertises confidential clients by default; this server supports public PKCE clients only.
  router.get('/.well-known/oauth-authorization-server', (_req, res) => res.json({ ...createOAuthMetadata(options),
    token_endpoint_auth_methods_supported: ['none'], revocation_endpoint_auth_methods_supported: ['none'] }))
  router.use('/register', express.json({ limit: '8kb' }), (req, _res, next) => {
    if (req.body && req.body.token_endpoint_auth_method === undefined) req.body.token_endpoint_auth_method = 'none'
    next()
  })
  router.use(mcpAuthRouter(options))
  return { router, provider, resourceUrl, scope }
}

function consentPage(ticket, item) {
  return `<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Trio verbinden</title><main><h1>Trio mit einem KI-Client verbinden</h1><p>Client: ${escape(item.clientName)}</p><p>Weiterleitung nach der Freigabe: <code>${escape(item.redirectUri)}</code></p><p>Der Client darf synchronisierte Trio-Daten lesen und Änderungen vorschlagen. Änderungen müssen weiterhin lokal in Trio bestätigt werden.</p><form method="post" action="/consent"><input type="hidden" name="ticket" value="${escape(ticket)}"><label>Privater Anmeldeschlüssel <input type="password" name="ownerKey" autocomplete="current-password" required maxlength="512"></label><p><button name="decision" value="allow">Anmelden und Verbindung erlauben</button> <button name="decision" value="deny" formnovalidate>Abbrechen</button></p></form></main></html>`
}
