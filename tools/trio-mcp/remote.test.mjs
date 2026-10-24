import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { createMcpServer } from './mcp-server.mjs'
import { createRemoteApp } from './remote.mjs'

const publicUrl = 'https://synthetic-trio.example'
const resource = `${publicUrl}/mcp`
const ownerKey = 'synthetic-owner-secret-for-remote-tests-only'
const ownerKeyHash = createHash('sha256').update(ownerKey).digest('hex')
const redirectUri = 'https://claude.ai/api/mcp/auth_callback'
const rpcHeaders = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }
const listRequest = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })

async function fixture(t, createServer = () => createMcpServer(async () => ({ state: null }))) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-remote-test-'))
  const app = createRemoteApp({ publicUrl, ownerKeyHash, stateFile: path.join(dir, 'oauth.json'), createServer })
  const listener = app.listen(0, '127.0.0.1')
  await once(listener, 'listening')
  const baseUrl = `http://127.0.0.1:${listener.address().port}`
  t.after(async () => {
    listener.closeAllConnections()
    await new Promise(resolve => listener.close(resolve))
    await fs.rm(dir, { recursive: true, force: true })
  })
  return { baseUrl, request: (route, options = {}) => fetch(`${baseUrl}${route}`, { redirect: 'manual', ...options }) }
}

async function authorize(request) {
  const registered = await request('/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
    redirect_uris: [redirectUri], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code']
  }) })
  assert.equal(registered.status, 201)
  const { client_id } = await registered.json()
  const verifier = 'synthetic-pkce-verifier-with-at-least-forty-three-characters'
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const query = new URLSearchParams({ response_type: 'code', client_id, redirect_uri: redirectUri, code_challenge: challenge, code_challenge_method: 'S256', scope: 'trio', resource })
  const consent = await request(`/authorize?${query}`)
  assert.equal(consent.status, 200)
  const ticket = (await consent.text()).match(/name="ticket" value="([^"]+)"/)?.[1]
  assert.ok(ticket)
  const accepted = await request('/consent', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Origin: publicUrl, Cookie: consent.headers.get('set-cookie').split(';')[0] },
    body: new URLSearchParams({ ticket, ownerKey, decision: 'allow' })
  })
  assert.equal(accepted.status, 302)
  const code = new URL(accepted.headers.get('location')).searchParams.get('code')
  assert.ok(code)
  const exchanged = await request('/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({
    grant_type: 'authorization_code', client_id, code, code_verifier: verifier, redirect_uri: redirectUri, resource
  }) })
  assert.equal(exchanged.status, 200)
  const tokens = await exchanged.json()
  assert.equal(tokens.token_type.toLowerCase(), 'bearer')
  return tokens.access_token
}

test('remote MCP rejects public URLs that are not HTTPS origins', () => {
  for (const invalid of ['http://example.com', 'https://user:secret@example.com', 'https://example.com/path', 'https://example.com?x', 'https://example.com#x', 'https://example.com?', 'https://example.com/#', 'https://example.com:0', 'https://example.com:999999999999999999', 'https://example.com\\path', ' https://example.com']) {
    assert.throws(() => createRemoteApp({ publicUrl: invalid }), /valid HTTPS origin/)
  }
})

test('remote MCP exposes discovery and constant health, validates Host/Origin, and has no relay routes', async t => {
  const { request, baseUrl } = await fixture(t)
  const withHost = (host, origin) => new Promise((resolve, reject) => {
    const req = http.get(`${baseUrl}/health`, { headers: { Host: host, ...(origin ? { Origin: origin } : {}) } }, res => {
      res.resume()
      res.on('end', () => resolve(res.statusCode))
    })
    req.on('error', reject)
  })
  const health = await request('/health')
  assert.deepEqual(await health.json(), { ok: true, service: 'trio-mcp-remote' })
  assert.equal(health.headers.get('x-powered-by'), null)
  const metadata = await request('/.well-known/oauth-protected-resource/mcp')
  assert.equal(metadata.status, 200)
  const info = await metadata.json()
  assert.equal(info.resource, resource)
  assert.deepEqual(info.scopes_supported, ['trio'])
  assert.equal((await request('/.well-known/oauth-authorization-server')).status, 200)
  const denied = await request('/mcp', { method: 'POST', headers: rpcHeaders, body: listRequest })
  assert.equal(denied.status, 401)
  assert.ok(denied.headers.get('www-authenticate').includes(`${publicUrl}/.well-known/oauth-protected-resource/mcp`))
  assert.equal((await request('/mcp', { method: 'POST', headers: { ...rpcHeaders, Authorization: 'Bearer synthetic-invalid' }, body: listRequest })).status, 401)
  assert.equal(await withHost('attacker.example'), 403)
  assert.equal((await request('/health', { headers: { Origin: 'https://attacker.example' } })).status, 403)
  assert.equal((await request('/health', { headers: { Origin: 'null' } })).status, 403)
  assert.equal(await withHost(new URL(publicUrl).host, publicUrl), 200)
  for (const route of ['/api/state', '/api/health', '/api/proposals', '/trio/state', '/trio/history', '/app']) {
    assert.equal((await request(route)).status, 404, route)
  }
})

test('SDK Streamable HTTP client uses shared tools through OAuth and closes each stateless server', async t => {
  const calls = []
  let created = 0
  let closed = 0
  const { request, baseUrl } = await fixture(t, async () => {
    const server = await createMcpServer(async route => {
      calls.push(route)
      assert.equal(route, '/api/state')
      return { stateReceivedAt: new Date().toISOString(), state: { app: 'Trio', version: 'synthetic', build: '0', units: 'mg/dL', status: { glucose: 120 } } }
    })
    created++
    const close = server.close.bind(server)
    server.close = async () => { closed++; await close() }
    return server
  })
  const accessToken = await authorize(request)
  const transport = new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp`), { requestInit: { headers: { Authorization: `Bearer ${accessToken}` } } })
  const client = new Client({ name: 'synthetic-remote-client', version: '1.0.0' })
  t.after(() => client.close())
  await client.connect(transport)
  assert.match(client.getInstructions(), /current chat/)
  assert.equal(transport.sessionId, undefined)
  const tools = (await client.listTools()).tools
  assert.equal(tools.length, 11)
  assert.equal(tools.find(tool => tool.name === 'trio_get_status').annotations.readOnlyHint, true)
  const result = await client.callTool({ name: 'trio_get_status', arguments: {} })
  assert.equal(result.isError, undefined)
  assert.equal(JSON.parse(result.content[0].text).status.glucose, 120)
  assert.deepEqual(calls, ['/api/state'])
  await new Promise(resolve => setImmediate(resolve))
  assert.ok(created >= 3)
  assert.equal(closed, created)
  for (const method of ['GET', 'DELETE']) {
    const response = await request('/mcp', { method, headers: { Authorization: `Bearer ${accessToken}` } })
    assert.equal(response.status, 405)
    assert.equal(response.headers.get('allow'), 'POST')
  }
})

test('authenticated remote MCP bounds bodies and keeps parser/internal failures generic', async t => {
  let factories = 0
  const { request } = await fixture(t, () => { factories++; throw new Error('synthetic-private-error-not-for-client') })
  const accessToken = await authorize(request)
  const headers = { ...rpcHeaders, Authorization: `Bearer ${accessToken}` }
  const oversized = await request('/mcp', { method: 'POST', headers, body: JSON.stringify({ data: 'x'.repeat(256 * 1024) }) })
  assert.equal(oversized.status, 413)
  assert.deepEqual(await oversized.json(), { error: 'Request too large' })
  const malformed = await request('/mcp', { method: 'POST', headers, body: '{"synthetic-secret"' })
  assert.equal(malformed.status, 400)
  assert.deepEqual(await malformed.json(), { error: 'Invalid request body' })
  const batch = await request('/mcp', { method: 'POST', headers, body: `[${listRequest},${listRequest}]` })
  assert.equal(batch.status, 400)
  assert.deepEqual(await batch.json(), { error: 'Single MCP message required' })
  assert.equal(factories, 0)
  const failure = await request('/mcp', { method: 'POST', headers, body: listRequest })
  assert.equal(failure.status, 500)
  assert.deepEqual(await failure.json(), { jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null })
  assert.equal(factories, 1)
})

test('proxy IP headers neither alter limits nor cause OAuth limiter warnings', async t => {
  const { request } = await fixture(t)
  const errors = t.mock.method(console, 'error', () => {})
  const forwarded = (route, options = {}) => request(route, { ...options, headers: {
    ...options.headers, 'X-Forwarded-For': '203.0.113.7', Forwarded: 'for=203.0.113.7;proto=https'
  } })
  await authorize(forwarded)
  for (let attempt = 0; attempt <= 120; attempt++) {
    const response = await request('/mcp', { method: 'POST', headers: {
      ...rpcHeaders, 'X-Forwarded-For': `203.0.113.${attempt + 1}`, Forwarded: `for=203.0.113.${attempt + 1}`
    }, body: listRequest })
    assert.equal(response.status, attempt < 120 ? 401 : 429)
    await response.arrayBuffer()
  }
  assert.equal((await request('/.well-known/oauth-protected-resource/mcp')).status, 200)
  assert.equal(errors.mock.calls.length, 0)
})

test('remote MCP bounds concurrent requests and releases capacity after completion', { timeout: 5000 }, async t => {
  let release
  const gate = new Promise(resolve => { release = resolve })
  let reachedLimit
  const ready = new Promise(resolve => { reachedLimit = resolve })
  let started = 0
  const { request } = await fixture(t, async () => {
    started++
    if (started === 8) reachedLimit()
    await gate
    return createMcpServer(async () => ({ state: null }))
  })
  t.after(() => release())
  const accessToken = await authorize(request)
  const options = { method: 'POST', headers: { ...rpcHeaders, Authorization: `Bearer ${accessToken}` }, body: listRequest }
  const pending = Array.from({ length: 8 }, () => request('/mcp', options))
  await ready
  assert.equal((await request('/mcp', options)).status, 503)
  assert.equal(started, 8)
  release()
  for (const response of await Promise.all(pending)) {
    assert.equal(response.status, 200)
    await response.arrayBuffer()
  }
  assert.equal((await request('/mcp', options)).status, 200)
  assert.equal(started, 9)
})
