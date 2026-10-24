import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { setupRemote } from './remote-config.mjs'
import { parseTunnelURL, runTestTunnel } from './remote-test-tunnel.mjs'

const origin = 'https://synthetic-remote-test.trycloudflare.com'

async function fixture(t, { tunnelExits = false, badURL = false, earlyRemoteExit = false } = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-tunnel-test-'))
  const held = net.createServer(socket => socket.destroy())
  await new Promise(resolve => held.listen(0, '127.0.0.1', resolve))
  const port = held.address().port
  await new Promise(resolve => held.close(resolve))
  setupRemote(directory, 'https://previous-synthetic.example')
  await fs.writeFile(path.join(directory, 'remote.json'), JSON.stringify({ publicUrl: 'https://previous-synthetic.example', port }))
  const binary = path.join(directory, 'cloudflared-fixture.mjs')
  const script = path.join(directory, 'remote-fixture.mjs')
  await fs.writeFile(binary, `#!${process.execPath}
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const directory = path.dirname(fileURLToPath(import.meta.url))
fs.writeFileSync(path.join(directory, 'tunnel-args.json'), JSON.stringify(process.argv.slice(2)))
console.log('synthetic-private-tunnel-log')
process.on('SIGTERM', () => { fs.writeFileSync(path.join(directory, 'tunnel-stopped'), 'yes'); process.exit(0) })
process.stderr.write('| ${badURL ? 'https://wrong.trycloudflare.com.evil.example' : origin.slice(0, 20)}')
setTimeout(() => process.stderr.write('${badURL ? '' : origin.slice(20)} |\\n'), 5)
${badURL ? 'setTimeout(() => process.exit(3), 60)' : tunnelExits ? "const timer = setInterval(() => { if (fs.existsSync(path.join(directory, 'remote-ready'))) { clearInterval(timer); setTimeout(() => process.exit(4), 300) } }, 10)" : 'setInterval(() => {}, 1000)'}
`, { mode: 0o700 })
  await fs.writeFile(script, `
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
const directory = process.env.TRIO_MCP_DIR
const { port, publicUrl } = JSON.parse(fs.readFileSync(path.join(directory, 'remote.json')))
fs.writeFileSync(path.join(directory, 'remote-started'), JSON.stringify(process.argv.slice(2)))
console.log('synthetic-private-remote-log')
${earlyRemoteExit ? 'process.exit(5)' : ''}
process.on('SIGTERM', () => { fs.writeFileSync(path.join(directory, 'remote-stopped'), 'yes'); process.exit(0) })
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json')
  if (req.url === '/health') res.end(JSON.stringify({ ok: true, service: 'trio-mcp-remote' }))
  else if (req.url === '/mcp') { res.statusCode = 401; res.setHeader('WWW-Authenticate', 'Bearer resource_metadata="' + publicUrl + '/.well-known/oauth-protected-resource/mcp"'); res.end('{}') }
  else if (req.url === '/.well-known/oauth-protected-resource/mcp') res.end(JSON.stringify({ resource: publicUrl + '/mcp', scopes_supported: ['trio'] }))
  else { res.statusCode = 404; res.end('{}') }
})
server.listen(port, '127.0.0.1', () => {
  fs.writeFileSync(path.join(directory, 'remote-ready'), 'yes')
  ${tunnelExits ? '' : 'setTimeout(() => process.exit(7), 300)'}
})
`)
  const logs = t.mock.method(console, 'log', () => {})
  const errors = t.mock.method(console, 'error', () => {})
  t.after(() => fs.rm(directory, { recursive: true, force: true }))
  return { binary, directory, script, port, logs, errors }
}

test('Quick Tunnel parser accepts only an exact HTTPS trycloudflare origin', () => {
  assert.equal(parseTunnelURL(`info | ${origin} |`), origin)
  for (const invalid of [
    'http://a.trycloudflare.com', 'https://trycloudflare.com', 'https://a.trycloudflare.com.evil.test',
    'https://user@a.trycloudflare.com', 'https://a.trycloudflare.com:443', 'https://a.trycloudflare.com:8443', 'https://a.trycloudflare.com/path',
    'https://a.trycloudflare.com?query', 'https://a.trycloudflare.com#fragment', 'https://a.b.trycloudflare.com'
  ]) assert.equal(parseTunnelURL(invalid), undefined, invalid)
})

test('supervisor configures the printed issuer, checks readiness and stops tunnel when remote exits', { timeout: 5000 }, async t => {
  const f = await fixture(t)
  assert.equal(await runTestTunnel(f), 1)
  assert.deepEqual(f.logs.mock.calls.map(call => call.arguments), [[`Remote MCP test ready: ${origin}/mcp`]])
  assert.equal(await fs.readFile(path.join(f.directory, 'tunnel-stopped'), 'utf8'), 'yes')
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(f.directory, 'remote-started'), 'utf8')), ['remote'])
  const args = JSON.parse(await fs.readFile(path.join(f.directory, 'tunnel-args.json'), 'utf8'))
  assert.deepEqual(args, ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${f.port}`, '--metrics', '127.0.0.1:0', '--management-diagnostics=false', '--grace-period', '1s', '--loglevel', 'info'])
  assert.equal(JSON.parse(await fs.readFile(path.join(f.directory, 'remote.json'), 'utf8')).publicUrl, origin)
  assert.ok(f.errors.mock.calls.every(call => !String(call.arguments).includes('synthetic-private')))
})

test('supervisor stops the remote process when its tunnel exits', { timeout: 5000 }, async t => {
  const f = await fixture(t, { tunnelExits: true })
  assert.equal(await runTestTunnel(f), 1)
  assert.equal(await fs.readFile(path.join(f.directory, 'remote-stopped'), 'utf8'), 'yes')
  assert.equal(f.logs.mock.calls.length, 1)
})

test('stopping the supervisor terminates both children without restarting', { timeout: 5000 }, async t => {
  const f = await fixture(t, { tunnelExits: true })
  t.mock.method(console, 'log', () => process.emit('SIGTERM'))
  assert.equal(await runTestTunnel(f), 0)
  assert.equal(await fs.readFile(path.join(f.directory, 'tunnel-stopped'), 'utf8'), 'yes')
  assert.equal(await fs.readFile(path.join(f.directory, 'remote-stopped'), 'utf8'), 'yes')
})

test('remote startup failure stops the tunnel without advertising a ready link', { timeout: 5000 }, async t => {
  const f = await fixture(t, { earlyRemoteExit: true })
  assert.equal(await runTestTunnel(f), 1)
  assert.equal(await fs.readFile(path.join(f.directory, 'tunnel-stopped'), 'utf8'), 'yes')
  assert.equal(f.logs.mock.calls.length, 0)
})

test('occupied loopback port prevents starting or exposing a tunnel', { timeout: 5000 }, async t => {
  const f = await fixture(t)
  const occupied = net.createServer(socket => socket.destroy())
  await new Promise(resolve => occupied.listen(f.port, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => occupied.close(resolve)))
  assert.equal(await runTestTunnel(f), 1)
  await assert.rejects(fs.stat(path.join(f.directory, 'tunnel-args.json')), { code: 'ENOENT' })
  assert.equal(JSON.parse(await fs.readFile(path.join(f.directory, 'remote.json'), 'utf8')).publicUrl, 'https://previous-synthetic.example')
  assert.equal(f.logs.mock.calls.length, 0)
})

test('lookalike tunnel URLs never configure an issuer or start the remote process', { timeout: 5000 }, async t => {
  const f = await fixture(t, { badURL: true })
  assert.equal(await runTestTunnel(f), 1)
  await assert.rejects(fs.stat(path.join(f.directory, 'remote-started')), { code: 'ENOENT' })
  assert.equal(JSON.parse(await fs.readFile(path.join(f.directory, 'remote.json'), 'utf8')).publicUrl, 'https://previous-synthetic.example')
  assert.equal(f.logs.mock.calls.length, 0)
})
