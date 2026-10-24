import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { once } from 'node:events'
import test from 'node:test'
import express from 'express'
import { createRemoteAuth } from './remote-auth.mjs'

const origin = 'https://trio.example'
const callback = 'https://claude.ai/api/mcp/auth_callback'
const ownerKey = 'synthetic-owner-secret-not-for-real-use'
const ownerKeyHash = createHash('sha256').update(ownerKey).digest('hex')

async function fixture(t, options = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-oauth-test-'))
  const stateFile = path.join(dir, 'oauth.json')
  const config = { publicUrl: origin, ownerKeyHash, stateFile, ...options }
  let server, auth, base
  const stop = async () => {
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); server = undefined }
  }
  const start = async () => {
    auth = createRemoteAuth(config)
    const app = express()
    app.use(auth.router)
    server = app.listen(0, '127.0.0.1')
    await once(server, 'listening')
    base = `http://127.0.0.1:${server.address().port}`
  }
  t.after(async () => { await stop(); await fs.rm(dir, { recursive: true, force: true }) })
  await start()
  const request = async (route, { body, json, headers = {} } = {}) => {
    const res = await fetch(base + route, { method: body !== undefined || json !== undefined ? 'POST' : 'GET', redirect: 'manual',
      headers: { ...(json !== undefined ? { 'Content-Type': 'application/json' } : body !== undefined ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}), ...headers },
      body: json !== undefined ? JSON.stringify(json) : body !== undefined ? new URLSearchParams(body) : undefined })
    const text = await res.text()
    return { status: res.status, headers: res.headers, text, json: (() => { try { return JSON.parse(text) } catch { return undefined } })() }
  }
  return { request, stateFile, config, get auth() { return auth }, restart: async () => { await stop(); await start() } }
}

async function register(f, values = {}) {
  const result = await f.request('/register', { json: { redirect_uris: [callback], client_name: 'Synthetic client', ...values } })
  assert.equal(result.status, 201, result.text)
  return result.json
}

async function authorization(f, client, values = {}) {
  const verifier = randomBytes(32).toString('base64url')
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const params = { client_id: client.client_id, redirect_uri: client.redirect_uris[0], response_type: 'code',
    code_challenge: challenge, code_challenge_method: 'S256', state: 'synthetic-state', ...values }
  const res = await f.request('/authorize?' + new URLSearchParams(params))
  return { res, verifier, params, ticket: /name="ticket" value="([A-Za-z0-9_-]+)"/.exec(res.text)?.[1], cookie: res.headers.get('set-cookie')?.split(';')[0] }
}

async function consent(f, auth, changes = {}, headers = {}) {
  return f.request('/consent', { body: { ticket: auth.ticket, ownerKey, decision: 'allow', ...changes }, headers: { Origin: origin, Cookie: auth.cookie, ...headers } })
}

async function grant(f, client) {
  client ||= await register(f)
  const auth = await authorization(f, client)
  assert.equal(auth.res.status, 200, auth.res.text)
  const approval = await consent(f, auth)
  assert.equal(approval.status, 302, approval.text)
  const location = new URL(approval.headers.get('location'))
  assert.equal(location.searchParams.get('state'), 'synthetic-state')
  const body = { grant_type: 'authorization_code', client_id: client.client_id, redirect_uri: client.redirect_uris[0],
    code: location.searchParams.get('code'), code_verifier: auth.verifier }
  const exchanged = await f.request('/token', { body })
  assert.equal(exchanged.status, 200, exchanged.text)
  return { client, auth, body, tokens: exchanged.json }
}

test('OAuth discovery, public DCR and redirect allowlist match the implemented protocol', async t => {
  const f = await fixture(t)
  const metadata = (await f.request('/.well-known/oauth-authorization-server')).json
  assert.deepEqual(metadata.token_endpoint_auth_methods_supported, ['none'])
  assert.deepEqual(metadata.revocation_endpoint_auth_methods_supported, ['none'])
  assert.deepEqual(metadata.code_challenge_methods_supported, ['S256'])
  assert.equal(metadata.authorization_response_iss_parameter_supported, undefined)
  const prm = (await f.request('/.well-known/oauth-protected-resource/mcp')).json
  assert.equal(prm.resource, origin + '/mcp')
  assert.deepEqual(prm.scopes_supported, ['trio'])
  for (const uri of [callback, 'https://chatgpt.com/connector_platform_oauth_redirect', 'https://chatgpt.com/connector/oauth/callback_123-A']) {
    const client = await register(f, { redirect_uris: [uri] })
    assert.equal(client.token_endpoint_auth_method, 'none')
    assert.equal(client.client_secret, undefined)
  }
  for (const uri of ['http://claude.ai/api/mcp/auth_callback', callback + '#fragment', callback + '?x=1',
    'https://user@claude.ai/api/mcp/auth_callback', 'https://chatgpt.com.evil.example/connector/oauth/id',
    'https://chatgpt.com/connector/oauth/a/b', 'https://chatgpt.com/connector/oauth/%2e%2e', 'https://elsewhere.example/callback']) {
    assert.equal((await f.request('/register', { json: { redirect_uris: [uri] } })).status, 400, uri)
  }
  for (const patch of [{ token_endpoint_auth_method: 'client_secret_post' }, { grant_types: ['client_credentials'] }, { response_types: ['token'] }, { scope: 'admin' }]) {
    assert.equal((await f.request('/register', { json: { redirect_uris: [callback], ...patch } })).status, 400)
  }
})

test('consent displays escaped identity and actual callback, requires owner, cookie, origin and a live ticket', async t => {
  const f = await fixture(t)
  const client = await register(f, { client_name: '<script>untrusted</script>' })
  const auth = await authorization(f, client)
  assert.ok(auth.res.text.includes('&lt;script&gt;untrusted&lt;/script&gt;'))
  assert.ok(auth.res.text.includes(callback))
  assert.ok(!auth.res.text.includes(ownerKey))
  for (const part of ['Secure', 'HttpOnly', 'SameSite=Strict', 'Path=/']) assert.ok(auth.res.headers.get('set-cookie').includes(part))
  assert.equal(auth.res.headers.get('referrer-policy'), 'no-referrer')
  assert.ok(auth.res.headers.get('content-security-policy').includes("frame-ancestors 'none'"))
  assert.equal((await consent(f, auth, {}, { Origin: 'https://evil.example' })).status, 403)
  assert.equal((await consent(f, auth, {}, { Cookie: '' })).status, 403)
  assert.equal((await consent(f, auth, { ticket: 'unknown-ticket' })).status, 403)
  assert.equal((await consent(f, auth, { ownerKey: 'wrong' })).status, 403)
  assert.equal((await consent(f, auth)).status, 302)
  assert.equal((await consent(f, auth)).status, 403)
  const denied = await authorization(f, client)
  const result = await consent(f, denied, { decision: 'deny', ownerKey: '' })
  assert.equal(new URL(result.headers.get('location')).searchParams.get('error'), 'access_denied')
})

test('SDK enforces S256 PKCE; codes are single use and client, redirect and resource bound', async t => {
  const f = await fixture(t)
  const client = await register(f)
  const another = await register(f)
  assert.equal(new URL((await authorization(f, client, { code_challenge_method: 'plain' })).res.headers.get('location')).searchParams.get('error'), 'invalid_request')
  for (const values of [{ resource: 'https://evil.example/mcp' }, { scope: 'admin' }, { code_challenge: 'short' }]) {
    const auth = await authorization(f, client, values)
    assert.equal(auth.res.status, 302)
    assert.ok(new URL(auth.res.headers.get('location')).searchParams.has('error'))
  }
  const auth = await authorization(f, client, { resource: origin + '/mcp', scope: 'trio' })
  const approved = await consent(f, auth)
  const body = { client_id: client.client_id, grant_type: 'authorization_code',
    code: new URL(approved.headers.get('location')).searchParams.get('code'),
    redirect_uri: callback, code_verifier: auth.verifier, resource: origin + '/mcp' }
  for (const patch of [{ code_verifier: 'wrong-verifier' }, { client_id: another.client_id },
    { redirect_uri: 'https://chatgpt.com/connector_platform_oauth_redirect' }, { resource: 'https://evil.example/mcp' }]) {
    assert.equal((await f.request('/token', { body: { ...body, ...patch } })).status, 400)
  }
  const tokens = (await f.request('/token', { body })).json
  assert.equal(tokens.token_type, 'Bearer')
  assert.equal(tokens.expires_in, 3600)
  assert.equal((await f.request('/token', { body })).status, 400)
  assert.equal((await f.auth.provider.verifyAccessToken(tokens.access_token)).resource.href, origin + '/mcp')
  assert.equal(f.auth.provider.skipLocalPkceValidation, undefined)
})

test('refresh rotates, binds client/resource/scope, and replay revokes its token family', async t => {
  const f = await fixture(t)
  const { client, tokens } = await grant(f)
  const other = await register(f)
  const body = { grant_type: 'refresh_token', client_id: client.client_id, refresh_token: tokens.refresh_token }
  for (const patch of [{ client_id: other.client_id }, { resource: 'https://evil.example/mcp' }, { scope: 'admin' }]) {
    assert.equal((await f.request('/token', { body: { ...body, ...patch } })).status, 400)
  }
  const rotated = await f.request('/token', { body })
  assert.equal(rotated.status, 200)
  assert.notEqual(rotated.json.refresh_token, tokens.refresh_token)
  await assert.rejects(f.auth.provider.verifyAccessToken(tokens.access_token))
  await f.auth.provider.verifyAccessToken(rotated.json.access_token)
  assert.equal((await f.request('/token', { body })).status, 400)
  await assert.rejects(f.auth.provider.verifyAccessToken(rotated.json.access_token))
  assert.equal((await f.request('/token', { body: { ...body, refresh_token: rotated.json.refresh_token } })).status, 400)
})

test('revocation is client bound, idempotent, and removes access plus refresh tokens', async t => {
  const f = await fixture(t)
  const { client, tokens } = await grant(f)
  const other = await register(f)
  assert.equal((await f.request('/revoke', { body: { client_id: other.client_id, token: tokens.access_token } })).status, 200)
  await f.auth.provider.verifyAccessToken(tokens.access_token)
  for (let i = 0; i < 2; i++) assert.equal((await f.request('/revoke', { body: { client_id: client.client_id, token: tokens.refresh_token } })).status, 200)
  await assert.rejects(f.auth.provider.verifyAccessToken(tokens.access_token))
  assert.equal((await f.request('/token', { body: { client_id: client.client_id, grant_type: 'refresh_token', refresh_token: tokens.refresh_token } })).status, 400)
})

test('restart preserves clients and hashed token grants, but drops pending authorization codes', async t => {
  const f = await fixture(t)
  const { client, tokens } = await grant(f)
  const pending = await authorization(f, client)
  const codeApproval = await consent(f, await authorization(f, client))
  const code = new URL(codeApproval.headers.get('location')).searchParams.get('code')
  const disk = await fs.readFile(f.stateFile, 'utf8')
  for (const secret of [ownerKey, tokens.access_token, tokens.refresh_token, pending.ticket, code]) assert.ok(!disk.includes(secret))
  assert.equal((await fs.stat(f.stateFile)).mode & 0o777, 0o600)
  await f.restart()
  assert.equal((await f.auth.provider.clientsStore.getClient(client.client_id)).client_id, client.client_id)
  await f.auth.provider.verifyAccessToken(tokens.access_token)
  assert.equal((await consent(f, pending)).status, 403)
  assert.equal((await f.request('/token', { body: { client_id: client.client_id, grant_type: 'authorization_code', code, code_verifier: 'unused', redirect_uri: callback } })).status, 400)
  const refreshed = await f.request('/token', { body: { client_id: client.client_id, grant_type: 'refresh_token', refresh_token: tokens.refresh_token } })
  assert.equal(refreshed.status, 200)
  await f.restart()
  await f.auth.provider.verifyAccessToken(refreshed.json.access_token)
})

test('temporary grants and unused clients expire while confirmed client IDs survive 90 days and restart', async t => {
  let now = Date.now()
  t.mock.method(Date, 'now', () => now)
  const f = await fixture(t)
  const { client, tokens } = await grant(f)
  const unused = await register(f)
  const pending = await authorization(f, client)
  const approval = await consent(f, await authorization(f, client))
  const code = new URL(approval.headers.get('location')).searchParams.get('code')
  now += 61 * 1000
  await assert.rejects(f.auth.provider.challengeForAuthorizationCode(client, code))
  now += 5 * 60 * 1000
  assert.equal((await consent(f, pending)).status, 403)
  now += 3600 * 1000
  await assert.rejects(f.auth.provider.verifyAccessToken(tokens.access_token))
  now += 31 * 86400 * 1000
  assert.equal(await f.auth.provider.clientsStore.getClient(unused.client_id), undefined)
  assert.equal((await f.request('/token', { body: { client_id: client.client_id, grant_type: 'refresh_token', refresh_token: tokens.refresh_token } })).status, 400)
  now += 100 * 86400 * 1000
  await f.restart()
  assert.equal((await f.auth.provider.clientsStore.getClient(client.client_id)).client_id, client.client_id)
  assert.equal(JSON.parse(await fs.readFile(f.stateFile, 'utf8')).clients[client.client_id].expiresAt, null)
  await assert.rejects(f.auth.provider.verifyAccessToken(tokens.access_token))
  assert.equal((await f.request('/token', { body: { client_id: client.client_id, grant_type: 'refresh_token', refresh_token: tokens.refresh_token } })).status, 400)
  assert.equal((await authorization(f, client)).res.status, 200)
})

test('failed consent attempts are bounded per ticket and globally', async t => {
  const f = await fixture(t)
  const client = await register(f)
  const auth = await authorization(f, client)
  for (let i = 0; i < 3; i++) assert.equal((await consent(f, auth, { ownerKey: 'wrong' })).status, 403)
  assert.equal((await consent(f, auth)).status, 403)
  for (let i = 0; i < 11; i++) assert.equal((await consent(f, auth)).status, 403)
  assert.equal((await consent(f, auth)).status, 429)
})

test('registration and pending authorization stores are bounded, and expired entries free capacity', async t => {
  let now = Date.now()
  t.mock.method(Date, 'now', () => now)
  const f = await fixture(t)
  // Exercise the store cap separately from the SDK's stricter public registration rate limit.
  const store = f.auth.provider.clientsStore
  for (let i = 0; i < 100; i++) await store.registerClient({ client_id: `synthetic-${i}`, redirect_uris: [callback] })
  await assert.rejects(store.registerClient({ client_id: 'overflow', redirect_uris: [callback] }))
  const client = await store.getClient('synthetic-0')
  for (let i = 0; i < 64; i++) assert.equal((await authorization(f, client)).res.status, 200)
  const overflow = await authorization(f, client)
  assert.equal(new URL(overflow.res.headers.get('location')).searchParams.get('error'), 'too_many_requests')
  now += 6 * 60 * 1000
  assert.equal((await authorization(f, client)).res.status, 200)
  now += 2 * 86400 * 1000
  await store.registerClient({ client_id: 'after-expiry', redirect_uris: [callback] })
  assert.equal(await store.getClient(client.client_id), undefined)
})

test('explicit callback allowlist and public origin/state validation fail closed', async t => {
  const f = await fixture(t, { allowedRedirects: ['https://synthetic.example/callback'] })
  await register(f, { redirect_uris: ['https://synthetic.example/callback'] })
  for (const publicUrl of ['http://trio.example', 'https://trio.example/path', 'https://user@trio.example', origin + '?x=1', origin + '#fragment', 'https://TRIO.example']) {
    assert.throws(() => createRemoteAuth({ ...f.config, publicUrl }))
  }
  assert.throws(() => createRemoteAuth({ ...f.config, allowedRedirects: ['http://synthetic.example/callback'] }))
  assert.throws(() => createRemoteAuth({ ...f.config, ownerKeyHash: 'wrong' }))
  assert.throws(() => createRemoteAuth({ ...f.config, ownerKeyHash: '0'.repeat(64) }))
  await fs.writeFile(f.stateFile, '{}')
  assert.throws(() => createRemoteAuth(f.config))
})
