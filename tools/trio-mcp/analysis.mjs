// Statistics + daily Claude analysis for trio-mcp.
// All glucose values are mg/dL. Times are evaluated in the Mac's local time zone.

import { requestToolResult } from './providers.mjs'

const DAY = 24 * 3600 * 1000

// ---------- helpers ----------

const round = (v, d = 1) => (v === null || v === undefined || Number.isNaN(v) ? null : Math.round(v * 10 ** d) / 10 ** d)
const mean = (a) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : null)
function sd(a) {
  if (a.length < 2) return null
  const m = mean(a)
  return Math.sqrt(a.reduce((s, x) => s + (x - m) ** 2, 0) / (a.length - 1))
}
function quantile(sorted, q) {
  if (!sorted.length) return null
  const pos = (sorted.length - 1) * q
  const lo = Math.floor(pos)
  const hi = Math.ceil(pos)
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo)
}
const pct = (n, total) => (total ? round((100 * n) / total, 1) : null)
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

function glucoseStats(values) {
  const n = values.length
  if (!n) return { n: 0 }
  const m = mean(values)
  const s = sd(values)
  return {
    n,
    mean: round(m, 0),
    sd: round(s, 0),
    cv: s && m ? round((100 * s) / m, 1) : null,
    gmi: round(3.31 + 0.02392 * m, 1),
    tir: pct(values.filter((v) => v >= 70 && v <= 180).length, n),
    tightRange: pct(values.filter((v) => v >= 70 && v <= 140).length, n),
    below70: pct(values.filter((v) => v < 70).length, n),
    below54: pct(values.filter((v) => v < 54).length, n),
    above180: pct(values.filter((v) => v > 180).length, n),
    above250: pct(values.filter((v) => v > 250).length, n)
  }
}

// ---------- history storage ----------

export function mergeHistory(history, upload, now = Date.now()) {
  const cutoff = now - 30 * DAY
  const kinds = ['glucose', 'carbs', 'boluses', 'tempBasals', 'determinations', 'tdd']
  const out = { ...history }
  for (const kind of kinds) {
    const map = new Map()
    const keyOf = (e) => (kind === 'boluses' ? `${e.t}|${e.u}` : e.t)
    for (const e of history[kind] || []) map.set(keyOf(e), e)
    for (const e of upload[kind] || []) map.set(keyOf(e), e)
    out[kind] = [...map.values()].filter((e) => Date.parse(e.t) >= cutoff).sort((a, b) => Date.parse(a.t) - Date.parse(b.t))
  }
  out.updatedAt = new Date(now).toISOString()
  return out
}

export function historyThrough(history) {
  const g = history?.glucose
  return g && g.length ? g[g.length - 1].t : null
}

// ---------- statistics ----------

export function computeStats(history, now = Date.now()) {
  const glucose = (history.glucose || []).map((e) => ({ t: new Date(e.t), v: e.v })).filter((e) => e.v > 20 && e.v < 600)
  const dets = (history.determinations || []).map((e) => ({ ...e, t: new Date(e.t) }))
  const carbs = (history.carbs || []).map((e) => ({ ...e, t: new Date(e.t) }))
  const boluses = (history.boluses || []).map((e) => ({ ...e, t: new Date(e.t) }))

  const since = (days) => glucose.filter((e) => now - e.t.getTime() <= days * DAY).map((e) => e.v)
  const firstDate = glucose[0]?.t
  const coveredDays = firstDate ? round((now - firstDate.getTime()) / DAY, 1) : 0

  // per day
  const days = new Map()
  const ensure = (k) => {
    if (!days.has(k)) days.set(k, { date: k, glucose: [], carbs: 0, bolus: 0, smb: 0, tdd: null })
    return days.get(k)
  }
  for (const e of glucose) ensure(dayKey(e.t)).glucose.push(e.v)
  for (const c of carbs) if (!c.fpu) ensure(dayKey(c.t)).carbs += c.c || 0
  for (const b of boluses) {
    const d = ensure(dayKey(b.t))
    d.bolus += b.u || 0
    if (b.smb) d.smb += b.u || 0
  }
  for (const t of history.tdd || []) ensure(dayKey(new Date(t.t))).tdd = round(t.total, 1)
  const daily = [...days.values()]
    .sort((a, b) => a.date.localeCompare(b.date))
    .map((d) => ({
      date: d.date,
      ...glucoseStats(d.glucose),
      carbs: round(d.carbs, 0),
      bolus: round(d.bolus, 1),
      smb: round(d.smb, 1),
      tdd: d.tdd
    }))

  // per hour of day
  const hourly = Array.from({ length: 24 }, (_, h) => ({ hour: h, g: [], sens: [], tempDelta: [], isf: [], cr: [], hypos: 0 }))
  for (const e of glucose) hourly[e.t.getHours()].g.push(e.v)
  for (const d of dets) {
    const h = hourly[d.t.getHours()]
    if (typeof d.sens === 'number') h.sens.push(d.sens)
    if (typeof d.rate === 'number' && typeof d.basal === 'number' && d.enacted) h.tempDelta.push(d.rate - d.basal)
    if (typeof d.isf === 'number') h.isf.push(d.isf)
    if (typeof d.cr === 'number') h.cr.push(d.cr)
  }
  // hypo events: first value < 70 after >= 30 min above 70
  let lastLow = 0
  const hypoEvents = []
  for (const e of glucose) {
    if (e.v < 70 && e.t.getTime() - lastLow > 30 * 60 * 1000) {
      hypoEvents.push({ t: e.t.toISOString(), v: e.v })
      hourly[e.t.getHours()].hypos += 1
    }
    if (e.v < 70) lastLow = e.t.getTime()
  }
  const hourlyOut = hourly.map((h) => {
    const s = [...h.g].sort((a, b) => a - b)
    return {
      hour: h.hour,
      n: s.length,
      median: round(quantile(s, 0.5), 0),
      p10: round(quantile(s, 0.1), 0),
      p25: round(quantile(s, 0.25), 0),
      p75: round(quantile(s, 0.75), 0),
      p90: round(quantile(s, 0.9), 0),
      below70: pct(h.g.filter((v) => v < 70).length, h.g.length),
      above180: pct(h.g.filter((v) => v > 180).length, h.g.length),
      hypoEvents: h.hypos,
      avgSensitivityRatio: round(mean(h.sens), 2),
      avgTempMinusScheduled: round(mean(h.tempDelta), 2),
      avgIsfUsed: round(mean(h.isf), 0),
      avgCrUsed: round(mean(h.cr), 1)
    }
  })

  // meal responses (carbs >= 10 g)
  const meals = { breakfast: [], lunch: [], dinner: [], other: [] }
  const bgAt = (t) => {
    let best = null
    for (const e of glucose) {
      const dt = Math.abs(e.t.getTime() - t)
      if (dt <= 10 * 60 * 1000 && (!best || dt < best.dt)) best = { dt, v: e.v }
    }
    return best?.v ?? null
  }
  for (const c of carbs) {
    if (c.fpu || !(c.c >= 10)) continue
    const t0 = c.t.getTime()
    const start = bgAt(t0)
    const window = glucose.filter((e) => e.t.getTime() > t0 && e.t.getTime() <= t0 + 3 * 3600 * 1000).map((e) => e.v)
    if (start === null || window.length < 12) continue
    const h = c.t.getHours()
    const slot = h >= 5 && h < 11 ? 'breakfast' : h >= 11 && h < 15 ? 'lunch' : h >= 17 && h < 22 ? 'dinner' : 'other'
    meals[slot].push({ carbs: c.c, start, peakRise: Math.max(...window) - start, after3h: bgAt(t0 + 3 * 3600 * 1000), min: Math.min(...window) })
  }
  const mealSummary = Object.fromEntries(
    Object.entries(meals).map(([slot, list]) => [slot, {
      n: list.length,
      avgCarbs: round(mean(list.map((m) => m.carbs)), 0),
      avgPeakRise: round(mean(list.map((m) => m.peakRise)), 0),
      avgDelta3h: round(mean(list.filter((m) => m.after3h !== null).map((m) => m.after3h - m.start)), 0),
      lowsWithin3h: list.filter((m) => m.min < 70).length
    }])
  )

  const tddValues = (history.tdd || []).map((t) => t.total).filter((v) => v > 0)

  return {
    generatedAt: new Date(now).toISOString(),
    coveredDays,
    readings: glucose.length,
    overall30d: glucoseStats(since(30)),
    last14d: glucoseStats(since(14)),
    last7d: glucoseStats(since(7)),
    last24h: glucoseStats(since(1)),
    avgTdd: round(mean(tddValues), 1),
    avgDailyCarbs: round(mean(daily.map((d) => d.carbs).filter((v) => v > 0)), 0),
    hypoEventCount: hypoEvents.length,
    recentHypoEvents: hypoEvents.slice(-15),
    daily,
    hourly: hourlyOut,
    meals: mealSummary
  }
}

// ---------- Claude analysis ----------

const SYSTEM_PROMPT = `Du bist ein sehr vorsichtiger Analyse-Assistent für eine Person mit Typ-1-Diabetes, die das Open-Source-AID-System Trio (oref-Algorithmus) nutzt.
Du erhältst aggregierte Statistiken der letzten bis zu 30 Tage sowie die aktuellen Trio-Einstellungen.
Deine Aufgabe: einen kurzen Tagesbericht auf Deutsch schreiben und – nur wenn die Daten es klar stützen – konkrete Einstellungsänderungen vorschlagen.

Regeln für Vorschläge:
- Jeder Vorschlag wird vom Nutzer einzeln geprüft und am iPhone mit Face ID freigegeben. Trotzdem: konservativ bleiben.
- Nur Muster, die an mindestens 3 verschiedenen Tagen auftreten, rechtfertigen eine Änderung. Bei weniger als 7 Tagen Daten keine Therapie-Änderungen vorschlagen.
- Basal, ISF und KH-Faktor pro Schritt um höchstens 10 % ändern (an einzelnen Zeitblöcken), Zielwerte um höchstens 10 mg/dL.
- Maximal 2 Therapie-Vorschläge pro Tag. Hypoglykämien haben Vorrang: zuerst Unterzuckerungen reduzieren, dann Hyperglykämien.
- Keine Vorschläge, die die Insulinabgabe erhöhen, wenn in demselben Zeitfenster Werte < 70 mg/dL gehäuft vorkommen.
- Keine Boli, keine Mahlzeiten, keine Änderungen an Pumpen-/Sensor-Konfiguration oder Sicherheitslimits nach oben (maxIOB, maxSMBBasalMinutes, maxDailySafetyMultiplier etc.), außer der Nutzer hat es ausdrücklich gewünscht.
- Zeitpläne immer vollständig angeben (alle 24 h), Einträge ab 00:00 in 30-Minuten-Schritten, Werte in mg/dL bzw. g/IE bzw. IE/h. Unveränderte Blöcke unverändert übernehmen. Basalraten nur aus supportedBasalRates.
- Für settings/preferences nur Schlüssel verwenden, die im Snapshot existieren, mit gleichem Typ.
- In "reason" die Evidenz mit Zahlen nennen (z. B. "an 9 von 14 Tagen zwischen 3 und 6 Uhr Median 165 mg/dL, Loop erhöht dort im Mittel um +0,25 IE/h").
- Datenqualität prüfen (Lücken, wenige Messwerte, Sensorwechsel) und bei Zweifeln keine Vorschläge machen.
Wenn nichts geändert werden sollte, gib eine leere proposals-Liste zurück – das ist ein gutes Ergebnis.`

const ANALYSIS_TOOL = {
  name: 'submit_analysis',
  description: 'Submit the daily analysis report and optional setting proposals.',
  input_schema: {
    type: 'object',
    properties: {
      summary: { type: 'string', description: 'Tagesbericht auf Deutsch, 3-8 Sätze, Markdown erlaubt' },
      highlights: { type: 'array', items: { type: 'string' }, description: 'Kurze Stichpunkte (positiv und negativ)' },
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            title: { type: 'string' },
            detail: { type: 'string' },
            severity: { type: 'string', enum: ['info', 'warn', 'critical'] }
          },
          required: ['title', 'detail', 'severity']
        }
      },
      proposals: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            target: { type: 'string', enum: ['settings', 'preferences', 'basal_profile', 'isf', 'carb_ratios', 'bg_targets'] },
            changes: { type: 'object', description: 'Nur für settings/preferences: key → neuer Wert' },
            schedule: {
              type: 'array',
              description: 'Nur für Zeitpläne: vollständiger 24h-Plan',
              items: {
                type: 'object',
                properties: { time: { type: 'string' }, value: { type: 'number' }, low: { type: 'number' }, high: { type: 'number' } },
                required: ['time']
              }
            },
            reason: { type: 'string' }
          },
          required: ['target', 'reason']
        }
      }
    },
    required: ['summary', 'findings', 'proposals']
  }
}

/// Values of a Trio schedule as [{minutes, value}] for the relative-change guard.
function currentSchedule(state, target, field = 'low') {
  const toMin = (s) => {
    const [h, m] = String(s).split(':').map(Number)
    return h * 60 + (m || 0)
  }
  if (target === 'basal_profile') return (state.basalProfile || []).map((e) => ({ minutes: e.minutes ?? toMin(e.start), value: e.rate }))
  if (target === 'isf') return (state.isf?.sensitivities || []).map((e) => ({ minutes: e.offset ?? toMin(e.start), value: e.sensitivity }))
  if (target === 'carb_ratios') return (state.carbRatios?.schedule || []).map((e) => ({ minutes: e.offset ?? toMin(e.start), value: e.ratio }))
  if (target === 'bg_targets') return (state.bgTargets?.targets || []).map((e) => ({ minutes: e.offset ?? toMin(e.start), value: e[field] ?? e.low }))
  return []
}

const valueAt = (list, minute) => [...list].sort((a, b) => a.minutes - b.minutes).filter((e) => e.minutes <= minute).pop()?.value

/// Hard guard for automatically generated proposals: no step larger than maxStep relative to the current value.
export function checkStepSize(state, proposal, maxStep = 0.2) {
  if (proposal.schedule) {
    if (!Array.isArray(proposal.schedule) || !proposal.schedule.length) return 'Ungültiger Zeitplan'
    const fields = proposal.target === 'bg_targets' ? ['low', 'high'] : ['value']
    for (const field of fields) {
      const current = currentSchedule(state, proposal.target, field)
      if (!current.length) return 'Kein aktueller Vergleichszeitplan vorhanden'
      const proposed = proposal.schedule.map((e) => {
        const [h, m] = String(e.time).split(':').map(Number)
        return { minutes: h * 60 + m, value: e[field] ?? e.low ?? e.value }
      })
      for (let minute = 0; minute < 1440; minute += 30) {
        const before = valueAt(current, minute)
        const after = valueAt(proposed, minute)
        if (!Number.isFinite(before) || !Number.isFinite(after) || before < 0 || after < 0) return 'Zeitplan kann nicht sicher verglichen werden'
        if (before === 0 && after !== 0) return 'Änderung ausgehend von 0 kann nicht prozentual begrenzt werden'
        if (before > 0 && Math.abs(after - before) / before > maxStep + 1e-9) {
          return `Änderung um ${Math.round((100 * Math.abs(after - before)) / before)} % um ${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')} überschreitet ${Math.round(maxStep * 100)} %`
        }
      }
    }
  }
  if (proposal.changes) {
    const section = state[proposal.target] || {}
    for (const [key, value] of Object.entries(proposal.changes)) {
      const before = Object.hasOwn(section, key) ? section[key]
        : state.settingsCatalog?.find(row => row.target === proposal.target && row.key === key && row.access === 'proposal')?.current
      if (typeof before === 'number' && typeof value === 'number') {
        if (!Number.isFinite(before) || !Number.isFinite(value)) return `"${key}" muss endlich sein`
        if (before === 0 && value !== 0) return `"${key}" kann ausgehend von 0 nicht prozentual begrenzt werden`
        if (before !== 0 && Math.abs(value - before) / Math.abs(before) > 0.3 + 1e-9) return `"${key}" ändert sich um mehr als 30 %`
      }
    }
  }
  return null
}

const SCHEDULE_TARGETS = ['basal_profile', 'isf', 'carb_ratios', 'bg_targets']

function proposalTargets(state) {
  const patchTargets = Array.isArray(state.settingsCatalog)
    ? state.settingsCatalog.filter(row => row?.access === 'proposal' && typeof row.target === 'string').map(row => row.target)
    : ['settings', 'preferences']
  return [...new Set([...patchTargets, ...SCHEDULE_TARGETS])]
}

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const isText = value => typeof value === 'string' && value.trim().length > 0

export function validateAnalysisResult(input, state = {}) {
  if (!isObject(input) || !isText(input.summary) || !Array.isArray(input.findings) || !Array.isArray(input.proposals)) {
    throw new Error('Invalid analysis: summary, findings and proposals are required')
  }
  if (input.highlights !== undefined && (!Array.isArray(input.highlights) || input.highlights.some(item => typeof item !== 'string'))) {
    throw new Error('Invalid analysis highlights')
  }
  if (input.findings.some(item => !isObject(item) || !isText(item.title) || !isText(item.detail) || !['info', 'warn', 'critical'].includes(item.severity))) {
    throw new Error('Invalid analysis findings')
  }
  const targets = proposalTargets(state)
  for (const proposal of input.proposals) {
    if (!isObject(proposal) || !targets.includes(proposal.target) || !isText(proposal.reason)) throw new Error('Invalid analysis proposal target or reason')
    if (SCHEDULE_TARGETS.includes(proposal.target)) {
      if (!Array.isArray(proposal.schedule) || !proposal.schedule.length || proposal.schedule.some(entry =>
        !isObject(entry) || typeof entry.time !== 'string' || ['value', 'low', 'high'].some(key => entry[key] !== undefined && !Number.isFinite(entry[key]))
      )) throw new Error('Invalid analysis proposal schedule')
    } else if (!isObject(proposal.changes) || !Object.keys(proposal.changes).length) {
      throw new Error('Invalid analysis proposal changes')
    }
  }
  return { summary: input.summary, highlights: input.highlights ?? [], findings: input.findings, proposals: input.proposals }
}

export async function runAIAnalysis({ config, state, stats, previousReports = [] }) {
  const payload = {
    today: new Date().toISOString(),
    units: 'mg/dL',
    stats,
    currentSettings: {
      settings: state.settings,
      preferences: state.preferences,
      basalProfile: state.basalProfile,
      isf: state.isf,
      carbRatios: state.carbRatios,
      bgTargets: state.bgTargets,
      supportedBasalRates: state.supportedBasalRates,
      pump: state.pump,
      settingsCatalog: state.settingsCatalog
    },
    recentDecisions: previousReports.slice(-7).map((r) => ({
      date: r.createdAt,
      proposals: (r.proposals || []).map((p) => ({ target: p.target, reason: p.reason, status: p.status }))
    }))
  }
  const tool = structuredClone(ANALYSIS_TOOL)
  tool.input_schema.properties.proposals.items.properties.target.enum = proposalTargets(state)
  const result = await requestToolResult({
    config, system: SYSTEM_PROMPT, tool,
    prompt: 'Analysiere bitte meine Trio-Daten:\n\n' + JSON.stringify(payload)
  })
  return { ...validateAnalysisResult(result.input, state), provider: result.provider, model: result.model, usage: result.usage }
}

export async function runClaudeAnalysis({ apiKey, model, state, stats, previousReports = [] }) {
  return runAIAnalysis({ config: { provider: 'anthropic', providers: { anthropic: { apiKey, model } } }, state, stats, previousReports })
}
