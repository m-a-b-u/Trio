import { AI_PROVIDERS, AI_PROVIDER_DEFAULTS, aiConfigurationStatus, normalizeBaseURL } from './providers.mjs'

export function relaySettings(config) {
  const ai = aiConfigurationStatus(config)
  return { provider: ai.provider, model: ai.model, baseURL: ai.baseURL, analysisTime: config.analysisTime || '07:00' }
}

export function withRelayCatalog(state, config) {
  if (!state) return null
  const current = relaySettings(config)
  // Old app versions cannot approve the relay_config target.
  if (!Array.isArray(state.settingsCatalog)) return state
  return { ...state, settingsCatalog: [
    ...state.settingsCatalog.filter(row => row.target !== 'relay_config'),
    ...Object.entries(current).map(([key, value]) => ({ target: 'relay_config', key, type: 'string', current: value, access: 'proposal', constraints: key === 'provider' ? { enum: AI_PROVIDERS } : {} })),
    { target: 'relay_config', key: 'apiKey', type: 'string', access: 'action', reason: 'Enter the provider key locally on the Mac with set-api-key; keys are never exported.' }
  ] }
}

export function patchRelaySettings(config, patch) {
  if (!patch || Array.isArray(patch) || typeof patch !== 'object' || !Object.keys(patch).length) throw new Error('Empty relay settings patch')
  const allowed = ['provider', 'model', 'baseURL', 'analysisTime']
  for (const [key, value] of Object.entries(patch)) {
    if (!allowed.includes(key) || typeof value !== 'string') throw new Error(`Unsupported relay setting: ${key}`)
  }
  const next = structuredClone(config)
  const provider = patch.provider ?? config.provider ?? 'anthropic'
  if (!AI_PROVIDERS.includes(provider)) throw new Error('Unknown AI provider')
  next.provider = provider
  next.providers ||= {}
  const saved = next.providers[provider] ||= {}
  if (patch.analysisTime !== undefined) {
    if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(patch.analysisTime)) throw new Error('analysisTime must be HH:mm')
    next.analysisTime = patch.analysisTime
  }
  if (patch.model !== undefined) {
    if (!patch.model.trim()) throw new Error('Model must not be empty')
    saved.model = patch.model.trim()
  }
  if (patch.baseURL !== undefined) {
    const baseURL = normalizeBaseURL(provider, patch.baseURL)
    if (provider === 'openai-compatible' && saved.baseURL !== baseURL) {
      delete saved.apiKey
      delete saved.apiKeyBaseURL
    }
    saved.baseURL = baseURL
  }
  // Configuration may await a locally entered key, but model and endpoint must be deliberate.
  if (!(saved.model ?? (provider === 'anthropic' ? config.model ?? AI_PROVIDER_DEFAULTS.anthropic.model : '')).trim()) throw new Error('Include the model when selecting this provider')
  normalizeBaseURL(provider, saved.baseURL ?? AI_PROVIDER_DEFAULTS[provider].baseURL)
  return next
}
