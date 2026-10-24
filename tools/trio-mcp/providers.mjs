// Provider settings are isolated so switching providers never reuses another provider's key.
export const AI_PROVIDERS = Object.freeze(['anthropic', 'openai', 'openai-compatible'])
export const AI_PROVIDER_DEFAULTS = Object.freeze({
  anthropic: { label: 'Anthropic', model: 'claude-sonnet-4-5', baseURL: 'https://api.anthropic.com/v1' },
  openai: { label: 'OpenAI', model: '', baseURL: 'https://api.openai.com/v1' },
  'openai-compatible': { label: 'OpenAI-kompatibel', model: '', baseURL: '' }
})

const isLoopback = (url) => ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname)
const text = (value, name) => {
  if (value === undefined || value === null) return ''
  if (typeof value !== 'string') throw new Error(`${name} must be text`)
  return value.trim()
}

export function normalizeBaseURL(provider, value) {
  if (!AI_PROVIDERS.includes(provider)) throw new Error('Unknown AI provider')
  let url
  try { url = new URL(text(value, 'Base URL')) } catch { throw new Error('A valid AI base URL is required') }
  if (url.username || url.password || url.search || url.hash) throw new Error('AI base URL must not contain credentials, query parameters, or a fragment')
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && isLoopback(url))) {
    throw new Error('AI base URL requires HTTPS (HTTP is allowed only on localhost)')
  }
  const normalized = url.toString().replace(/\/+$/, '')
  if (provider !== 'openai-compatible' && normalized !== AI_PROVIDER_DEFAULTS[provider].baseURL) {
    throw new Error(`${AI_PROVIDER_DEFAULTS[provider].label} requires its official API base URL; use openai-compatible for a custom endpoint`)
  }
  return normalized
}

export function resolveAIConfig(config = {}) {
  const provider = config.provider ?? 'anthropic'
  if (!AI_PROVIDERS.includes(provider)) throw new Error('Unknown AI provider')
  const saved = config.providers?.[provider] ?? {}
  const defaults = AI_PROVIDER_DEFAULTS[provider]
  const legacy = provider === 'anthropic' ? config : {}
  const apiKey = text(saved.apiKey ?? legacy.anthropicApiKey, 'API key')
  const model = text(saved.model ?? legacy.model ?? defaults.model, 'Model')
  const rawURL = text(saved.baseURL ?? defaults.baseURL, 'Base URL')
  const baseURL = rawURL ? normalizeBaseURL(provider, rawURL) : ''
  const apiKeyBaseURL = text(saved.apiKeyBaseURL, 'API key base URL')
  if (provider === 'openai-compatible' && apiKey && (!baseURL || apiKeyBaseURL !== baseURL)) {
    throw new Error('The API key is not bound to this base URL. Save the key again for the selected endpoint.')
  }
  return { provider, apiKey, model, baseURL, apiKeyBaseURL }
}

export function aiConfigurationStatus(config = {}) {
  const provider = config.provider ?? 'anthropic'
  const saved = config.providers?.[provider] ?? {}
  let status = {
    provider,
    model: typeof saved.model === 'string' ? saved.model : (provider === 'anthropic' ? config.model ?? AI_PROVIDER_DEFAULTS.anthropic.model : ''),
    baseURL: typeof saved.baseURL === 'string' ? saved.baseURL : AI_PROVIDER_DEFAULTS[provider]?.baseURL ?? '',
    hasKey: Boolean(saved.apiKey ?? (provider === 'anthropic' ? config.anthropicApiKey : '')),
    ready: false,
    error: null
  }
  try {
    const ai = resolveAIConfig(config)
    status = { ...status, provider: ai.provider, model: ai.model, baseURL: ai.baseURL, hasKey: Boolean(ai.apiKey) }
    if (!ai.baseURL) throw new Error('Set an AI base URL')
    if (!ai.model) throw new Error('Select an AI model')
    if (!ai.apiKey && ai.provider !== 'openai-compatible') throw new Error(`Set an API key for ${AI_PROVIDER_DEFAULTS[provider].label}`)
    status.ready = true
  } catch (error) {
    status.error = error.message
  }
  return status
}

function endpointFor(ai) {
  const path = ai.provider === 'anthropic' ? '/messages' : ai.provider === 'openai' ? '/responses' : '/chat/completions'
  const override = process.env[ai.provider === 'anthropic' ? 'TRIO_MCP_ANTHROPIC_URL' : ai.provider === 'openai' ? 'TRIO_MCP_OPENAI_URL' : 'TRIO_MCP_COMPATIBLE_URL']
  if (!override) return ai.baseURL + path
  // Test overrides may target local mocks only, never a different remote key recipient.
  let url
  try { url = new URL(override) } catch { throw new Error('Invalid local AI test endpoint') }
  if (!isLoopback(url) || !['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('AI test endpoint overrides must use a local loopback URL')
  }
  return url.toString()
}

export async function requestToolResult({ config, system, prompt, tool }) {
  const status = aiConfigurationStatus(config)
  if (!status.ready) throw new Error(status.error)
  const ai = resolveAIConfig(config)
  const headers = { 'content-type': 'application/json' }
  let request
  if (ai.provider === 'anthropic') {
    headers['x-api-key'] = ai.apiKey
    headers['anthropic-version'] = '2023-06-01'
    request = {
      model: ai.model, max_tokens: 8000, system, tools: [tool],
      tool_choice: { type: 'tool', name: tool.name, disable_parallel_tool_use: true },
      messages: [{ role: 'user', content: prompt }]
    }
  } else {
    if (ai.apiKey) headers.Authorization = `Bearer ${ai.apiKey}`
    const fn = { name: tool.name, description: tool.description, parameters: tool.input_schema, strict: false }
    request = ai.provider === 'openai' ? {
      model: ai.model, max_output_tokens: 8000, store: false,
      instructions: system, input: [{ role: 'user', content: prompt }],
      tools: [{ type: 'function', ...fn }], tool_choice: { type: 'function', name: tool.name }, parallel_tool_calls: false
    } : {
      model: ai.model, max_tokens: 8000,
      messages: [{ role: 'system', content: system }, { role: 'user', content: prompt }],
      tools: [{ type: 'function', function: fn }], tool_choice: { type: 'function', function: { name: tool.name } }, parallel_tool_calls: false
    }
  }
  const endpoint = endpointFor(ai)
  let response
  try {
    response = await fetch(endpoint, {
      method: 'POST', headers, body: JSON.stringify(request), redirect: 'error', signal: AbortSignal.timeout(120000)
    })
  } catch (error) {
    if (error.name === 'TimeoutError') throw new Error('AI request timed out')
    throw new Error('AI request failed; check the selected endpoint and network connection')
  }
  // Do not persist provider error bodies: they can echo keys or private request data.
  if (!response.ok) throw new Error(`${AI_PROVIDER_DEFAULTS[ai.provider].label} API HTTP ${response.status}`)
  let body
  try { body = await response.json() } catch { throw new Error('AI response is not valid JSON') }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('AI response must be an object')
  let calls
  if (ai.provider === 'anthropic') {
    if (body.stop_reason && body.stop_reason !== 'tool_use') throw new Error('AI response did not complete the requested tool call')
    calls = (Array.isArray(body.content) ? body.content : []).filter(item => item?.type === 'tool_use').map(item => ({ name: item.name, input: item.input }))
  } else if (ai.provider === 'openai') {
    if (body.status && body.status !== 'completed') throw new Error('AI response is incomplete')
    calls = (Array.isArray(body.output) ? body.output : []).filter(item => item?.type === 'function_call').map(item => ({ name: item.name, arguments: item.arguments, status: item.status }))
  } else {
    const choices = body.choices
    if (!Array.isArray(choices) || choices.length !== 1) throw new Error('AI response must contain one completion')
    const choice = choices[0]
    if (choice.finish_reason && choice.finish_reason !== 'tool_calls') throw new Error('AI response did not complete the requested tool call')
    calls = (Array.isArray(choice?.message?.tool_calls) ? choice.message.tool_calls : []).map(item => ({ name: item?.function?.name, arguments: item?.function?.arguments }))
  }
  if (calls.length !== 1 || calls[0].name !== tool.name || (calls[0].status && calls[0].status !== 'completed')) {
    throw new Error(`AI response must contain exactly one ${tool.name} call`)
  }
  let input = calls[0].input
  if (ai.provider !== 'anthropic') {
    try { input = JSON.parse(calls[0].arguments) } catch { throw new Error('AI tool arguments are not valid JSON') }
  }
  return { input, provider: ai.provider, model: typeof body.model === 'string' ? body.model : ai.model, usage: body.usage }
}
