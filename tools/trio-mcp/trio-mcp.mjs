#!/usr/bin/env node
// trio-mcp — relay between Trio (iPhone) and Claude (MCP).
//
//   node trio-mcp.mjs serve            HTTP relay for the iPhone (run permanently, e.g. via launchd)
//   node trio-mcp.mjs mcp              MCP server over stdio (started by Claude Desktop / Claude Code)
//   node trio-mcp.mjs info             Print URL + token to enter in Trio
//   node trio-mcp.mjs install-launchd  Start the relay automatically at login (macOS)
//
// Safety model: Claude can read Trio's snapshot and create PROPOSALS. Nothing is changed in Trio
// until the user reviews the proposal on the iPhone and approves it with Face ID.

import { randomBytes, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = os.homedir()
const DIR = process.env.TRIO_MCP_DIR || path.join(HOME, '.trio-mcp')
const CONFIG_FILE = path.join(DIR, 'config.json')
const DB_FILE = path.join(DIR, 'db.json')
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
  if (changed) fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 })
  return config
}

function loadDB() {
  try { return JSON.parse(fs.readFileSync(DB_FILE, 'utf8')) } catch { return { state: null, stateReceivedAt: null, proposals: [] } }
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

// ---------- HTTP relay (serve) ----------

function serve() {
  const config = loadConfig()
  const send = (res, code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  const readBody = (req) => new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (c) => { data += c; if (data.length > 5e6) req.destroy() })
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}) } catch (e) { reject(e) } })
    req.on('error', reject)
  })

  const server = http.createServer(async (req, res) => {
    try {
      if ((req.headers.authorization || '') !== `Bearer ${config.token}`) return send(res, 401, { error: 'unauthorized' })
      const url = new URL(req.url, 'http://local')
      const parts = url.pathname.split('/').filter(Boolean)
      const db = loadDB()

      // --- endpoints used by Trio ---
      if (req.method === 'POST' && url.pathname === '/trio/state') {
        db.state = await readBody(req)
        db.stateReceivedAt = new Date().toISOString()
        saveDB(db)
        return send(res, 200, { ok: true })
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
        const body = await readBody(req)
        if (PATCH_TARGETS.includes(body.target)) validatePatch(db, body.target, body.patch)
        else if (SCHEDULE_TARGETS.includes(body.target)) validateSchedule(body.target, body.schedule)
        else throw new Error(`target must be one of ${[...PATCH_TARGETS, ...SCHEDULE_TARGETS].join(', ')}`)
        const proposal = {
          id: randomUUID(),
          createdAt: new Date().toISOString(),
          target: body.target,
          patch: body.patch ?? null,
          schedule: body.schedule ?? null,
          reason: String(body.reason || '').slice(0, 500),
          status: 'pending'
        }
        db.proposals.push(proposal)
        saveDB(db)
        return send(res, 200, proposal)
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

  await server.connect(new StdioServerTransport())
}

// ---------- helpers ----------

function info() {
  const config = loadConfig()
  console.log('Enter this in Trio → Settings → Claude:')
  for (const ip of lanAddresses()) console.log(`  Server: http://${ip}:${config.port}`)
  console.log(`  Token:  ${config.token}`)
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

const command = process.argv[2]
if (command === 'serve') serve()
else if (command === 'mcp') mcp().catch((e) => { console.error(e); process.exit(1) })
else if (command === 'info') info()
else if (command === 'install-launchd') installLaunchd()
else {
  console.error('Usage: node trio-mcp.mjs <serve|mcp|info|install-launchd>')
  process.exit(1)
}
