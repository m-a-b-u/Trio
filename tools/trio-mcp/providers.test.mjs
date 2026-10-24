import assert from 'node:assert/strict'
import { once } from 'node:events'
import http from 'node:http'
import test from 'node:test'
import { aiConfigurationStatus, normalizeBaseURL, resolveAIConfig } from './providers.mjs'
import { checkStepSize, runAIAnalysis, runClaudeAnalysis, validateAnalysisResult } from './analysis.mjs'

const report = () => ({ summary: 'Synthetic report', highlights: [], findings: [], proposals: [] })
const fixture = () => ({ state: { settings: { enabled: true }, preferences: { maxIOB: 2 } }, stats: { coveredDays: 8 }, previousReports: [] })
const configs = {
  anthropic: { provider: 'anthropic', providers: { anthropic: { apiKey: 'synthetic-anthropic', model: 'synthetic-claude' } } },
  openai: { provider: 'openai', providers: { openai: { apiKey: 'synthetic-openai', model: 'synthetic-gpt' } } }
}
const overrideNames = { anthropic: 'TRIO_MCP_ANTHROPIC_URL', openai: 'TRIO_MCP_OPENAI_URL' }

function envelope(provider, input = report()) {
  if (provider === 'anthropic') return { model: 'synthetic-response-model', stop_reason: 'tool_use', content: [{ type: 'tool_use', name: 'submit_analysis', input }] }
  if (provider === 'openai') return { model: 'synthetic-response-model', status: 'completed', output: [{ type: 'function_call', name: 'submit_analysis', arguments: JSON.stringify(input), status: 'completed' }] }
  return { model: 'synthetic-response-model', choices: [{ finish_reason: 'tool_calls', message: { tool_calls: [{ type: 'function', function: { name: 'submit_analysis', arguments: JSON.stringify(input) } }] } }] }
}

async function mockProvider(t, provider, respond = () => envelope(provider)) {
  const requests = []
  const server = http.createServer(async (req, res) => {
    let raw = ''
    for await (const part of req) raw += part
    requests.push({ path: req.url, headers: req.headers, body: JSON.parse(raw) })
    const result = respond(req, res)
    if (result !== undefined) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(result)) }
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const baseURL = `http://127.0.0.1:${server.address().port}/v1`
  const override = overrideNames[provider]
  const priorOverride = override && process.env[override]
  if (override) process.env[override] = baseURL + (provider === 'anthropic' ? '/messages' : '/responses')
  t.after(async () => {
    if (override) {
      if (priorOverride === undefined) delete process.env[override]
      else process.env[override] = priorOverride
    }
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
  })
  const config = provider === 'openai-compatible' ? {
    provider, providers: { [provider]: { apiKey: 'synthetic-compatible', model: 'synthetic-compatible-model', baseURL, apiKeyBaseURL: baseURL } }
  } : configs[provider]
  return { config, requests, baseURL }
}

test('legacy Anthropic config resolves without leaking its key or model across providers', () => {
  const legacy = { anthropicApiKey: 'synthetic-legacy-key', model: 'synthetic-legacy-model' }
  assert.equal(resolveAIConfig(legacy).apiKey, legacy.anthropicApiKey)
  assert.equal(resolveAIConfig(legacy).model, legacy.model)
  assert.equal(resolveAIConfig({ ...legacy, provider: 'openai' }).apiKey, '')
  assert.equal(resolveAIConfig({ ...legacy, provider: 'openai' }).model, '')
  const migrated = resolveAIConfig({ ...legacy, providers: { anthropic: { apiKey: '', model: 'new-model' } } })
  assert.equal(migrated.apiKey, '')
  assert.equal(migrated.model, 'new-model')
})

test('configuration status safely represents incomplete provider settings', () => {
  assert.equal(aiConfigurationStatus({ provider: 'openai' }).ready, false)
  assert.match(aiConfigurationStatus({ provider: 'openai' }).error, /model/i)
  assert.equal(aiConfigurationStatus(configs.openai).ready, true)
  assert.equal(aiConfigurationStatus({ provider: 'unknown' }).ready, false)
  assert.equal(aiConfigurationStatus({ provider: 'openai-compatible' }).ready, false)
  assert.equal(aiConfigurationStatus({ provider: 'openai-compatible', providers: { 'openai-compatible': { model: 'local', baseURL: 'http://localhost:1234/v1' } } }).ready, true)
})

test('endpoint validation binds official providers and excludes unsafe custom URLs', () => {
  assert.equal(normalizeBaseURL('openai', 'https://api.openai.com/v1/'), 'https://api.openai.com/v1')
  assert.equal(normalizeBaseURL('openai-compatible', 'https://example.test/tenant/v1/'), 'https://example.test/tenant/v1')
  assert.equal(normalizeBaseURL('openai-compatible', 'http://[::1]:1234/v1'), 'http://[::1]:1234/v1')
  for (const url of ['http://example.test/v1', 'https://key@example.test/v1', 'https://example.test/v1?key=secret', 'https://example.test/v1#token', 'file:///tmp/api']) {
    assert.throws(() => normalizeBaseURL('openai-compatible', url))
  }
  for (const provider of ['anthropic', 'openai']) assert.throws(() => normalizeBaseURL(provider, 'https://example.test/v1'))
})

test('compatible keys are bound to the entire normalized base URL', () => {
  const configured = { provider: 'openai-compatible', providers: { 'openai-compatible': { apiKey: 'synthetic-key', model: 'model', baseURL: 'https://example.test/tenant1/v1', apiKeyBaseURL: 'https://example.test/tenant1/v1' } } }
  assert.equal(resolveAIConfig(configured).apiKey, 'synthetic-key')
  configured.providers['openai-compatible'].baseURL = 'https://example.test/tenant2/v1'
  assert.throws(() => resolveAIConfig(configured), /not bound/)
  assert.equal(aiConfigurationStatus(configured).ready, false)
})

for (const provider of ['anthropic', 'openai', 'openai-compatible']) {
  test(`${provider} submits the same guarded analysis with its own API wire format`, async t => {
    const { config, requests } = await mockProvider(t, provider)
    const result = await runAIAnalysis({ config, ...fixture() })
    assert.equal(result.provider, provider)
    assert.equal(result.summary, 'Synthetic report')
    assert.equal(result.model, 'synthetic-response-model')
    assert.equal(requests.length, 1)
    const { path, headers, body } = requests[0]
    if (provider === 'anthropic') {
      assert.equal(path, '/v1/messages')
      assert.equal(headers['x-api-key'], 'synthetic-anthropic')
      assert.equal(headers.authorization, undefined)
      assert.equal(body.tool_choice.name, 'submit_analysis')
      assert.match(body.system, /Face ID/)
      assert.match(body.system, /höchstens 10 %/)
    } else if (provider === 'openai') {
      assert.equal(path, '/v1/responses')
      assert.equal(headers.authorization, 'Bearer synthetic-openai')
      assert.equal(body.store, false)
      assert.equal(body.tool_choice.name, 'submit_analysis')
      assert.equal(body.tools[0].type, 'function')
      assert.equal(body.tools[0].strict, false)
      assert.equal(body.max_output_tokens, 8000)
      assert.equal(body.messages, undefined)
      assert.match(body.instructions, /mindestens 3 verschiedenen Tagen/)
    } else {
      assert.equal(path, '/v1/chat/completions')
      assert.equal(headers.authorization, 'Bearer synthetic-compatible')
      assert.equal(body.tool_choice.function.name, 'submit_analysis')
      assert.equal(body.tools[0].function.name, 'submit_analysis')
      assert.equal(body.messages[0].role, 'system')
      assert.match(body.messages[0].content, /Keine Boli/)
    }
  })

  test(`${provider} rejects a malformed or unexpected analysis tool result`, async t => {
    const { config } = await mockProvider(t, provider, () => envelope(provider, { ...report(), proposals: [null] }))
    await assert.rejects(runAIAnalysis({ config, ...fixture() }), /Invalid analysis proposal/)
  })

  test(`${provider} rejects explicitly incomplete responses`, async t => {
    const { config } = await mockProvider(t, provider, () => {
      const result = envelope(provider)
      if (provider === 'anthropic') result.stop_reason = 'max_tokens'
      else if (provider === 'openai') result.status = 'incomplete'
      else result.choices[0].finish_reason = 'length'
      return result
    })
    await assert.rejects(runAIAnalysis({ config, ...fixture() }), /incomplete|did not complete/)
  })
}

test('legacy runClaudeAnalysis still uses the Anthropic transport', async t => {
  await mockProvider(t, 'anthropic')
  const result = await runClaudeAnalysis({ apiKey: 'synthetic-legacy', model: 'synthetic-model', ...fixture() })
  assert.equal(result.summary, 'Synthetic report')
  assert.equal(result.provider, 'anthropic')
})

test('provider HTTP errors do not expose response bodies', async t => {
  const { config } = await mockProvider(t, 'openai', (req, res) => {
    res.statusCode = 429
    return { error: { message: 'synthetic-private-data-and-key' } }
  })
  await assert.rejects(runAIAnalysis({ config, ...fixture() }), error => error.message === 'OpenAI API HTTP 429')
})

test('redirects are rejected before any key or data can reach another endpoint', async t => {
  const { config, requests, baseURL } = await mockProvider(t, 'openai', (req, res) => {
    res.writeHead(307, { Location: '/should-not-receive-data' })
    res.end()
  })
  await assert.rejects(runAIAnalysis({ config, ...fixture() }), /AI request failed/)
  assert.equal(requests.length, 1)
})

test('non-JSON and duplicate or incorrectly named function calls are rejected', async t => {
  let reply = 'not-json'
  const { config } = await mockProvider(t, 'openai', (req, res) => {
    if (reply === 'not-json') { res.end('not-json'); return }
    const result = envelope('openai')
    if (reply === 'duplicate') result.output.push({ ...result.output[0] })
    if (reply === 'wrong-name') result.output[0].name = 'apply_changes'
    if (reply === 'bad-arguments') result.output[0].arguments = '{'
    return result
  })
  await assert.rejects(runAIAnalysis({ config, ...fixture() }), /not valid JSON/)
  for (const invalid of ['duplicate', 'wrong-name', 'bad-arguments']) {
    reply = invalid
    await assert.rejects(runAIAnalysis({ config, ...fixture() }), /exactly one submit_analysis|arguments are not valid JSON/)
  }
})

test('analysis schema and result validation include only proposal-enabled catalog targets', async t => {
  const input = { ...report(), proposals: [{ target: 'notifications', changes: { enabled: false }, reason: 'Synthetic setting' }] }
  const { config, requests } = await mockProvider(t, 'openai', () => envelope('openai', input))
  const state = { settingsCatalog: [
    { target: 'notifications', key: 'enabled', access: 'proposal' },
    { target: 'pumpAction', key: 'bolus', access: 'action' },
    { target: 'status', key: 'glucose', access: 'readOnly' }
  ] }
  assert.equal((await runAIAnalysis({ config, state, stats: {} })).proposals[0].target, 'notifications')
  const targets = requests[0].body.tools[0].parameters.properties.proposals.items.properties.target.enum
  assert.ok(targets.includes('notifications'))
  assert.ok(!targets.includes('pumpAction'))
  assert.ok(!targets.includes('status'))
  assert.throws(() => validateAnalysisResult({ ...input, proposals: [{ ...input.proposals[0], target: 'pumpAction' }] }, state))
})

test('catalog settings reach the model and preserve string, array, and nested changes', async t => {
  const input = { ...report(), proposals: [{ target: 'app_preferences', changes: {
    color: 'dark', order: ['glucose', 'iob'], options: { enabled: true }
  }, reason: 'Synthetic preference' }] }
  const { config, requests } = await mockProvider(t, 'openai', () => envelope('openai', input))
  const state = { settingsCatalog: [
    { target: 'app_preferences', key: 'color', type: 'string', current: 'light', access: 'proposal', constraints: {} },
    { target: 'app_preferences', key: 'order', type: 'array', current: ['iob', 'glucose'], access: 'proposal', constraints: {} },
    { target: 'app_preferences', key: 'options', type: 'object', current: { enabled: false }, access: 'proposal', constraints: {} }
  ] }
  const result = await runAIAnalysis({ config, state, stats: {} })
  assert.deepEqual(result.proposals, input.proposals)
  const payload = JSON.parse(requests[0].body.input[0].content.split('\n\n')[1])
  assert.deepEqual(payload.currentSettings.settingsCatalog, state.settingsCatalog)
})

test('numeric settings outside legacy snapshot sections retain the automatic step guard', () => {
  const state = { settingsCatalog: [{ target: 'pump_settings', key: 'dia', type: 'number', current: 5, access: 'proposal', constraints: {} }] }
  assert.equal(checkStepSize(state, { target: 'pump_settings', changes: { dia: 6 } }), null)
  assert.ok(checkStepSize(state, { target: 'pump_settings', changes: { dia: 10 } }))
})
