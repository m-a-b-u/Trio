import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'
import { createSetupLink, defaultSetupServer, normalizeBridgeURL, renderSetupHTML } from './setup.mjs'

const token = 'synthetic_token_12345678901234567890'
const png = Buffer.from('89504e470d0a1a0a', 'hex')

test('setup server accepts only the agreed private HTTP hosts or HTTPS', () => {
  for (const server of [
    'http://localhost:8765', 'http://Odin.local:8765/', 'http://127.0.0.1:8765', 'http://10.0.0.1',
    'http://172.16.0.1', 'http://172.31.255.254', 'http://192.168.1.20', 'http://169.254.1.20',
    'https://example.com', 'https://8.8.8.8', 'https://[2001:db8::1]:8765'
  ]) assert.ok(normalizeBridgeURL(server))
  assert.equal(normalizeBridgeURL('HTTP://Odin.local:8765/'), 'http://odin.local:8765')
  assert.equal(normalizeBridgeURL('https://example.com:443/'), 'https://example.com')
  for (const server of [
    'http://example.com', 'http://192.169.1.20', 'http://172.32.0.1', 'http://169.255.1.20', 'http://0.0.0.0',
    'http://[::1]', 'ftp://odin.local', 'http://user:secret@odin.local', 'http://odin.local/app',
    'http://odin.local/./', 'http://odin.local?token=secret', 'http://odin.local#fragment',
    'http://odin.local:0', 'http://odin.local:65536', 'http://odin.local:', 'http://bad-.local',
    'http://.local', 'http://odin.local.', 'http://odin.local\\@evil.example', 'http://odin.local\n',
    'https://[notipv6]', 'https://%65xample.com', 'https://ex ample.com', 'https://' + 'a'.repeat(2048)
  ]) assert.throws(() => normalizeBridgeURL(server), undefined, server)
})

test('setup rejects alternate numeric host spellings instead of normalizing them', () => {
  for (const host of ['127.1', '2130706433', '0x7f000001', '0x7f.0.0.1', '0177.0.0.1', '127.0.0.01', '192.168.1']) {
    for (const scheme of ['http', 'https']) assert.throws(() => normalizeBridgeURL(`${scheme}://${host}`))
  }
})

test('default setup address uses the Mac local hostname and validates its port', () => {
  assert.equal(defaultSetupServer(8765, 'Odin'), 'http://odin.local:8765')
  assert.equal(defaultSetupServer(8765, 'Odin.local'), 'http://odin.local:8765')
  assert.throws(() => defaultSetupServer(0, 'Odin'))
  assert.throws(() => defaultSetupServer(8765, 'invalid/name'))
})

test('private setup link contains only version, normalized server and the existing token', () => {
  const link = new URL(createSetupLink({ baseURL: 'http://Odin.local:8765/', token }))
  assert.equal(link.protocol, 'trio:')
  assert.equal(link.host, 'ai-bridge-setup')
  assert.equal(link.pathname, '')
  assert.deepEqual([...link.searchParams], [['version', '1'], ['server', 'http://odin.local:8765'], ['token', token]])
  assert.equal(link.hash, '')
  for (const invalid of ['', 'short', 'a'.repeat(513), 'a'.repeat(31) + ' ', 'a'.repeat(31) + '+']) {
    assert.throws(() => createSetupLink({ baseURL: 'http://odin.local', token: invalid }))
  }
  assert.throws(() => createSetupLink({ baseURL: 'http://odin.local', token, version: 2 }))
})

test('setup HTML escapes displayed text and contains only offline QR pixels, without links or scripts', () => {
  const html = renderSetupHTML({ server: '<script>"&\'</script>', png })
  assert.ok(html.includes('&lt;script&gt;&quot;&amp;&#39;&lt;/script&gt;'))
  assert.ok(html.includes('src="data:image/png;base64,'))
  assert.ok(html.includes('Content-Security-Policy'))
  assert.ok(html.includes('kein Einmalcode'))
  for (const forbidden of ['<script>', 'href=', 'data-text=', 'Trio://', 'token=', token]) assert.ok(!html.includes(forbidden))
  assert.throws(() => renderSetupHTML({ server: 'http://odin.local', png: Buffer.from('<svg></svg>') }))
})

test('setup CLI creates a private atomic file with an offline CoreImage QR and does not print credentials', {
  skip: process.platform !== 'darwin', timeout: 65000
}, t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'trio-setup-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const config = { token, port: 8765, model: 'synthetic', analysisTime: '23:59' }
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify(config), { mode: 0o600 })
  fs.writeFileSync(path.join(dir, 'setup.html'), 'previous setup', { mode: 0o644 })
  const script = fileURLToPath(new URL('./trio-mcp.mjs', import.meta.url))
  const result = spawnSync(process.execPath, [script, 'setup', 'http://synthetic.local:8765'], {
    env: { ...process.env, TRIO_MCP_DIR: dir }, encoding: 'utf8', timeout: 60000
  })
  assert.equal(result.status, 0, result.stderr)
  assert.ok(!result.stdout.includes(token))
  assert.ok(!result.stderr.includes(token))
  assert.ok(!result.stdout.includes('Trio://'))
  assert.equal(result.stdout.trim().split('\n').length, 2)
  const file = path.join(dir, 'setup.html')
  assert.ok(result.stdout.includes(file))
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  const html = fs.readFileSync(file, 'utf8')
  assert.ok(html.includes('http://synthetic.local:8765'))
  assert.ok(!html.includes(token))
  const encoded = /src="data:image\/png;base64,([A-Za-z0-9+/=]+)"/.exec(html)?.[1]
  assert.ok(encoded && Buffer.from(encoded, 'base64').length > 100)
  const decode = spawnSync('/usr/bin/swift', ['-e', `import Foundation
import CoreImage
struct Check: Decodable { let image: String; let expected: String }
let check = try JSONDecoder().decode(Check.self, from: FileHandle.standardInput.readDataToEndOfFile())
let image = CIImage(data: Data(base64Encoded: check.image)!)!
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let messages = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
exit(messages == [check.expected] ? 0 : 1)
`], { input: JSON.stringify({ image: encoded, expected: createSetupLink({ baseURL: 'http://synthetic.local:8765', token }) }),
    encoding: 'utf8', timeout: 60000 })
  assert.equal(decode.status, 0, 'Native QR decoder must recover the exact synthetic setup link')
  assert.equal(decode.stdout, '')
  assert.deepEqual(fs.readdirSync(dir).sort(), ['config.json', 'setup.html'])
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, 'config.json'), 'utf8')), config)
})
