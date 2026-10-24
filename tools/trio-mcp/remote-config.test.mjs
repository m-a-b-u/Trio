import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { loadRemoteConfig, remoteInfo, setupRemote } from './remote-config.mjs'

test('remote setup stores a private independent key, preserves it, and isolates issuer grants', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'trio-remote-config-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const info = setupRemote(dir, 'https://trio.example/')
  const before = loadRemoteConfig(dir)
  const key = fs.readFileSync(info.ownerKeyFile, 'utf8').trim()
  assert.equal(key.length, 43)
  assert.equal(before.ownerKeyHash, createHash('sha256').update(key).digest('hex'))
  assert.equal(info.mcpUrl, 'https://trio.example/mcp')
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700)
  for (const file of [info.ownerKeyFile, info.configFile]) assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.ok(!JSON.stringify(remoteInfo(before)).includes(key))
  assert.ok(!JSON.stringify(remoteInfo(before)).includes(before.ownerKeyHash))
  setupRemote(dir, 'https://new.example')
  const after = loadRemoteConfig(dir)
  assert.equal(before.ownerKeyHash, after.ownerKeyHash)
  assert.notEqual(before.stateFile, after.stateFile)
  for (const url of ['http://localhost', 'https://u:p@example.com', 'https://example.com/path', 'https://example.com?x=1']) {
    assert.throws(() => setupRemote(dir, url))
  }
  assert.equal(loadRemoteConfig(dir).publicUrl, 'https://new.example')
  fs.writeFileSync(info.ownerKeyFile, 'damaged')
  assert.throws(() => loadRemoteConfig(dir), /Anmeldeschlüssel/)
  assert.throws(() => setupRemote(dir, 'https://trio.example'), /Anmeldeschlüssel/)
})

test('remote CLI starts separately from the relay and exposes only authenticated MCP', { timeout: 10_000 }, async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'trio-remote-cli-'))
  const probe = net.createServer().listen(0, '127.0.0.1')
  await once(probe, 'listening')
  const port = probe.address().port
  await new Promise(resolve => probe.close(resolve))
  const info = setupRemote(dir, 'https://synthetic-cli.example')
  fs.writeFileSync(info.configFile, JSON.stringify({ publicUrl: 'https://synthetic-cli.example', port }))
  const child = spawn(process.execPath, [fileURLToPath(new URL('./trio-mcp.mjs', import.meta.url)), 'remote'], {
    env: { ...process.env, TRIO_MCP_DIR: dir }, stdio: 'ignore'
  })
  const stopped = once(child, 'exit')
  t.after(async () => {
    child.kill('SIGTERM')
    await stopped
    fs.rmSync(dir, { recursive: true, force: true })
  })
  const base = `http://127.0.0.1:${port}`
  let response
  for (let attempt = 0; attempt < 100; attempt++) {
    try { response = await fetch(base + '/health'); break } catch {}
    assert.equal(child.exitCode, null)
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  assert.equal(response?.status, 200)
  assert.deepEqual(await response.json(), { ok: true, service: 'trio-mcp-remote' })
  assert.equal((await fetch(base + '/mcp')).status, 401)
  assert.equal((await fetch(base + '/trio/proposals')).status, 404)
})
