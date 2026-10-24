import assert from 'node:assert/strict'
import test from 'node:test'
import { checkStepSize } from './analysis.mjs'

test('step guard accepts a 20% boundary and blocks an oversized basal change', () => {
  const state = { basalProfile: [{ minutes: 0, rate: 1 }] }
  assert.equal(checkStepSize(state, { target: 'basal_profile', schedule: [{ time: '00:00', value: 1.2 }] }), null)
  assert.ok(checkStepSize(state, { target: 'basal_profile', schedule: [{ time: '00:00', value: 2 }] }))
})

test('step guard checks both glucose target bounds', () => {
  const state = { bgTargets: { targets: [{ offset: 0, low: 100, high: 110 }] } }
  assert.ok(checkStepSize(state, { target: 'bg_targets', schedule: [{ time: '00:00', low: 100, high: 300 }] }))
})

test('step guard blocks schedules without a current baseline', () => {
  assert.ok(checkStepSize({}, { target: 'basal_profile', schedule: [{ time: '00:00', value: 2 }] }))
})

test('step guard cannot treat a change from zero as a bounded relative change', () => {
  assert.ok(checkStepSize({ preferences: { maxIOB: 0 } }, { target: 'preferences', changes: { maxIOB: 20 } }))
  assert.ok(checkStepSize({ basalProfile: [{ minutes: 0, rate: 0 }] }, {
    target: 'basal_profile', schedule: [{ time: '00:00', value: 2 }]
  }))
})

test('step guard accepts the documented 30% settings boundary', () => {
  assert.equal(checkStepSize({ preferences: { maxIOB: 1 } }, { target: 'preferences', changes: { maxIOB: 1.3 } }), null)
})
