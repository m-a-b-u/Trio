// Exact relay records for charts. Statistics are deliberately a separate operation.
import { createHash } from 'node:crypto'
import { z } from 'zod'
import { computeStats } from './analysis.mjs'

const DAY = 86400000
const STEP = 300000
export const HISTORY_KINDS = ['glucose', 'carbs', 'boluses', 'tempBasals', 'determinations', 'tdd']
const timestamp = z.iso.datetime({ offset: true })
export const rangeShape = { from: timestamp.optional(), to: timestamp.optional() }
export const historyShape = {
  kind: z.enum(HISTORY_KINDS).optional(), ...rangeShape,
  limit: z.number().int().min(1).max(1000).default(500),
  cursor: z.string().min(1).max(2048).optional()
}
export const compareShape = {
  a: z.object({ from: timestamp, to: timestamp }).strict(),
  b: z.object({ from: timestamp, to: timestamp }).strict()
}
const fields = {
  glucose: { t: 'ISO 8601 timestamp', v: 'mg/dL', d: 'direction' },
  carbs: { t: 'ISO 8601 timestamp', c: 'g carbohydrate', f: 'g fat', p: 'g protein', fpu: 'fat/protein equivalent entry', note: 'note' },
  boluses: { t: 'ISO 8601 timestamp', u: 'U', smb: 'automatic SMB', ext: 'external bolus' },
  tempBasals: { t: 'ISO 8601 timestamp', rate: 'U/h', min: 'minutes' },
  determinations: { t: 'ISO 8601 timestamp', enacted: 'enacted flag', bg: 'mg/dL', iob: 'U', cob: 'g', isf: 'mg/dL per U', cr: 'g per U', sens: 'ratio', target: 'mg/dL', eventual: 'mg/dL', rate: 'U/h', smb: 'U requested', basal: 'U/h scheduled', req: 'U requested' },
  tdd: { t: 'ISO 8601 timestamp', total: 'U', bolus: 'U', temp: 'U', scheduled: 'U' }
}
const source = 'Synced relay records only. Phone history completeness is not proven. No interpolation, resampling, unit conversion or rounding. Current iPhone export uses second-resolution timestamps.'

function range(input, now) {
  const end = input.to === undefined ? now : Date.parse(input.to)
  const start = input.from === undefined ? end - 30 * DAY : Date.parse(input.from)
  if (!(start < end) || end - start > 30 * DAY) throw new Error('Range must be positive and at most 30 days.')
  return { from: new Date(start).toISOString(), to: new Date(end).toISOString() }
}
function rowsIn(history, kind, window) {
  const start = Date.parse(window.from), end = Date.parse(window.to)
  return (history[kind] || []).filter(row => {
    const t = Date.parse(row.t)
    return t >= start && t < end
  }).sort((a, b) => Date.parse(a.t) - Date.parse(b.t))
}
const digest = rows => createHash('sha256').update(JSON.stringify(rows)).digest('hex')
const cursorSchema = z.object({
  kind: z.enum(HISTORY_KINDS), from: timestamp, to: timestamp,
  offset: z.number().int().nonnegative(), revision: z.string().regex(/^[a-f0-9]{64}$/)
}).strict()

export function getHistory(history, input = {}, now = Date.now()) {
  const query = z.object(historyShape).strict().parse(input)
  let previous
  if (query.cursor) {
    try { previous = cursorSchema.parse(JSON.parse(Buffer.from(query.cursor, 'base64url').toString('utf8'))) }
    catch { throw new Error('Invalid history cursor.') }
    for (const key of ['kind', 'from', 'to']) {
      if (query[key] !== undefined && query[key] !== previous[key]) throw new Error('Cursor belongs to a different query. Pass only cursor and limit for subsequent pages.')
    }
  }
  const window = range(previous || query, now)
  const kind = previous?.kind || query.kind || 'glucose'
  const rows = rowsIn(history, kind, window)
  const revision = digest(rows)
  if (previous && previous.revision !== revision) throw new Error('History changed during pagination. Discard collected pages and restart without cursor.')
  const offset = previous?.offset || 0
  if (offset > rows.length) throw new Error('Cursor offset exceeds history length.')
  const data = rows.slice(offset, offset + query.limit)
  const nextOffset = offset + data.length
  const nextCursor = nextOffset < rows.length
    ? Buffer.from(JSON.stringify({ kind, ...window, offset: nextOffset, revision })).toString('base64url') : null
  return {
    kind, ...window, interval: '[from,to)', source, fields: fields[kind],
    historyUpdatedAt: history.updatedAt || null,
    revision, total: rows.length, offset, count: data.length, nextCursor,
    hasMore: nextCursor !== null,
    completenessMeaning: 'All matching relay rows retrieved only after collecting every page from offset 0. Not proof of complete iPhone or sensor history.',
    data
  }
}

export function getDataQuality(history, input = {}, now = Date.now()) {
  const window = range(z.object(rangeShape).strict().parse(input), now)
  const start = Date.parse(window.from), end = Date.parse(window.to)
  const series = Object.fromEntries(HISTORY_KINDS.map(kind => {
    const rows = rowsIn(history, kind, window)
    return [kind, {
      count: rows.length, first: rows[0]?.t || null, last: rows.at(-1)?.t || null,
      duplicateTimestamps: rows.length - new Set(rows.map(row => Date.parse(row.t))).size,
      invalidTimestampsInStore: (history[kind] || []).filter(row => !Number.isFinite(Date.parse(row.t))).length
    }]
  }))
  const glucose = rowsIn(history, 'glucose', window)
  const valid = glucose.filter(row => typeof row.v === 'number' && Number.isFinite(row.v) && row.v > 0)
  const occupied = new Set(valid.map(row => Math.floor((Date.parse(row.t) - start) / STEP))).size
  const expected = Math.ceil((end - start) / STEP)
  const times = [...new Set(valid.map(row => Date.parse(row.t)))]
  const gaps = []
  const addGap = (from, to, location) => {
    if (to - from > STEP * 1.5) gaps.push({ from: new Date(from).toISOString(), to: new Date(to).toISOString(), seconds: (to - from) / 1000, location })
  }
  if (!times.length) gaps.push({ from: window.from, to: window.to, seconds: (end - start) / 1000, location: 'whole-window' })
  else {
    addGap(start, times[0], 'leading')
    for (let i = 1; i < times.length; i++) addGap(times[i - 1], times[i], 'internal')
    addGap(times.at(-1), end, 'trailing')
  }
  return {
    ...window, interval: '[from,to)', source, historyUpdatedAt: history.updatedAt || null, series,
    glucoseCadence: {
      assumedIntervalSeconds: STEP / 1000, expectedSlots: expected, occupiedSlots: occupied,
      emptySlots: expected - occupied, occupiedPercent: occupied * 100 / expected,
      invalidValueCount: glucose.length - valid.length,
      interpretation: 'Estimated occupancy of 5-minute bins anchored at from; not measured sensor uptime. Jitter and other sensor intervals affect it. Raw values remain unchanged.',
      gapThresholdSeconds: STEP * 1.5 / 1000, gapCount: gaps.length,
      gaps: gaps.slice(0, 100), gapsTruncated: gaps.length > 100
    }
  }
}

export function comparePeriods(history, input, now = Date.now()) {
  const query = z.object(compareShape).strict().parse(input)
  const summarize = input => {
    const window = range(input, now)
    const subset = Object.fromEntries(HISTORY_KINDS.map(kind => [kind, rowsIn(history, kind, window)]))
    const stats = computeStats(subset, Date.parse(window.to))
    return {
      ...window, durationSeconds: (Date.parse(window.to) - Date.parse(window.from)) / 1000,
      glucose: stats.overall30d, quality: getDataQuality(history, window, now)
    }
  }
  const a = summarize(query.a), b = summarize(query.b)
  const delta = Object.fromEntries(['mean', 'cv', 'tir', 'below70', 'below54', 'above180', 'above250'].map(key => [key,
    typeof a.glucose[key] === 'number' && typeof b.glucose[key] === 'number' ? b.glucose[key] - a.glucose[key] : null
  ]))
  return {
    a, b, deltaBMinusA: delta,
    interpretation: 'Descriptive sample-based statistics, not time-weighted. Same filters and rounding as trio_get_history_stats (glucose >20 and <600 mg/dL). Percentage differences are percentage points. No causal attribution or therapy recommendation; inspect coverage and unequal durations.'
  }
}
