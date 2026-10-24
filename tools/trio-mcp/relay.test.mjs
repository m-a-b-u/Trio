import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const script = fileURLToPath(new URL('./trio-mcp.mjs', import.meta.url))
const token = 'synthetic-test-token'
const state = () => ({
  version: 'synthetic-v1', units: 'mg/dL', settings: { enabled: true },
  preferences: { maxIOB: 2 },
  basalProfile: [{ start: '00:00:00', minutes: 0, rate: 1 }],
  bgTargets: { targets: [{ start: '00:00:00', offset: 0, low: 100, high: 110 }] }
})

async function listen(server) {
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  return server.address().port
}

async function fixture(t, response, { scheduled = false } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-relay-test-'))
  const mock = http.createServer(response || ((req, res) => {
    res.writeHead(500); res.end('{}')
  }))
  const mockPort = await listen(mock)
  const reserve = http.createServer()
  const relayPort = await listen(reserve)
  await new Promise(resolve => reserve.close(resolve))
  await fs.writeFile(path.join(dir, 'config.json'), JSON.stringify({
    token, port: relayPort, anthropicApiKey: 'synthetic-key', analysisTime: scheduled ? '00:00' : '23:59', model: 'synthetic-model'
  }))
  const env = { ...process.env, TRIO_MCP_DIR: dir, TRIO_MCP_ANTHROPIC_URL: `http://127.0.0.1:${mockPort}` }
  const args = scheduled ? ['--import', 'data:text/javascript,const original = globalThis.setInterval; globalThis.setInterval = fn => original(fn, 20)', script, 'serve'] : [script, 'serve']
  const child = spawn(process.execPath, args, {
    env,
    stdio: ['ignore', 'pipe', 'pipe']
  })
  t.after(async () => {
    const stopped = child.exitCode === null ? once(child, 'exit') : null
    if (stopped) { child.kill(); await stopped }
    mock.closeAllConnections()
    await new Promise(resolve => mock.close(resolve))
    await fs.rm(dir, { recursive: true, force: true })
  })
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('relay startup timed out')), 5000)
    child.once('exit', code => { clearTimeout(timeout); reject(new Error(`relay exited ${code}`)) })
    child.stderr.on('data', data => {
      if (String(data).includes('relay listening')) { clearTimeout(timeout); resolve() }
    })
  })
  async function request(route, body, authorized = true) {
    const res = await fetch(`http://127.0.0.1:${relayPort}${route}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', ...(authorized ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body)
    })
    return { status: res.status, body: await res.json() }
  }
  return { dir, request, relayPort, env }
}

function analysisResponse(res, proposals = []) {
  res.setHeader('Content-Type', 'application/json')
  res.end(JSON.stringify({ model: 'synthetic-model', content: [{
    type: 'tool_use', name: 'submit_analysis', input: { summary: 'Synthetic report', findings: [], proposals }
  }] }))
}

async function uploadSyntheticDays(request, offsets = [0, 1, 2, 3, 4, 5, 6, 7]) {
  const now = Date.now() - 60000
  const upload = await request('/trio/history', {
    glucose: offsets.map(day => ({ t: new Date(now - day * 24 * 60 * 60 * 1000).toISOString(), v: 120 }))
  })
  assert.equal(upload.status, 200)
}

const automaticProposal = () => ({
  target: 'basal_profile', schedule: [{ time: '00:00', value: 1.1 }], reason: 'Synthetic'
})

test('relay starts with isolated storage, requires auth, and merges synthetic history', async t => {
  const { request } = await fixture(t)
  assert.equal((await request('/api/state', undefined, false)).status, 401)
  assert.deepEqual((await request('/trio/state', state())).body, { ok: true, historyThrough: null })
  const reading = { t: new Date(Date.now() - 60000).toISOString(), v: 120 }
  for (let i = 0; i < 2; i++) assert.equal((await request('/trio/history', { glucose: [reading] })).body.glucose, 1)
  assert.equal((await request('/trio/state', state())).body.historyThrough, reading.t)
  assert.equal((await request('/api/stats')).body.readings, 1)
  assert.equal((await request('/api/overview')).body.state.version, 'synthetic-v1')
})

test('analysis preserves state uploads and proposal decisions received while Claude responds', async t => {
  let respond
  let started
  const called = new Promise(resolve => { started = resolve })
  const { request } = await fixture(t, (req, res) => { respond = () => analysisResponse(res); started() })
  await request('/trio/state', state())
  const proposal = (await request('/api/proposals', { target: 'preferences', patch: { maxIOB: 2.1 }, reason: 'Synthetic' })).body
  const analysis = request('/api/analyze', {})
  await called
  await request('/trio/state', { ...state(), version: 'synthetic-v2' })
  await request(`/trio/proposals/${proposal.id}/result`, { status: 'applied', message: 'Synthetic approval' })
  respond()
  assert.equal((await analysis).status, 200)
  assert.equal((await request('/api/state')).body.state.version, 'synthetic-v2')
  assert.equal((await request('/api/proposals')).body.find(p => p.id === proposal.id).status, 'applied')
})

test('daily report reflects the eventual proposal decision', async t => {
  const { request } = await fixture(t, (req, res) => analysisResponse(res, [automaticProposal()]))
  await request('/trio/state', state())
  await uploadSyntheticDays(request)
  const report = (await request('/api/analyze', {})).body
  assert.equal(report.proposals[0].status, 'pending')
  await request(`/trio/proposals/${report.proposals[0].id}/result`, { status: 'rejected', message: 'Synthetic rejection' })
  assert.equal((await request('/api/reports')).body[0].proposals[0].status, 'rejected')
})

test('schedule endpoint rejects malformed clock times and nonnumeric values', async t => {
  const { request } = await fixture(t)
  await request('/trio/state', state())
  for (const schedule of [
    [{ time: '00:00', value: 1 }, { time: '00:60', value: 1 }],
    [{ time: '00:00', value: '1.1' }]
  ]) {
    assert.equal((await request('/api/proposals', { target: 'basal_profile', schedule, reason: 'Synthetic' })).status, 400)
  }
})

test('set-time rejects values outside the clock range', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-relay-time-test-'))
  t.after(() => fs.rm(dir, { recursive: true, force: true }))
  for (const value of ['24:00', '07:60', '99:99']) {
    const result = spawnSync(process.execPath, [script, 'set-time', value], {
      env: { ...process.env, TRIO_MCP_DIR: dir }, encoding: 'utf8'
    })
    assert.notEqual(result.status, 0, `invalid time ${value} was accepted`)
  }
})

test('slow state upload preserves proposals created while its request body is arriving', async t => {
  const { request, relayPort } = await fixture(t)
  await request('/trio/state', state())
  let finish
  const uploading = new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: relayPort, path: '/trio/state', method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }
    }, res => {
      res.resume()
      res.once('end', () => resolve(res.statusCode))
    })
    req.once('error', reject)
    req.write('{"version":')
    finish = () => req.end('"slow-upload"}')
  })
  await new Promise(resolve => setTimeout(resolve, 25))
  const proposal = (await request('/api/proposals', {
    target: 'preferences', patch: { maxIOB: 2.1 }, reason: 'Synthetic concurrent proposal'
  })).body
  finish()
  assert.equal(await uploading, 200)
  assert.ok((await request('/api/proposals')).body.some(p => p.id === proposal.id))
})

test('CLI analysis shares the relay concurrency guard', async t => {
  let respond
  let started
  let calls = 0
  const called = new Promise(resolve => { started = resolve })
  const { request, env } = await fixture(t, (req, res) => {
    calls++
    if (calls === 1) { respond = () => analysisResponse(res); started() }
    else analysisResponse(res)
  })
  await request('/trio/state', state())
  const analysis = request('/api/analyze', {})
  await called
  const cli = spawn(process.execPath, [script, 'analyze'], { env, stdio: 'pipe' })
  let stderr = ''
  cli.stderr.on('data', data => { stderr += data })
  const [code] = await once(cli, 'exit')
  respond()
  await analysis
  assert.equal(code, 1)
  assert.match(stderr, /already running/i)
  assert.equal(calls, 1)
})

test('companion app authenticates its subsequent API reads using its cookie', async t => {
  const { relayPort } = await fixture(t)
  const app = await fetch(`http://127.0.0.1:${relayPort}/app?token=${token}`)
  assert.equal(app.status, 200)
  assert.match(await app.text(), /Trio Coach/)
  const cookie = app.headers.get('set-cookie')
  assert.match(cookie, /HttpOnly/)
  const overview = await fetch(`http://127.0.0.1:${relayPort}/api/overview`, { headers: { Cookie: cookie.split(';')[0] } })
  assert.equal(overview.status, 200)
})

test('scheduler performs one due analysis per day', async t => {
  let calls = 0
  let started
  const called = new Promise(resolve => { started = resolve })
  const { request } = await fixture(t, (req, res) => { calls++; analysisResponse(res); started() }, { scheduled: true })
  await request('/trio/state', state())
  await called
  await new Promise(resolve => setTimeout(resolve, 100))
  assert.equal(calls, 1)
  const reports = (await request('/api/reports')).body
  assert.equal(reports.length, 1)
  assert.equal(reports[0].trigger, 'daily')
})

test('automatic proposals are blocked with fewer than seven distinct days of readings', async t => {
  const { request } = await fixture(t, (req, res) => analysisResponse(res, [automaticProposal()]))
  await request('/trio/state', state())
  await uploadSyntheticDays(request, [0, 8])
  const report = await request('/api/analyze', {})
  assert.equal(report.status, 200)
  assert.equal(report.body.proposals[0].status, 'blocked')
  assert.equal((await request('/api/proposals?status=pending')).body.length, 0)
})

test('automatic proposals are blocked when readings span less than seven days', async t => {
  const { request } = await fixture(t, (req, res) => analysisResponse(res, [automaticProposal()]))
  await request('/trio/state', state())
  await uploadSyntheticDays(request, [0, 1, 2, 3, 4, 5, 6])
  const report = await request('/api/analyze', {})
  assert.equal(report.status, 200)
  assert.equal(report.body.proposals[0].status, 'blocked')
  assert.equal((await request('/api/proposals?status=pending')).body.length, 0)
})

test('automatic analysis creates at most two proposals per day, including repeat runs', async t => {
  const { request } = await fixture(t, (req, res) => analysisResponse(res, [
    automaticProposal(), automaticProposal(), automaticProposal()
  ]))
  await request('/trio/state', state())
  await uploadSyntheticDays(request)
  const first = await request('/api/analyze', {})
  assert.equal(first.status, 200)
  assert.equal(first.body.proposals.filter(p => p.status === 'pending').length, 2)
  assert.equal(first.body.proposals.filter(p => p.status === 'blocked').length, 1)
  const second = await request('/api/analyze', {})
  assert.equal(second.status, 200)
  assert.equal(second.body.proposals.filter(p => p.status === 'pending').length, 0)
  assert.equal((await request('/api/proposals')).body.filter(p => p.origin === 'daily-analysis').length, 2)
})
