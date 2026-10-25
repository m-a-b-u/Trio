import assert from 'node:assert/strict'
import test from 'node:test'
import { getHistory, getDataQuality, comparePeriods, HISTORY_KINDS } from './history.mjs'

const from = '2026-09-01T00:00:00.000Z'
const to = '2026-10-01T00:00:00.000Z'
const start = Date.parse(from)
const now = Date.parse(to)
const reading = (i, v = 123.456789) => ({ t: new Date(start + i * 300000).toISOString(), v, d: 'Flat' })

test('8640 five-minute records survive all pages with exact values, timestamps and no duplicates', () => {
  const glucose = Array.from({ length: 8640 }, (_, i) => reading(i, 80 + i / 10000))
  const history = { glucose }
  let page = getHistory(history, { from, to, limit: 1000 }, now)
  const received = [], revision = page.revision
  while (true) {
    assert.equal(page.total, 8640)
    assert.equal(page.offset, received.length)
    assert.equal(page.revision, revision)
    received.push(...page.data)
    if (!page.nextCursor) break
    page = getHistory(history, { cursor: page.nextCursor, limit: 1000 }, now + 60000)
  }
  assert.deepEqual(received, glucose)
  assert.equal(new Set(received.map(row => row.t)).size, 8640)
  assert.equal(getDataQuality(history, { from, to }, now).glucoseCadence.occupiedPercent, 100)
})

test('raw series preserve all fields, precision, same-time rows and unusual values, with half-open bounds', () => {
  for (const kind of HISTORY_KINDS) {
    const rows = [reading(1, 0), { ...reading(1, 650), extra: 0.123456789 }, reading(0), reading(8640)]
    const page = getHistory({ [kind]: rows }, { kind, from, to }, now)
    assert.deepEqual(page.data, [rows[2], rows[0], rows[1]])
    assert.equal(page.total, 3)
  }
})

test('pagination rejects edits/backfills/deletions in its window instead of silently skipping data', () => {
  const history = { glucose: [reading(0), reading(1), reading(3)] }
  const { nextCursor } = getHistory(history, { from, to, limit: 1 }, now)
  for (const glucose of [[...history.glucose, reading(2)], history.glucose.slice(1), [reading(0, 99), ...history.glucose.slice(1)]]) {
    assert.throws(() => getHistory({ glucose }, { cursor: nextCursor }, now), /History changed/)
  }
  assert.equal(getHistory({ glucose: [...history.glucose, reading(8641)] }, { cursor: nextCursor }, now).count, 2)
  assert.throws(() => getHistory(history, { cursor: nextCursor, kind: 'carbs' }, now), /different query/)
})

test('invalid input is rejected, including ambiguous dates, unbounded ranges, malformed cursors and limits', () => {
  for (const args of [
    { kind: '../config' }, { from: 'yesterday' }, { from: '2026-09-01T00:00:00' },
    { from: to, to: from }, { from, to: '2026-10-02T00:00:00Z' },
    { limit: 1001 }, { limit: 0 }, { limit: 1.1 }, { cursor: 'bad' }, { unexpected: true }
  ]) assert.throws(() => getHistory({}, args, now))
  assert.deepEqual(getHistory({}, {}, now).data, [])
  assert.equal(getHistory({}, {}, now).total, 0)
})

test('data quality distinguishes empty coverage, edge gaps, duplicates and invalid values from raw data', () => {
  const toHour = new Date(start + 3600000).toISOString()
  const history = { glucose: [reading(3), reading(3), reading(4, 0), reading(5), { t: 'invalid', v: 100 }] }
  const quality = getDataQuality(history, { from, to: toHour }, now)
  assert.equal(quality.series.glucose.count, 4)
  assert.equal(quality.series.glucose.duplicateTimestamps, 1)
  assert.equal(quality.series.glucose.invalidTimestampsInStore, 1)
  assert.equal(quality.glucoseCadence.occupiedSlots, 2)
  assert.equal(quality.glucoseCadence.emptySlots, 10)
  assert.equal(quality.glucoseCadence.invalidValueCount, 1)
  assert.deepEqual(quality.glucoseCadence.gaps.map(g => g.location), ['leading', 'internal', 'trailing'])
  const empty = getDataQuality({}, { from, to }, now)
  assert.equal(empty.glucoseCadence.occupiedPercent, 0)
  assert.equal(empty.glucoseCadence.gaps[0].location, 'whole-window')
})

test('gap detail limit is explicit and does not truncate raw records', () => {
  const glucose = Array.from({ length: 200 }, (_, i) => reading(i * 3))
  const q = getDataQuality({ glucose }, { from, to }, now).glucoseCadence
  assert.equal(q.gaps.length, 100)
  assert.equal(q.gapsTruncated, true)
  assert.equal(getHistory({ glucose }, { from, to }, now).count, 200)
})

test('comparison uses explicit offset-aware bounds, flags coverage, and returns null deltas for missing data', () => {
  const history = { glucose: [reading(0, 100), reading(1, 120), reading(2, 200)] }
  const a = { from: '2026-09-01T02:00:00+02:00', to: reading(2).t }
  const b = { from: reading(2).t, to: reading(3).t }
  const result = comparePeriods(history, { a, b }, now)
  assert.equal(result.a.glucose.mean, 110)
  assert.equal(result.b.glucose.mean, 200)
  assert.equal(result.deltaBMinusA.mean, 90)
  assert.equal(result.a.quality.series.glucose.count, 2)
  assert.equal(comparePeriods({}, { a, b }, now).deltaBMinusA.mean, null)
})
