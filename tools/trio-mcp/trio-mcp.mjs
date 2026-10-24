#!/usr/bin/env node
// trio-mcp — relay between Trio (iPhone) and AI clients (MCP).
//
//   node trio-mcp.mjs serve            HTTP relay for the iPhone (run permanently, e.g. via launchd)
//   node trio-mcp.mjs mcp              MCP server over stdio (started by Claude Desktop / Claude Code)
//   node trio-mcp.mjs info             Print URL + token to enter in Trio
//   node trio-mcp.mjs install-launchd  Start the relay automatically at login (macOS)
//   node trio-mcp.mjs set-api-key      Store the selected provider API key for the daily analysis
//   node trio-mcp.mjs set-time 07:00   Time of the daily analysis (local time, default 07:00)
//   node trio-mcp.mjs analyze          Run the analysis now
//
// Companion web app: http://<mac-ip>:8765/app?token=<token>  (add to iPhone home screen)
//
// Safety model: AI clients can read Trio's snapshot and create PROPOSALS. Nothing is changed in Trio
// until the user reviews the proposal on the iPhone and approves it with Face ID.

import { randomBytes, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'
import { checkStepSize, computeStats, historyThrough, mergeHistory, runAIAnalysis } from './analysis.mjs'
import { AI_PROVIDERS, AI_PROVIDER_DEFAULTS, aiConfigurationStatus, normalizeBaseURL } from './providers.mjs'
import { validateSettingsPatch } from './settings.mjs'
import { patchRelaySettings, relaySettings, withRelayCatalog } from './relay-settings.mjs'

const HOME = os.homedir()
const DIR = process.env.TRIO_MCP_DIR || path.join(HOME, '.trio-mcp')
const CONFIG_FILE = path.join(DIR, 'config.json')
const DB_FILE = path.join(DIR, 'db.json')
const HISTORY_FILE = path.join(DIR, 'history.json')
const APP_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'app.html')
const SCHEDULE_TARGETS = ['basal_profile', 'isf', 'carb_ratios', 'bg_targets']

// ---------- config / storage ----------

function loadConfig() {
  fs.mkdirSync(DIR, { recursive: true, mode: 0o700 })
  let config = {}
  try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) } catch {}
  let changed = false
  if (!config.token) { config.token = randomBytes(24).toString('base64url'); changed = true }
  if (!config.port) { config.port = Number(process.env.TRIO_MCP_PORT) || 8765; changed = true }
  if (!config.analysisTime) { config.analysisTime = '07:00'; changed = true }
  if (!config.model) { config.model = 'claude-sonnet-4-5'; changed = true }
  if (changed) saveConfig(config)
  return config
}

function saveConfig(config) {
  fs.mkdirSync(DIR, { recursive: true, mode: 0o700 })
  const tmp = CONFIG_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), { mode: 0o600 })
  fs.chmodSync(tmp, 0o600)
  fs.renameSync(tmp, CONFIG_FILE)
}

function loadHistory() {
  try { return JSON.parse(fs.readFileSync(HISTORY_FILE, 'utf8')) } catch { return {} }
}

function saveHistory(history) {
  const tmp = HISTORY_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(history), { mode: 0o600 })
  fs.renameSync(tmp, HISTORY_FILE)
}

function loadDB() {
  let db
  try { db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8')) } catch { db = {} }
  db = { state: null, stateReceivedAt: null, proposals: [], reports: [], ...db }
  const proposals = new Map(db.proposals.map((p) => [p.id, p]))
  for (const report of db.reports) {
    report.proposals = (report.proposals || []).map((p) => {
      const current = proposals.get(p.id)
      return current ? { ...p, status: current.status, resultMessage: current.resultMessage, resolvedAt: current.resolvedAt } : p
    })
  }
  return db
}

function saveDB(db) {
  const tmp = DB_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2), { mode: 0o600 })
  fs.renameSync(tmp, DB_FILE)
}

function lanAddresses() {
  return Object.values(os.networkInterfaces()).flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address)
}

// ---------- validation ----------

function validatePatch(db, target, changes) {
  validateSettingsPatch(withRelayCatalog(db.state, loadConfig()), target, changes)
  if (target === 'relay_config') patchRelaySettings(loadConfig(), changes)
}

function validateSchedule(target, schedule) {
  if (!Array.isArray(schedule) || !schedule.length) throw new Error('schedule must be a non-empty array')
  let last = -1
  schedule.forEach((e, i) => {
    const m = /^(\d{1,2}):(\d{2})$/.exec(String(e.time ?? ''))
    if (!m) throw new Error(`entry ${i}: time must be "HH:MM"`)
    const minutes = Number(m[1]) * 60 + Number(m[2])
    if (Number(m[1]) > 23 || Number(m[2]) > 59 || minutes % 30 !== 0) throw new Error(`entry ${i}: time must be on a 30-minute boundary`)
    if (i === 0 && minutes !== 0) throw new Error('first entry must start at 00:00')
    if (minutes <= last) throw new Error('times must be strictly ascending')
    last = minutes
    if (target === 'bg_targets') {
      const low = e.low ?? e.value
      const high = e.high ?? low
      if (!Number.isFinite(low) || !Number.isFinite(high) || !(low > 0) || !(high >= low)) throw new Error(`entry ${i}: need finite low > 0 and high >= low (mg/dL)`)
    } else if (!Number.isFinite(e.value) || !(e.value > 0)) {
      throw new Error(`entry ${i}: value must be > 0`)
    }
  })
}

function createProposal(db, body, origin = 'ai-chat') {
  if (SCHEDULE_TARGETS.includes(body.target)) validateSchedule(body.target, body.schedule)
  else validatePatch(db, body.target, body.patch)
  let relayBefore
  let effectivePatch = body.patch
  if (body.target === 'relay_config') {
    const config = loadConfig()
    relayBefore = relaySettings(config)
    const after = relaySettings(patchRelaySettings(config, body.patch))
    // Switching providers also switches their saved model/URL; preview the complete effective change.
    effectivePatch = Object.fromEntries(Object.entries(after).filter(([key, value]) => value !== relayBefore[key]))
    if (!Object.keys(effectivePatch).length) throw new Error('No relay settings changed')
  }
  const proposal = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    origin,
    target: body.target,
    patch: effectivePatch ?? null,
    schedule: body.schedule ?? null,
    reason: String(body.reason || '').slice(0, 800),
    status: 'pending'
  }
  if (relayBefore) proposal.oldValues = relayBefore
  db.proposals.push(proposal)
  return proposal
}

// ---------- daily analysis ----------

let analysisRunning = false

async function analyze(trigger = 'manual') {
  if (analysisRunning) throw new Error('Analysis already running')
  analysisRunning = true
  try {
    const config = loadConfig()
    const ai = aiConfigurationStatus(config)
    if (!ai.ready) throw new Error(ai.error || 'Configure provider, model, endpoint and API key on the Mac first.')
    const input = loadDB()
    if (!input.state) throw new Error('Trio has not synced yet')
    const stats = computeStats(loadHistory())
    const result = await runAIAnalysis({ config, state: withRelayCatalog(input.state, config), stats, previousReports: input.reports })
    // Syncs and iPhone decisions can arrive while the model is running.
    const db = loadDB()
    const today = new Date().toDateString()
    let proposalsToday = db.proposals.filter((p) => p.origin === 'daily-analysis' && new Date(p.createdAt).toDateString() === today).length

    // withdraw older, still pending automatic proposals
    for (const p of db.proposals) {
      if (p.status === 'pending' && p.origin === 'daily-analysis') {
        p.status = 'cancelled'
        p.resolvedAt = new Date().toISOString()
        p.resultMessage = 'Durch neue Tagesanalyse ersetzt'
      }
    }
    const proposals = []
    for (const raw of result.proposals || []) {
      const body = { target: raw.target, patch: raw.changes ?? null, schedule: raw.schedule ?? null, reason: raw.reason }
      const guard = stats.coveredDays < 7 || stats.daily.filter((d) => d.n > 0).length < 7
        ? 'Mindestens 7 Tage mit Glukosedaten erforderlich'
        : proposalsToday >= 2 ? 'Maximal 2 automatische Therapie-Vorschläge pro Tag'
          : checkStepSize(db.state, { target: raw.target, changes: raw.changes, schedule: raw.schedule })
      if (guard) { proposals.push({ ...body, status: 'blocked', resultMessage: guard }); continue }
      try {
        const p = createProposal(db, body, 'daily-analysis')
        proposalsToday++
        proposals.push({ id: p.id, ...body, status: 'pending' })
      } catch (e) {
        proposals.push({ ...body, status: 'blocked', resultMessage: e.message })
      }
    }
    const report = {
      id: randomUUID(),
      createdAt: new Date().toISOString(),
      trigger,
      provider: ai.provider,
      model: result.model,
      summary: result.summary,
      highlights: result.highlights || [],
      findings: result.findings || [],
      proposals,
      statsHeadline: { coveredDays: stats.coveredDays, overall30d: stats.overall30d, last7d: stats.last7d, avgTdd: stats.avgTdd }
    }
    db.reports = [...(db.reports || []), report].slice(-60)
    db.lastAnalysisDate = new Date().toDateString()
    db.lastAnalysisError = null
    saveDB(db)
    return report
  } finally {
    analysisRunning = false
  }
}

function startScheduler() {
  setInterval(() => {
    const config = loadConfig()
    if (!aiConfigurationStatus(config).ready || analysisRunning) return
    const now = new Date()
    const [h, m] = String(config.analysisTime || '07:00').split(':').map(Number)
    const due = now.getHours() > h || (now.getHours() === h && now.getMinutes() >= m)
    const db = loadDB()
    if (due && db.lastAnalysisDate !== now.toDateString() && db.state) {
      analyze('daily').then(
        (r) => console.error(`Daily analysis done: ${r.proposals.length} proposal(s)`),
        (e) => {
          console.error('Daily analysis failed:', e.message)
          const d = loadDB()
          d.lastAnalysisDate = now.toDateString()
          d.lastAnalysisError = e.message
          saveDB(d)
        }
      )
    }
  }, 60 * 1000)
}

// ---------- HTTP relay (serve) ----------

function serve() {
  const config = loadConfig()
  const send = (res, code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  const readBody = (req) => new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (c) => { data += c; if (data.length > 60e6) req.destroy() })
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}) } catch (e) { reject(e) } })
    req.on('error', reject)
  })

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://local')
      const cookieToken = /(?:^|;\s*)trio_token=([^;]+)/.exec(req.headers.cookie || '')?.[1]
      const authorized = (req.headers.authorization || '') === `Bearer ${config.token}` ||
        cookieToken === config.token || url.searchParams.get('token') === config.token
      if (!authorized) return send(res, 401, { error: 'unauthorized' })

      // --- companion web app ---
      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/app')) {
        res.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Set-Cookie': `trio_token=${config.token}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict`
        })
        return res.end(fs.readFileSync(APP_FILE, 'utf8'))
      }
      const parts = url.pathname.split('/').filter(Boolean)
      const body = req.method === 'POST' ? await readBody(req) : null
      const db = loadDB()

      // --- endpoints used by Trio ---
      if (req.method === 'POST' && url.pathname === '/trio/state') {
        db.state = body
        db.stateReceivedAt = new Date().toISOString()
        saveDB(db)
        return send(res, 200, { ok: true, historyThrough: historyThrough(loadHistory()) })
      }
      if (req.method === 'POST' && url.pathname === '/trio/history') {
        const merged = mergeHistory(loadHistory(), body)
        saveHistory(merged)
        return send(res, 200, { ok: true, historyThrough: historyThrough(merged), glucose: merged.glucose.length })
      }
      if (req.method === 'GET' && url.pathname === '/trio/proposals') {
        const status = url.searchParams.get('status')
        return send(res, 200, db.proposals.filter((p) => !status || p.status === status))
      }
      if (req.method === 'POST' && parts[0] === 'trio' && parts[1] === 'proposals' && parts[3] === 'claim') {
        const p = db.proposals.find(x => x.id === parts[2])
        if (!p) return send(res, 404, { error: 'not found' })
        if (p.status !== 'pending') return send(res, 409, { error: `proposal is already ${p.status}` })
        if (p.target === 'relay_config' && JSON.stringify(relaySettings(loadConfig())) !== JSON.stringify(p.oldValues)) {
          return send(res, 409, { error: 'Relay settings changed; create and review a new proposal.' })
        }
        p.status = 'applying'
        p.claimedAt = new Date().toISOString()
        saveDB(db)
        return send(res, 200, { ok: true })
      }
      if (req.method === 'POST' && parts[0] === 'trio' && parts[1] === 'proposals' && parts[3] === 'result') {
        const p = db.proposals.find((x) => x.id === parts[2])
        if (!p) return send(res, 404, { error: 'not found' })
        if (!['applied', 'rejected', 'failed'].includes(body.status)) return send(res, 400, { error: 'bad status' })
        if (p.status === body.status) return send(res, 200, { ok: true })
        if (!['pending', 'applying'].includes(p.status)) return send(res, 409, { error: `proposal is already ${p.status}` })
        if (p.target === 'relay_config' && body.status === 'applied') {
          const current = loadConfig()
          try {
            if (JSON.stringify(relaySettings(current)) !== JSON.stringify(p.oldValues)) throw new Error('Relay settings changed since this proposal. Create and review a new proposal.')
            saveConfig(patchRelaySettings(current, p.patch))
          } catch (error) {
            Object.assign(p, { status: 'failed', resultMessage: error.message, resolvedAt: new Date().toISOString() })
            saveDB(db)
            return send(res, 409, { error: error.message })
          }
        }
        Object.assign(p, { status: body.status, resultMessage: body.message ?? '', resolvedAt: body.at ?? new Date().toISOString() })
        saveDB(db)
        return send(res, 200, { ok: true })
      }

      // --- endpoints used by the MCP side ---
      if (req.method === 'GET' && url.pathname === '/api/state') {
        return send(res, 200, { state: withRelayCatalog(db.state, loadConfig()), stateReceivedAt: db.stateReceivedAt })
      }
      if (req.method === 'GET' && url.pathname === '/api/proposals') {
        const status = url.searchParams.get('status')
        return send(res, 200, db.proposals.filter((p) => !status || p.status === status).slice(-50))
      }
      if (req.method === 'POST' && url.pathname === '/api/proposals') {
        const proposal = createProposal(db, body)
        saveDB(db)
        return send(res, 200, proposal)
      }
      if (req.method === 'GET' && url.pathname === '/api/stats') {
        return send(res, 200, computeStats(loadHistory()))
      }
      if (req.method === 'GET' && url.pathname === '/api/reports') {
        return send(res, 200, (db.reports || []).slice(-30).reverse())
      }
      if (req.method === 'GET' && url.pathname === '/api/overview') {
        const cfg = loadConfig()
        return send(res, 200, {
          state: db.state ? { status: db.state.status, units: db.state.units, version: db.state.version, pump: db.state.pump } : null,
          stateReceivedAt: db.stateReceivedAt,
          history: { through: historyThrough(loadHistory()) },
          latestReport: (db.reports || []).at(-1) || null,
          proposals: db.proposals.slice(-30).reverse(),
          analysis: { time: cfg.analysisTime, ...aiConfigurationStatus(cfg), running: analysisRunning, lastError: db.lastAnalysisError || null }
        })
      }
      if (req.method === 'POST' && url.pathname === '/api/analyze') {
        return send(res, 200, await analyze('manual'))
      }
      if (req.method === 'POST' && parts[0] === 'api' && parts[1] === 'proposals' && parts[3] === 'cancel') {
        const p = db.proposals.find((x) => x.id === parts[2])
        if (!p) return send(res, 404, { error: 'not found' })
        if (p.status !== 'pending') return send(res, 409, { error: `proposal is already ${p.status}` })
        p.status = 'cancelled'
        p.resolvedAt = new Date().toISOString()
        saveDB(db)
        return send(res, 200, p)
      }
      return send(res, 404, { error: 'not found' })
    } catch (e) {
      return send(res, 400, { error: e.message })
    }
  })

  startScheduler()
  server.listen(config.port, '0.0.0.0', () => {
    console.error(`trio-mcp relay listening on port ${config.port}`)
    for (const ip of lanAddresses()) console.error(`  Trio URL: http://${ip}:${config.port}`)
  })
}

// All clients use the relay so only one process writes the database and runs analyses.
async function api(pathname, options = {}) {
  const config = loadConfig()
  let res
  try {
    res = await fetch(`http://127.0.0.1:${config.port}${pathname}`, {
      ...options,
      headers: { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json', ...(options.headers || {}) }
    })
  } catch {
    throw new Error('trio-mcp relay is not running on this Mac. Start it with: node trio-mcp.mjs serve')
  }
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`)
  return body
}

// ---------- MCP server (stdio) ----------

async function mcp() {
  const { McpServer } = await import('@modelcontextprotocol/sdk/server/mcp.js')
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js')
  const { z } = await import('zod')
  const text = (obj) => ({ content: [{ type: 'text', text: typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2) }] })
  const guard = (fn) => async (args) => {
    try { return await fn(args) } catch (e) { return { ...text(`Error: ${e.message}`), isError: true } }
  }
  const ageMinutes = (iso) => iso ? Math.round((Date.now() - Date.parse(iso)) / 60000) : null

  const server = new McpServer({ name: 'trio', version: '0.1.0' })

  server.tool(
    'trio_get_status',
    'Current Trio status from the last iPhone sync: glucose, trend, delta, IOB, COB, last loop time, app version, and how old the snapshot is.',
    {},
    guard(async () => {
      const { state, stateReceivedAt } = await api('/api/state')
      if (!state) return text('Trio has not synced yet. Enable the KI-Bridge in Trio → Settings → KI.')
      return text({
        snapshotAgeMinutes: ageMinutes(stateReceivedAt),
        units: state.units,
        status: state.status,
        pump: state.pump,
        app: `${state.app} ${state.version} (${state.build})`
      })
    })
  )

  server.tool(
    'trio_get_settings',
    'Read Trio settings from the last iPhone sync. Use trio_get_settings_catalog to discover every available target/key, type, constraints and local actions. Section can be all or any catalog target. Schedules use mg/dL internally.',
    { section: z.string().default('all') },
    guard(async ({ section }) => {
      const { state, stateReceivedAt } = await api('/api/state')
      if (!state) return text('Trio has not synced yet.')
      const map = {
        settings: state.settings,
        preferences: state.preferences,
        basal_profile: state.basalProfile,
        isf: state.isf,
        carb_ratios: state.carbRatios,
        bg_targets: state.bgTargets,
        pump: { pumpSettings: state.pumpSettings, supportedBasalRates: state.supportedBasalRates, pump: state.pump }
      }
      for (const row of state.settingsCatalog || []) {
        if (row.access === 'proposal' && !SCHEDULE_TARGETS.includes(row.target)) {
          map[row.target] = { ...map[row.target], [row.key]: row.current }
        }
      }
      if (section !== 'all' && !Object.hasOwn(map, section)) throw new Error('Unknown settings section; read trio_get_settings_catalog first.')
      const data = section === 'all' ? { ...map, scheduleUnits: state.scheduleUnits } : map[section]
      return text({ snapshotAgeMinutes: ageMinutes(stateReceivedAt), section, data })
    })
  )

  server.tool(
    'trio_get_settings_catalog',
    'Discover Trio settings, current values, types, constraints and supported write paths. access=proposal means use trio_propose_settings_change and wait for local approval. action entries require the indicated local UI step; credentials and device pairing are never exported. Old app versions may have no catalog.',
    {},
    guard(async () => {
      const { state, stateReceivedAt } = await api('/api/state')
      return text({ snapshotAgeMinutes: ageMinutes(stateReceivedAt), catalog: state?.settingsCatalog || [], next: state?.settingsCatalog ? undefined : 'Sync the current Trio app to publish its settings catalog.' })
    })
  )

  server.tool(
    'trio_propose_settings_change',
    'Propose changing one or more keys in any writable settings catalog target. Read trio_get_settings_catalog first; keep the advertised types and constraints. Nested arrays/objects must be supplied as complete values. The change is NOT applied until the user reviews the diff and approves locally in Trio. Always explain the reason.',
    {
      target: z.string().min(1),
      changes: z.record(z.unknown()).describe('catalog key → new JSON value (including arrays/objects)'),
      reason: z.string().min(5).describe('Why this change is suggested (shown to the user)')
    },
    guard(async ({ target, changes, reason }) => {
      const p = await api('/api/proposals', { method: 'POST', body: JSON.stringify({ target, patch: changes, reason }) })
      return text({ proposal: p, next: 'Waiting for approval on the iPhone (Trio → Settings → KI). Check with trio_get_proposal.' })
    })
  )

  server.tool(
    'trio_propose_schedule',
    'Propose a complete replacement for a 24h schedule: basal_profile (value in U/h, must be a rate the pump supports), isf (value in mg/dL per U), carb_ratios (value in g per U) or bg_targets (low/high in mg/dL). Entries: [{time:"HH:MM", value}] or for bg_targets [{time, low, high}]; first entry 00:00, 30-minute steps, ascending. NOT applied until the user approves it with Face ID in Trio.',
    {
      target: z.enum(['basal_profile', 'isf', 'carb_ratios', 'bg_targets']),
      schedule: z.array(z.object({
        time: z.string().regex(/^\d{1,2}:\d{2}$/),
        value: z.number().positive().optional(),
        low: z.number().positive().optional(),
        high: z.number().positive().optional()
      })).min(1),
      reason: z.string().min(5)
    },
    guard(async ({ target, schedule, reason }) => {
      const p = await api('/api/proposals', { method: 'POST', body: JSON.stringify({ target, schedule, reason }) })
      return text({ proposal: p, next: 'Waiting for approval on the iPhone (Trio → Settings → KI).' })
    })
  )

  server.tool(
    'trio_list_proposals',
    'List recent proposals and their status (pending, applying, applied, rejected, failed, cancelled). applying means the iPhone has reserved the approved change; do not retry an uncertain hardware operation.',
    { status: z.enum(['pending', 'applying', 'applied', 'rejected', 'failed', 'cancelled']).optional() },
    guard(async ({ status }) => text(await api('/api/proposals' + (status ? `?status=${status}` : ''))))
  )

  server.tool(
    'trio_get_proposal',
    'Get one proposal including the result message reported by Trio after approval/rejection.',
    { id: z.string() },
    guard(async ({ id }) => {
      const list = await api('/api/proposals')
      const p = list.find((x) => x.id === id)
      return p ? text(p) : { ...text('Proposal not found'), isError: true }
    })
  )

  server.tool(
    'trio_cancel_proposal',
    'Withdraw a pending proposal so it no longer shows up in Trio.',
    { id: z.string() },
    guard(async ({ id }) => text(await api(`/api/proposals/${id}/cancel`, { method: 'POST' })))
  )

  server.tool(
    'trio_get_history_stats',
    'Aggregated statistics of the last up to 30 days from Trio: TIR/TBR/TAR, mean, CV, GMI per period and per day, hour-of-day glucose percentiles with loop adjustments (sensitivityRatio, temp basal minus scheduled basal), hypo events, meal responses, TDD. Use this before proposing therapy changes.',
    { include: z.enum(['summary', 'daily', 'hourly', 'meals', 'all']).default('all') },
    guard(async ({ include }) => {
      const stats = await api('/api/stats')
      if (include === 'all') return text(stats)
      const head = { coveredDays: stats.coveredDays, overall30d: stats.overall30d, last14d: stats.last14d, last7d: stats.last7d, last24h: stats.last24h, avgTdd: stats.avgTdd, hypoEventCount: stats.hypoEventCount }
      if (include === 'summary') return text(head)
      return text({ ...head, [include]: stats[include] })
    })
  )

  server.tool(
    'trio_get_daily_report',
    'Latest daily AI analysis report(s) created on the Mac, including findings and proposals with their status.',
    { count: z.number().int().min(1).max(10).default(1) },
    guard(async ({ count }) => text((await api('/api/reports')).slice(0, count)))
  )

  server.tool(
    'trio_run_daily_analysis',
    'Run the daily analysis now using the AI provider, model and credentials configured on the Mac. Creates a report and pending proposals for local approval in Trio.',
    {},
    guard(async () => text(await api('/api/analyze', { method: 'POST' })))
  )

  await server.connect(new StdioServerTransport())
}

// ---------- helpers ----------

function info() {
  const config = loadConfig()
  console.log('Enter this in Trio → Settings → KI:')
  for (const ip of lanAddresses()) console.log(`  Server: http://${ip}:${config.port}`)
  console.log(`  Token:  ${config.token}`)
  console.log('Companion web app (open on iPhone, then "Add to Home Screen"):')
  for (const ip of lanAddresses()) console.log(`  http://${ip}:${config.port}/app?token=${config.token}`)
}

function installLaunchd() {
  if (process.platform !== 'darwin') throw new Error('launchd is macOS only')
  const label = 'at.42bit.trio-mcp'
  const plistPath = path.join(HOME, 'Library', 'LaunchAgents', `${label}.plist`)
  const script = fileURLToPath(import.meta.url)
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array><string>${process.execPath}</string><string>${script}</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>${path.join(DIR, 'relay.log')}</string>
</dict></plist>
`
  loadConfig()
  fs.mkdirSync(path.dirname(plistPath), { recursive: true })
  fs.writeFileSync(plistPath, plist)
  try { execFileSync('launchctl', ['unload', plistPath], { stdio: 'ignore' }) } catch {}
  execFileSync('launchctl', ['load', plistPath])
  console.log(`Installed and started ${label}`)
  info()
}

async function setApiKey() {
  const config = loadConfig()
  const provider = config.provider || 'anthropic'
  const saved = providerSettings(config)
  const baseURL = normalizeBaseURL(provider, saved.baseURL || AI_PROVIDER_DEFAULTS[provider].baseURL)
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
  const key = await new Promise((resolve) => rl.question(`${AI_PROVIDER_DEFAULTS[provider].label} API key (empty removes it): `, resolve))
  rl.close()
  saved.apiKey = String(key).trim()
  saved.apiKeyBaseURL = baseURL
  saveConfig(config)
  console.log(saved.apiKey ? 'Saved for this provider and endpoint.' : 'Key removed.')
}

function providerSettings(config) {
  const provider = config.provider || 'anthropic'
  if (!AI_PROVIDERS.includes(provider)) throw new Error('Unknown AI provider')
  config.providers ||= {}
  config.providers[provider] ||= {}
  return config.providers[provider]
}

const command = process.argv[2]
if (command === 'serve') serve()
else if (command === 'set-api-key') setApiKey().catch(e => { console.error(e.message); process.exitCode = 1 })
else if (command === 'set-provider') {
  const provider = process.argv[3]
  if (!AI_PROVIDERS.includes(provider)) { console.error(`Usage: set-provider ${AI_PROVIDERS.join('|')}`); process.exit(1) }
  const config = loadConfig(); config.provider = provider; saveConfig(config); console.log(`Provider: ${provider}`)
}
else if (command === 'set-base-url') {
  try {
    const config = loadConfig()
    const provider = config.provider || 'anthropic'
    const baseURL = normalizeBaseURL(provider, process.argv[3])
    const saved = providerSettings(config)
    if (saved.baseURL !== baseURL && provider === 'openai-compatible') { delete saved.apiKey; delete saved.apiKeyBaseURL }
    saved.baseURL = baseURL
    saveConfig(config)
    console.log(`Base URL saved. ${provider === 'openai-compatible' ? 'Save the key again if the endpoint changed.' : ''}`)
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}
else if (command === 'provider-status') console.log(JSON.stringify(aiConfigurationStatus(loadConfig()), null, 2))
else if (command === 'set-time') {
  const value = process.argv[3]
  if (!/^(?:[01]?\d|2[0-3]):[0-5]\d$/.test(value || '')) { console.error('Usage: set-time HH:MM (00:00–23:59)'); process.exit(1) }
  const config = loadConfig(); config.analysisTime = value; saveConfig(config); console.log(`Daily analysis at ${value}`)
}
else if (command === 'set-model') {
  const model = process.argv[3]?.trim()
  if (!model) { console.error('Usage: set-model MODEL_ID'); process.exit(1) }
  const config = loadConfig(); providerSettings(config).model = model; saveConfig(config); console.log(`Model: ${model}`)
}
else if (command === 'analyze') api('/api/analyze', { method: 'POST' }).then((r) => console.log(JSON.stringify(r, null, 2)), (e) => { console.error(e.message); process.exit(1) })
else if (command === 'mcp') mcp().catch((e) => { console.error(e); process.exit(1) })
else if (command === 'info') info()
else if (command === 'install-launchd') installLaunchd()
else {
  console.error('Usage: node trio-mcp.mjs <serve|mcp|info|install-launchd|set-provider|set-base-url|set-api-key|set-time|set-model|provider-status|analyze>')
  process.exit(1)
}
