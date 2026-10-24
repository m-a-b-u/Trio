import express from 'express'
import { rateLimit } from 'express-rate-limit'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js'
import { getOAuthProtectedResourceMetadataUrl } from '@modelcontextprotocol/sdk/server/auth/router.js'
import { createRemoteAuth } from './remote-auth.mjs'

function publicOrigin(value) {
  try {
    if (typeof value !== 'string' || value.length > 2048 || !/^https:\/\/[^/?#]+\/?$/i.test(value) || /[^\x21-\x7e]|\\/.test(value)) throw new Error()
    const url = new URL(value)
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.port === '0') throw new Error()
    return url.origin
  } catch {
    throw new Error('Remote MCP requires a valid HTTPS origin without credentials, path, query or fragment.')
  }
}

export function createRemoteApp({ publicUrl, ownerKeyHash, stateFile, createServer, allowedRedirects }) {
  const origin = publicOrigin(publicUrl)
  const publicHost = new URL(origin).host
  const { router, provider, resourceUrl, scope } = createRemoteAuth({ publicUrl: origin, ownerKeyHash, stateFile, allowedRedirects })
  const app = express()
  app.disable('x-powered-by')
  app.set('trust proxy', false)
  app.use((req, res, next) => {
    // OAuth limits deliberately use the loopback peer, never caller-supplied IPs.
    delete req.headers['x-forwarded-for']
    delete req.headers.forwarded
    res.set('Cache-Control', 'no-store')
    res.set('X-Content-Type-Options', 'nosniff')
    const host = req.headers.host?.toLowerCase()
    if (host !== publicHost && host !== `127.0.0.1:${req.socket.localPort}`) return res.status(403).json({ error: 'Host not allowed' })
    if (req.headers.origin !== undefined && req.headers.origin !== origin) return res.status(403).json({ error: 'Origin not allowed' })
    next()
  })
  app.get('/health', (req, res) => res.json({ ok: true, service: 'trio-mcp-remote' }))
  app.use(router)
  app.use('/mcp', rateLimit({
    windowMs: 60_000, limit: 120, standardHeaders: 'draft-8', legacyHeaders: false,
    // One owner behind a loopback reverse proxy; do not trust forwarded client IPs.
    keyGenerator: () => 'trio-mcp', message: { error: 'Too many requests' }
  }), requireBearerAuth({
    verifier: provider, requiredScopes: [scope], expectedResource: resourceUrl,
    resourceMetadataUrl: getOAuthProtectedResourceMetadataUrl(new URL(resourceUrl))
  }))
  let activeRequests = 0
  app.post('/mcp', (req, res, next) => {
    if (activeRequests >= 8) return res.status(503).json({ error: 'MCP busy; retry later' })
    activeRequests++
    res.once('close', () => { activeRequests-- })
    if (!req.is('application/json')) return res.status(415).json({ error: 'JSON body required' })
    next()
  }, express.json({ limit: '256kb', inflate: false }), async (req, res) => {
    if (Array.isArray(req.body)) return res.status(400).json({ error: 'Single MCP message required' })
    let server
    let transport
    let closed = false
    const cleanup = async () => {
      if (closed) return
      closed = true
      await Promise.allSettled([transport?.close(), server?.close()])
    }
    res.once('close', () => { void cleanup() })
    try {
      server = await createServer()
      if (closed) { await server.close(); return }
      transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true })
      await server.connect(transport)
      if (closed) { await cleanup(); return }
      await transport.handleRequest(req, res, req.body)
    } catch {
      if (!res.headersSent && !res.destroyed) res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null })
      await cleanup()
    }
  })
  app.all('/mcp', (req, res) => res.set('Allow', 'POST').status(405).json({ error: 'Method not allowed' }))
  app.use((req, res) => res.status(404).json({ error: 'Not found' }))
  app.use((error, req, res, next) => {
    if (res.headersSent) { res.destroy(); return }
    const status = error.type === 'entity.too.large' ? 413 : error.status === 415 ? 415 : error.status === 400 ? 400 : 500
    res.status(status).json({ error: status === 413 ? 'Request too large' : status === 500 ? 'Internal server error' : 'Invalid request body' })
  })
  return app
}
