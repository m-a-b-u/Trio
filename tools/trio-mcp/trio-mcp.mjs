#!/usr/bin/env node
// trio-mcp — relay between Trio (iPhone) and Claude (MCP).
//
//   node trio-mcp.mjs serve            HTTP relay for the iPhone (run permanently, e.g. via launchd)
//   node trio-mcp.mjs mcp              MCP server over stdio (started by Claude Desktop / Claude Code)
//   node trio-mcp.mjs info             Print URL + token to enter in Trio
//   node trio-mcp.mjs install-launchd  Start the relay automatically at login (macOS)
//   node trio-mcp.mjs set-api-key      Store an Anthropic API key for the daily analysis
//   node trio-mcp.mjs set-time 07:00   Time of the daily analysis (local time, default 07:00)
//   node trio-mcp.mjs analyze          Run the analysis now
//
// Companion web app: http://<mac-ip>:8765/app?token=<token>  (add to iPhone home screen)
//
// Safety model: Claude can read Trio's snapshot and create PROPOSALS. Nothing is changed in Trio
// until the user reviews the proposal on the iPhone and approves it with Face ID.

import { randomBytes, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'
import { checkStepSize, computeStats, historyThrough, mergeHistory, runClaudeAnalysis } from './analysis.mjs'

const HOME = os.homedir()
const DIR = process.env.TRIO_MCP_DIR || path.join(HOME, '.trio-mcp')
const CONFIG_FILE = path.join(DIR, 'config.json')
const DB_FILE = path.join(DIR, 'db.json')
const HISTORY_FILE = path.join(DIR, 'history.json')
const APP_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'app.html')
const SCHEDULE_TARGETS = ['basal_profile', 'isf', 'carb_ratios', 'bg_targets']
const PATCH_TARGETS = ['settings', 'preferences']

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
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 })
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
  return { state: null, stateReceivedAt: null, proposals: [], reports: [], ...db }
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

function typeOf(v) { return v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v }

function validatePatch(db, target, changes) {
  if (!changes || typeof changes !== 'object' || Array.isArray(changes) || !Object.keys(changes).length) {
    throw new Error('changes must be a non-empty object of key → value')
  }
  const section = db.state?.[target]
  if (!section) throw new Error(`No ${target} snapshot from Trio yet – open Trio so it can sync first.`)
  const issues = []
  for (const [key, value] of Object.entries(changes)) {
    if (!(key in section)) { issues.push(`unknown key "${key}"`); continue }
    const current = section[key]
    if (current !== null && typeOf(current) !== typeOf(value)) {
      issues.push(`"${key}" must be ${typeOf(current)} (current value ${JSON.stringify(current)})`)
    }
    if (typeof value === 'number' && !Number.isFinite(value)) issues.push(`"${key}" must be finite`)
  }
  if (issues.length) throw new Error('Invalid proposal: ' + issues.join('; '))
}

function validateSchedule(target, schedule) {
  if (!Array.isArray(schedule) || !schedule.length) throw new Error('schedule must be a non-empty array')
  let last = -1
  schedule.forEach((e, i) => {
    const m = /^(\d{1,2}):(\d{2})$/.exec(String(e.time ?? ''))
    if (!m) throw new Error(`entry ${i}: time must be "HH:MM"`)
    const minutes = Number(m[1]) * 60 + Number(m[2])
    if (minutes >= 1440 || minutes % 30 !== 0) throw new Error(`entry ${i}: time must be on a 30-minute boundary`)
    if (i === 0 && minutes !== 0) throw new Error('first entry must start at 00:00')
    if (minutes <= last) throw new Error('times must be strictly ascending')
    last = minutes
    if (target === 'bg_targets') {
      const low = e.low ?? e.value
      const high = e.high ?? low
      if (!(low > 0) || !(high >= low)) throw new Error(`entry ${i}: need low > 0 and high >= low (mg/dL)`)
    } else if (!(e.value > 0)) {
      throw new Error(`entry ${i}: value must be > 0`)
    }
  })
}

function createProposal(db, body, origin = 'claude') {
  if (PATCH_TARGETS.includes(body.target)) validatePatch(db, body.target, body.patch)
  else if (SCHEDULE_TARGETS.includes(body.target)) validateSchedule(body.target, body.schedule)
  else throw new Error(`target must be one of ${[...PATCH_TARGETS, ...SCHEDULE_TARGETS].join(', ')}`)
  const proposal = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    origin,
    target: body.target,
    patch: body.patch ?? null,
    schedule: body.schedule ?? null,
    reason: String(body.reason || '').slice(0, 800),
    status: 'pending'
  }
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
    if (!config.anthropicApiKey) throw new Error('No Anthropic API key. Run: node trio-mcp.mjs set-api-key')
    const db = loadDB()
    if (!db.state) throw new Error('Trio has not synced yet')
    const stats = computeStats(loadHistory())
    const result = await runClaudeAnalysis({ apiKey: config.anthropicApiKey, model: config.model, state: db.state, stats, previousReports: db.reports })

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
      const guard = checkStepSize(db.state, { target: raw.target, changes: raw.changes, schedule: raw.schedule })
      if (guard) { proposals.push({ ...body, status: 'blocked', resultMessage: guard }); continue }
      try {
        const p = createProposal(db, body, 'daily-analysis')
        proposals.push({ id: p.id, ...body, status: 'pending' })
      } catch (e) {
        proposals.push({ ...body, status: 'blocked', resultMessage: e.message })
      }
    }
    const report = {
      id: randomUUID(),
      createdAt: new Date().toISOString(),
      trigger,
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
    if (!config.anthropicApiKey || analysisRunning) return
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
      const db = loadDB()

      // --- endpoints used by Trio ---
      if (req.method === 'POST' && url.pathname === '/trio/state') {
        db.state = await readBody(req)
        db.stateReceivedAt = new Date().toISOString()
        saveDB(db)
        return send(res, 200, { ok: true, historyThrough: historyThrough(loadHistory()) })
      }
      if (req.method === 'POST' && url.pathname === '/trio/history') {
        const upload = await readBody(req)
        const merged = mergeHistory(loadHistory(), upload)
        saveHistory(merged)
        return send(res, 200, { ok: true, historyThrough: historyThrough(merged), glucose: merged.glucose.length })
      }
      if (req.method === 'GET' && url.pathname === '/trio/proposals') {
        const status = url.searchParams.get('status')
        return send(res, 200, db.proposals.filter((p) => !status || p.status === status))
      }
      if (req.method === 'POST' && parts[0] === 'trio' && parts[1] === 'proposals' && parts[3] === 'result') {
        const p = db.proposals.find((x) => x.id === parts[2])
        if (!p) return send(res, 404, { error: 'not found' })
        const body = await readBody(req)
        if (!['applied', 'rejected', 'failed'].includes(body.status)) return send(res, 400, { error: 'bad status' })
        Object.assign(p, { status: body.status, resultMessage: body.message ?? '', resolvedAt: body.at ?? new Date().toISOString() })
        saveDB(db)
        return send(res, 200, { ok: true })
      }

      // --- endpoints used by the MCP side ---
      if (req.method === 'GET' && url.pathname === '/api/state') {
        return send(res, 200, { state: db.state, stateReceivedAt: db.stateReceivedAt })
      }
      if (req.method === 'GET' && url.pathname === '/api/proposals') {
        const status = url.searchParams.get('status')
        return send(res, 200, db.proposals.filter((p) => !status || p.status === status).slice(-50))
      }
      if (req.method === 'POST' && url.pathname === '/api/proposals') {
        const proposal = createProposal(db, await readBody(req))
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
          analysis: { time: cfg.analysisTime, model: cfg.model, hasKey: Boolean(cfg.anthropicApiKey), running: analysisRunning, lastError: db.lastAnalysisError || null }
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

// ---------- MCP server (stdio) ----------

async function mcp() {
  const { McpServer } = await import('@modelcontextprotocol/sdk/server/mcp.js')
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js')
  const { z } = await import('zod')
  const config = loadConfig()

  async function api(pathname, options = {}) {
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
      if (!state) return text('Trio has not synced yet. Enable the Claude-Bridge in Trio → Settings → Claude.')
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
    'Read Trio settings from the last iPhone sync. Sections: settings (TrioSettings), preferences (oref algorithm preferences, e.g. maxIOB, SMB, autosens, dynamic ISF), basal_profile, isf, carb_ratios, bg_targets, pump, or all. Schedules use mg/dL internally.',
    { section: z.enum(['all', 'settings', 'preferences', 'basal_profile', 'isf', 'carb_ratios', 'bg_targets', 'pump']).default('all') },
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
      const data = section === 'all' ? { ...map, scheduleUnits: state.scheduleUnits } : map[section]
      return text({ snapshotAgeMinutes: ageMinutes(stateReceivedAt), section, data })
    })
  )

  server.tool(
    'trio_propose_settings_change',
    'Propose changing one or more keys in Trio "settings" or "preferences". Keys must exist in the snapshot (see trio_get_settings) and keep their type. The change is NOT applied: the user must review the diff and approve it with Face ID in Trio. Always explain the reason.',
    {
      target: z.enum(['settings', 'preferences']),
      changes: z.record(z.union([z.number(), z.boolean(), z.string()])).describe('key → new value'),
      reason: z.string().min(5).describe('Why this change is suggested (shown to the user)')
    },
    guard(async ({ target, changes, reason }) => {
      const p = await api('/api/proposals', { method: 'POST', body: JSON.stringify({ target, patch: changes, reason }) })
      return text({ proposal: p, next: 'Waiting for approval on the iPhone (Trio → Settings → Claude). Check with trio_get_proposal.' })
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
      return text({ proposal: p, next: 'Waiting for approval on the iPhone (Trio → Settings → Claude).' })
    })
  )

  server.tool(
    'trio_list_proposals',
    'List recent proposals and their status (pending, applied, rejected, failed, cancelled).',
    { status: z.enum(['pending', 'applied', 'rejected', 'failed', 'cancelled']).optional() },
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
    'Run the daily analysis now (uses the Anthropic API key configured on the Mac). Creates a report and pending proposals for approval in Trio.',
    {},
    guard(async () => text(await api('/api/analyze', { method: 'POST' })))
  )

  await server.connect(new StdioServerTransport())
}

// ---------- helpers ----------

function info() {
  const config = loadConfig()
  console.log('Enter this in Trio → Settings → Claude:')
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
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
  const key = await new Promise((resolve) => rl.question('Anthropic API key (sk-ant-...): ', resolve))
  rl.close()
  const config = loadConfig()
  config.anthropicApiKey = String(key).trim()
  saveConfig(config)
  console.log(config.anthropicApiKey ? 'Saved.' : 'Key removed.')
}

const command = process.argv[2]
if (command === 'serve') serve()
else if (command === 'set-api-key') setApiKey()
else if (command === 'set-time') {
  const value = process.argv[3]
  if (!/^\d{1,2}:\d{2}$/.test(value || '')) { console.error('Usage: set-time HH:MM'); process.exit(1) }
  const config = loadConfig(); config.analysisTime = value; saveConfig(config); console.log(`Daily analysis at ${value}`)
}
else if (command === 'set-model') {
  const config = loadConfig(); config.model = process.argv[3] || 'claude-sonnet-4-5'; saveConfig(config); console.log(`Model: ${config.model}`)
}
else if (command === 'analyze') analyze('cli').then((r) => console.log(JSON.stringify(r, null, 2)), (e) => { console.error(e.message); process.exit(1) })
else if (command === 'mcp') mcp().catch((e) => { console.error(e); process.exit(1) })
else if (command === 'info') info()
else if (command === 'install-launchd') installLaunchd()
else {
  console.error('Usage: node trio-mcp.mjs <serve|mcp|info|install-launchd|set-api-key|set-time|set-model|analyze>')
  process.exit(1)
}
