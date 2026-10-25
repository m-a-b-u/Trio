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

async function fixture(t, response, { scheduled = false, configuration = {}, provider = 'anthropic' } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trio-relay-test-'))
  const mock = http.createServer(response || ((req, res) => {
    res.writeHead(500); res.end('{}')
  }))
  const mockPort = await listen(mock)
  const reserve = http.createServer()
  const relayPort = await listen(reserve)
  await new Promise(resolve => reserve.close(resolve))
  await fs.writeFile(path.join(dir, 'config.json'), JSON.stringify({
    token, port: relayPort, anthropicApiKey: 'synthetic-key', analysisTime: scheduled ? '00:00' : '23:59', model: 'synthetic-model', ...configuration
  }))
  const override = provider === 'openai' ? 'TRIO_MCP_OPENAI_URL' : provider === 'openai-compatible' ? 'TRIO_MCP_COMPATIBLE_URL' : 'TRIO_MCP_ANTHROPIC_URL'
  const env = { ...process.env, TRIO_MCP_DIR: dir, [override]: `http://127.0.0.1:${mockPort}` }
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

test('authenticated health check does not load the therapy database or history', async t => {
  const { dir, request } = await fixture(t)
  // loadDB would throw on this deliberately invalid synthetic shape.
  const invalidDB = '{"proposals":null}'
  await fs.writeFile(path.join(dir, 'db.json'), invalidDB)
  await fs.writeFile(path.join(dir, 'history.json'), 'not-json')
  assert.deepEqual(await request('/api/health'), { status: 200, body: { ok: true, service: 'trio-mcp' } })
  assert.equal((await request('/api/health', undefined, false)).status, 401)
  assert.equal(await fs.readFile(path.join(dir, 'db.json'), 'utf8'), invalidDB)
  assert.equal(await fs.readFile(path.join(dir, 'history.json'), 'utf8'), 'not-json')
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

for (const provider of ['openai', 'openai-compatible']) {
  test(`${provider} runs through the relay and reports the configured provider without keys`, async t => {
    const baseURL = 'https://synthetic.invalid/v1'
    const { request } = await fixture(t, (req, res) => {
      const result = { summary: 'Synthetic provider report', findings: [], proposals: [] }
      res.setHeader('Content-Type', 'application/json')
      res.end(JSON.stringify(provider === 'openai' ? {
        status: 'completed', output: [{ type: 'function_call', name: 'submit_analysis', arguments: JSON.stringify(result) }]
      } : { choices: [{ finish_reason: 'tool_calls', message: { tool_calls: [{ type: 'function', function: { name: 'submit_analysis', arguments: JSON.stringify(result) } }] } }] }))
    }, { provider, configuration: { provider, providers: { [provider]: { model: 'synthetic-model', apiKey: 'synthetic-provider-key', ...(provider === 'openai-compatible' ? { baseURL, apiKeyBaseURL: baseURL } : {}) } } } })
    await request('/trio/state', state())
    const report = await request('/api/analyze', {})
    assert.equal(report.status, 200)
    assert.equal(report.body.provider, provider)
    const overview = await request('/api/overview')
    assert.equal(overview.body.analysis.ready, true)
    assert.equal(overview.body.analysis.provider, provider)
    assert.ok(!JSON.stringify(overview.body).includes('synthetic-provider-key'))
  })
}

test('CLI provider settings remain isolated and endpoint changes invalidate the custom key', async t => {
  const { dir, env } = await fixture(t)
  const run = (...args) => spawnSync(process.execPath, [script, ...args], { env, encoding: 'utf8' })
  assert.equal(run('set-provider', 'openai').status, 0)
  assert.equal(run('set-model', 'synthetic-gpt').status, 0)
  let config = JSON.parse(await fs.readFile(path.join(dir, 'config.json')))
  assert.equal(config.model, 'synthetic-model')
  assert.equal(config.providers.openai.model, 'synthetic-gpt')
  assert.equal(JSON.parse(run('provider-status').stdout).hasKey, false)
  assert.equal(run('set-provider', 'openai-compatible').status, 0)
  assert.equal(run('set-base-url', 'https://first.invalid/v1').status, 0)
  config = JSON.parse(await fs.readFile(path.join(dir, 'config.json')))
  Object.assign(config.providers['openai-compatible'], { apiKey: 'synthetic-custom', apiKeyBaseURL: 'https://first.invalid/v1' })
  await fs.writeFile(path.join(dir, 'config.json'), JSON.stringify(config))
  assert.equal(run('set-base-url', 'https://second.invalid/v1').status, 0)
  config = JSON.parse(await fs.readFile(path.join(dir, 'config.json')))
  assert.equal(config.providers['openai-compatible'].apiKey, undefined)
  assert.notEqual(run('set-base-url', 'http://untrusted.invalid/v1').status, 0)
})

test('relay setting changes wait for iPhone approval and reject stale approvals', async t => {
  const { request, env } = await fixture(t)
  await request('/trio/state', { ...state(), settingsCatalog: [] })
  const catalog = (await request('/api/state')).body.state.settingsCatalog
  assert.equal(catalog.find(row => row.target === 'relay_config' && row.key === 'model').access, 'proposal')
  const proposal = (await request('/api/proposals', { target: 'relay_config', patch: { model: 'new-synthetic-model' }, reason: 'Synthetic config test' })).body
  assert.equal((await request('/api/overview')).body.analysis.model, 'synthetic-model')
  assert.equal((await request(`/trio/proposals/${proposal.id}/result`, { status: 'applied' })).status, 200)
  assert.equal((await request('/api/overview')).body.analysis.model, 'new-synthetic-model')
  assert.equal((await request(`/trio/proposals/${proposal.id}/result`, { status: 'applied' })).status, 200)
  const stale = (await request('/api/proposals', { target: 'relay_config', patch: { model: 'stale-model' }, reason: 'Synthetic stale test' })).body
  assert.equal(spawnSync(process.execPath, [script, 'set-time', '06:00'], { env }).status, 0)
  assert.equal((await request(`/trio/proposals/${stale.id}/result`, { status: 'applied' })).status, 409)
  assert.equal((await request('/api/overview')).body.analysis.model, 'new-synthetic-model')
  assert.equal((await request('/api/proposals')).body.find(p => p.id === stale.id).status, 'failed')
})

test('provider-switch proposal previews its effective saved model and endpoint', async t => {
  const { request } = await fixture(t, undefined, { configuration: { providers: { openai: { model: 'synthetic-gpt' } } } })
  await request('/trio/state', { ...state(), settingsCatalog: [] })
  const response = await request('/api/proposals', { target: 'relay_config', patch: { provider: 'openai' }, reason: 'Synthetic provider switch' })
  assert.equal(response.status, 200)
  assert.deepEqual(response.body.patch, { provider: 'openai', model: 'synthetic-gpt', baseURL: 'https://api.openai.com/v1' })
  assert.equal(response.body.oldValues.model, 'synthetic-model')
})

test('MCP exposes chat instructions and tool hints, and reads/proposes/cancels without a provider key or call', async t => {
  const { Client } = await import('@modelcontextprotocol/sdk/client/index.js')
  const { StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js')
  let providerCalls = 0
  const { request, env } = await fixture(t, (req, res) => {
    providerCalls++
    res.writeHead(500); res.end('{}')
  }, { configuration: { anthropicApiKey: '' } })
  await request('/trio/state', { ...state(), settingsCatalog: [
    { target: 'glucose_alerts', key: 'alerts', type: 'array', current: [], access: 'proposal', constraints: {} },
    { target: 'ai_meal', key: 'apiKey', type: 'string', access: 'action', reason: 'Local entry' }
  ] })
  await uploadSyntheticDays(request)
  assert.equal((await request('/api/overview')).body.analysis.ready, false)
  const transport = new StdioClientTransport({ command: process.execPath, args: [script, 'mcp'], env })
  const client = new Client({ name: 'synthetic-trio-test', version: '1.0.0' })
  await client.connect(transport)
  t.after(() => client.close())
  const instructions = client.getInstructions()
  for (const phrase of ['current chat', 'No additional AI provider API key', 'snapshot age', 'trio_get_settings_catalog', 'approve locally', 'only when the user explicitly requests']) {
    assert.ok(instructions.includes(phrase), `missing MCP instruction: ${phrase}`)
  }
  const tools = (await client.listTools()).tools
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  const proposal = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
  const expectedHints = {
    trio_get_status: readOnly, trio_get_settings: readOnly, trio_get_settings_catalog: readOnly,
    trio_propose_settings_change: proposal, trio_propose_schedule: proposal,
    trio_list_proposals: readOnly, trio_get_proposal: readOnly,
    trio_cancel_proposal: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    trio_get_history_stats: readOnly, trio_get_daily_report: readOnly,
    trio_get_history: readOnly, trio_get_data_quality: readOnly, trio_compare_periods: readOnly,
    trio_get_meals: readOnly, trio_get_meal_photo: readOnly,
    trio_run_daily_analysis: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true }
  }
  assert.equal(tools.length, 16)
  for (const tool of tools) assert.deepEqual(tool.annotations, expectedHints[tool.name], tool.name)
  assert.match(tools.find(tool => tool.name === 'trio_run_daily_analysis').description, /only when the user explicitly requests/)
  const call = async (name, args = {}) => {
    const response = await client.callTool({ name, arguments: args })
    assert.equal(response.isError, undefined, name)
    return JSON.parse(response.content[0].text)
  }
  assert.equal(typeof (await call('trio_get_status')).snapshotAgeMinutes, 'number')
  assert.deepEqual((await call('trio_get_settings', { section: 'settings' })).data, state().settings)
  assert.equal((await call('trio_get_history_stats')).readings, 8)
  assert.deepEqual(await call('trio_get_daily_report'), [])
  const mealID = '0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9'
  const jpeg = Buffer.from([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
  const meal = (revision, extra = {}) => ({
    id: mealID, createdAt: '2026-10-25T12:00:00Z', provider: 'anthropic', model: 'synthetic-model', webSearch: true,
    description: '300 g Spaghetti', revision,
    estimate: { carbs: 90, fat: 12, protein: 20, confidence: 'medium', notes: 'Synthetic', shortNote: 'Pasta', items: [{ name: 'Spaghetti', grams: 300, carbs: 90 }] },
    ...extra
  })
  assert.equal((await request('/trio/meals', { meals: [meal(1, { photo: jpeg.toString('base64') })] })).status, 200)
  assert.equal((await request('/trio/meals', { meals: [meal(2, { applied: { carbs: 85, fat: 12, protein: 20, note: 'Pasta', at: '2026-10-25T12:01:00Z' } })] })).status, 200)
  assert.equal((await request('/trio/meals', { meals: [meal(1)] })).status, 200)
  assert.equal((await request('/trio/meals', { meals: [meal(3, { photo: Buffer.from('not a jpeg').toString('base64') })] })).status, 400)
  const listed = await call('trio_get_meals', {})
  assert.equal(listed.total, 1)
  assert.equal(listed.nextOffset, null)
  assert.equal(listed.meals[0].revision, 2)
  assert.equal(listed.meals[0].applied.carbs, 85)
  assert.equal(listed.meals[0].hasPhoto, true)
  assert.equal(listed.meals[0].photo, undefined)
  assert.equal((await call('trio_get_meals', { from: '2026-10-26T00:00:00Z' })).total, 0)
  const photo = await client.callTool({ name: 'trio_get_meal_photo', arguments: { id: mealID.toLowerCase() } })
  assert.equal(photo.isError, undefined)
  assert.equal(photo.content[0].type, 'image')
  assert.equal(photo.content[0].mimeType, 'image/jpeg')
  assert.deepEqual(Buffer.from(photo.content[0].data, 'base64'), jpeg)
  assert.equal((await client.callTool({ name: 'trio_get_meal_photo', arguments: { id: '../meals.json' } })).isError, true)
  const catalog = await client.callTool({ name: 'trio_get_settings_catalog', arguments: {} })
  assert.equal(catalog.isError, undefined)
  assert.ok(JSON.parse(catalog.content[0].text).catalog.some(row => row.target === 'relay_config'))
  const result = await client.callTool({ name: 'trio_propose_settings_change', arguments: {
    target: 'glucose_alerts', changes: { alerts: [{ name: 'Synthetic', enabled: true }] }, reason: 'Synthetic nested proposal'
  } })
  assert.equal(result.isError, undefined)
  const created = JSON.parse(result.content[0].text).proposal
  assert.deepEqual(created.patch.alerts, [{ name: 'Synthetic', enabled: true }])
  assert.equal((await call('trio_list_proposals', { status: 'pending' }))[0].id, created.id)
  assert.equal((await call('trio_get_proposal', { id: created.id })).status, 'pending')
  for (const id of [`../../trio/proposals/${created.id}/claim?x=`, `${created.id}?x=`, `%2e%2e%2f${created.id}`]) {
    const response = await client.callTool({ name: 'trio_cancel_proposal', arguments: { id } })
    assert.equal(response.isError, true)
  }
  assert.equal((await call('trio_get_proposal', { id: created.id })).status, 'pending')
  await call('trio_cancel_proposal', { id: created.id })
  assert.equal((await call('trio_get_proposal', { id: created.id })).status, 'cancelled')
  assert.deepEqual(await call('trio_list_proposals', { status: 'pending' }), [])
  const denied = await client.callTool({ name: 'trio_propose_settings_change', arguments: {
    target: 'ai_meal', changes: { apiKey: 'not-a-secret' }, reason: 'Synthetic rejected action'
  } })
  assert.equal(denied.isError, true)
  assert.deepEqual((await request('/api/state')).body.state.settings, state().settings)
  assert.deepEqual((await request('/api/reports')).body, [])
  assert.equal(providerCalls, 0)
})

test('iPhone approval reservation excludes concurrent cancellation and duplicate application', async t => {
  const { request } = await fixture(t)
  await request('/trio/state', state())
  const proposal = (await request('/api/proposals', { target: 'preferences', patch: { maxIOB: 2.1 }, reason: 'Synthetic approval reservation' })).body
  assert.equal((await request(`/trio/proposals/${proposal.id}/claim`, {})).status, 200)
  assert.equal((await request(`/api/proposals/${proposal.id}/cancel`, {})).status, 409)
  assert.equal((await request(`/trio/proposals/${proposal.id}/claim`, {})).status, 409)
  assert.equal((await request('/trio/proposals?status=pending')).body.length, 0)
  assert.equal((await request('/api/proposals?status=applying')).body.length, 1)
  assert.equal((await request(`/trio/proposals/${proposal.id}/result`, { status: 'applied' })).status, 200)
  const cancelled = (await request('/api/proposals', { target: 'preferences', patch: { maxIOB: 2.1 }, reason: 'Synthetic cancelled proposal' })).body
  assert.equal((await request(`/api/proposals/${cancelled.id}/cancel`, {})).status, 200)
  assert.equal((await request(`/trio/proposals/${cancelled.id}/claim`, {})).status, 409)
})

test('raw history: authenticated relay and stdio retrieve all 8640 exact readings, other series and coverage', async t => {
  const { Client } = await import('@modelcontextprotocol/sdk/client/index.js')
  const { StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js')
  const { request, env } = await fixture(t, undefined, { configuration: { anthropicApiKey: '' } })
  const start = Date.now() - 30 * 86400000 + 60000
  const from = new Date(start).toISOString(), to = new Date(start + 30 * 86400000).toISOString()
  const glucose = Array.from({ length: 8640 }, (_, i) => ({ t: new Date(start + i * 300000).toISOString(), v: 100 + i / 100000, d: 'Flat' }))
  const boluses = [{ t: glucose[0].t, u: 0.123456789, smb: true, ext: false }]
  assert.equal((await request('/trio/history', { glucose, boluses })).body.glucose, 8640)
  assert.equal((await request('/api/history', undefined, false)).status, 401)
  assert.equal((await request('/api/history/quality', undefined, false)).status, 401)
  const periods = { a: { from, to }, b: { from, to } }
  assert.equal((await request('/api/history/compare', periods, false)).status, 401)
  for (const query of ['limit=1001', 'kind=unknown', 'from=2026-01-01', 'cursor=broken']) {
    assert.equal((await request('/api/history?' + query)).status, 400)
  }
  const client = new Client({ name: 'synthetic-exact-charts', version: '1.0.0' })
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [script, 'mcp'], env }))
  t.after(() => client.close())
  const call = async (name, args) => {
    const response = await client.callTool({ name, arguments: args })
    assert.equal(response.isError, undefined, JSON.stringify(response))
    return JSON.parse(response.content[0].text)
  }
  const all = []
  let page = await call('trio_get_history', { kind: 'glucose', from, to, limit: 1000 })
  const revision = page.revision
  while (true) {
    assert.equal(page.total, 8640)
    assert.equal(page.offset, all.length)
    assert.equal(page.revision, revision)
    all.push(...page.data)
    if (!page.nextCursor) break
    page = await call('trio_get_history', { cursor: page.nextCursor, limit: 1000 })
  }
  assert.deepEqual(all, glucose)
  assert.deepEqual((await call('trio_get_history', { kind: 'boluses', from, to })).data, boluses)
  assert.equal((await call('trio_get_data_quality', { from, to })).glucoseCadence.occupiedSlots, 8640)
  assert.equal((await call('trio_compare_periods', periods)).deltaBMinusA.mean, 0)
  const initial = await call('trio_get_history', { from, to, limit: 1 })
  await request('/trio/history', { glucose: [{ ...glucose[1], v: 199.123456 }] })
  const changed = await client.callTool({ name: 'trio_get_history', arguments: { cursor: initial.nextCursor } })
  assert.equal(changed.isError, true)
  assert.match(changed.content[0].text, /History changed/)
})

test('unreadable history fails explicitly and is never replaced by a fresh upload', async t => {
  const { dir, request } = await fixture(t)
  const file = path.join(dir, 'history.json')
  for (const invalid of ['broken-history', 'null', '[]', '{"glucose":{}}']) {
    await fs.writeFile(file, invalid)
    for (const route of ['/api/history', '/api/history/quality']) {
      const result = await request(route)
      assert.equal(result.status, 400)
      assert.match(result.body.error, /Stored history could not be read/)
    }
    assert.equal((await request('/trio/history', { glucose: [{ t: new Date().toISOString(), v: 120 }] })).status, 400)
    assert.equal(await fs.readFile(file, 'utf8'), invalid)
  }
})
