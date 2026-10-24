// The iPhone publishes the writable keys and their real storage types.
const legacyTargets = ['settings', 'preferences']
const kind = value => value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value

function validJSON(value, depth = 0) {
  if (depth > 16) return false
  if (value === null || ['string', 'boolean'].includes(typeof value)) return true
  if (typeof value === 'number') return Number.isFinite(value)
  if (Array.isArray(value)) return value.every(item => validJSON(item, depth + 1))
  return typeof value === 'object' && Object.entries(value).every(([key, item]) =>
    !['__proto__', 'prototype', 'constructor'].includes(key) && validJSON(item, depth + 1))
}

export function validateSettingsPatch(state, target, changes) {
  if (!changes || kind(changes) !== 'object' || !Object.keys(changes).length || !validJSON(changes)) {
    throw new Error('changes must be a non-empty JSON object with finite values (maximum depth 16)')
  }
  const catalog = state?.settingsCatalog
  const section = state?.[target]
  if (!Array.isArray(catalog) && (!legacyTargets.includes(target) || !section)) {
    throw new Error(`No writable ${target} snapshot from Trio yet – sync the current app first.`)
  }
  for (const [key, value] of Object.entries(changes)) {
    const entry = Array.isArray(catalog) ? catalog.find(row => row.target === target && row.key === key) : null
    if (Array.isArray(catalog) && (!entry || entry.access !== 'proposal')) {
      throw new Error(`Cannot propose ${target}.${key}: ${entry?.reason || 'not in the writable settings catalog'}`)
    }
    if (!entry && !Object.hasOwn(section, key)) throw new Error(`Invalid proposal: unknown key "${key}"`)
    const expected = entry?.type || kind(section[key])
    if (expected === 'integer' ? !Number.isInteger(value) : expected !== 'null' && kind(value) !== expected) {
      throw new Error(`Invalid proposal: "${key}" must be ${expected}`)
    }
    const constraints = entry?.constraints || {}
    if (constraints.integer && !Number.isInteger(value)) throw new Error(`Invalid proposal: "${key}" must be integer`)
    if (typeof value === 'number' && (value < (constraints.minimum ?? -Infinity) || value > (constraints.maximum ?? Infinity))) {
      throw new Error(`Invalid proposal: "${key}" is outside its supported range`)
    }
    if (typeof value === 'number' && constraints.exclusiveMinimum !== undefined && value <= constraints.exclusiveMinimum) {
      throw new Error(`Invalid proposal: "${key}" must be greater than ${constraints.exclusiveMinimum}`)
    }
    if (typeof value === 'number' && constraints.step > 0 && value !== entry?.current) {
      const steps = (value - (constraints.minimum ?? 0)) / constraints.step
      if (Math.abs(steps - Math.round(steps)) > 0.000001) throw new Error(`Invalid proposal: "${key}" does not match its supported step`)
    }
    if (Array.isArray(value) && ((constraints.length !== undefined && value.length !== constraints.length) || value.length > (constraints.maxItems ?? Infinity))) {
      throw new Error(`Invalid proposal: "${key}" has an unsupported number of items`)
    }
    if (Array.isArray(constraints.enum) && !constraints.enum.some(option => JSON.stringify(option) === JSON.stringify(value))) {
      throw new Error(`Invalid proposal: unsupported value for "${key}"`)
    }
  }
}
