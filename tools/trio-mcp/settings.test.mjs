import assert from 'node:assert/strict'
import test from 'node:test'
import { validateSettingsPatch } from './settings.mjs'

test('catalog accepts all advertised writable targets, including nested JSON', () => {
  const settingsCatalog = [
    { target: 'glucose_alerts', key: 'alerts', type: 'array', access: 'proposal' },
    { target: 'glucose_alerts', key: 'configuration', type: 'object', access: 'proposal' },
    { target: 'ai_meal', key: 'provider', type: 'string', access: 'proposal', constraints: { enum: ['anthropic', 'openai'] } }
  ]
  validateSettingsPatch({ settingsCatalog }, 'glucose_alerts', { alerts: [{ enabled: true }], configuration: { duration: 5 } })
  validateSettingsPatch({ settingsCatalog }, 'ai_meal', { provider: 'openai' })
  assert.throws(() => validateSettingsPatch({ settingsCatalog }, 'ai_meal', { provider: 'unknown' }), /unsupported value/)
})

test('catalog rejects unadvertised keys, actions, wrong types and numeric bounds', () => {
  const settingsCatalog = [
    { target: 'settings', key: 'port', type: 'integer', access: 'proposal', constraints: { minimum: 1, maximum: 65535 } },
    { target: 'ai_meal', key: 'apiKey', type: 'string', access: 'action', reason: 'Enter on iPhone' }
  ]
  for (const port of [0, 65536, 1.5, '8080', Infinity]) {
    assert.throws(() => validateSettingsPatch({ settingsCatalog }, 'settings', { port }))
  }
  assert.throws(() => validateSettingsPatch({ settingsCatalog }, 'settings', { unknown: true }), /not in the writable/)
  assert.throws(() => validateSettingsPatch({ settingsCatalog }, 'ai_meal', { apiKey: 'not-a-secret' }), /Enter on iPhone/)
})

test('legacy snapshots remain supported without opening arbitrary new stores', () => {
  const state = { settings: { enabled: true }, pump_settings: { maxBolus: 1 } }
  validateSettingsPatch(state, 'settings', { enabled: false })
  assert.throws(() => validateSettingsPatch(state, 'settings', { enabled: 1 }), /must be boolean/)
  assert.throws(() => validateSettingsPatch(state, 'pump_settings', { maxBolus: 2 }), /sync the current app/)
  assert.throws(() => validateSettingsPatch(state, 'settings', JSON.parse('{"__proto__":{}}')), /JSON object/)
})

test('catalog scalar steps match native pickers while retaining an unchanged legacy value', () => {
  const settingsCatalog = [{ target: 'settings', key: 'interval', type: 'number', access: 'proposal', current: 20,
    constraints: { minimum: 1, maximum: 60, step: 5 } }]
  validateSettingsPatch({ settingsCatalog }, 'settings', { interval: 20 })
  validateSettingsPatch({ settingsCatalog }, 'settings', { interval: 21 })
  assert.throws(() => validateSettingsPatch({ settingsCatalog }, 'settings', { interval: 22 }), /supported step/)
})
