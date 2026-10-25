// Shared MCP tools for local stdio and authenticated remote clients.
import { historyShape, rangeShape, compareShape } from './history.mjs'
import { mealsShape, mealPhotoShape } from './meals.mjs'
const SCHEDULE_TARGETS = ['basal_profile', 'isf', 'carb_ratios', 'bg_targets']

export async function createMcpServer(api) {
  const { McpServer } = await import('@modelcontextprotocol/sdk/server/mcp.js')
  const { z } = await import('zod')
  const text = (obj) => ({ content: [{ type: 'text', text: typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2) }] })
  const guard = (fn) => async (args) => {
    try { return await fn(args) } catch (e) { return { ...text(`Error: ${e.message}`), isError: true } }
  }
  const ageMinutes = (iso) => iso ? Math.round((Date.now() - Date.parse(iso)) / 60000) : null

  const server = new McpServer({ name: 'trio', version: '0.1.0' }, {
    instructions: [
      'Analyze Trio data directly in the current chat using the read tools. No additional AI provider API key is required for this MCP chat workflow.',
      'Proposals do not apply changes. The user must review the diff and approve locally in Trio; check proposal status before claiming a change was applied.',
      'Read status, settings and history statistics as needed; report the snapshot age and data coverage. These are synced snapshots, not live readings; request a fresh iPhone sync if current data is needed.',
      'For exact charts use trio_get_history, not aggregated statistics. Collect every page until nextCursor is null and verify the collected count equals total. Never invent missing values, interpolate or downsample silently. All pages must share one revision; restart if history changed. Check trio_get_data_quality and label times and units.',
      'Read trio_get_settings_catalog before proposing changes and respect its types, constraints and local-only actions.',
      'trio_run_daily_analysis is a separate optional Mac-side API job using its configured provider credentials. Run it only when the user explicitly requests that separate daily analysis, never merely to analyze data in this chat.'
    ].join(' ')
  })
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  const proposal = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }

  server.tool(
    'trio_get_history',
    'Exact synced history for charts: glucose, carbs, boluses, tempBasals, determinations (IOB/COB and loop fields), or tdd. Original relay records without rounding, interpolation or averaging. Default last 30 days; explicit ISO timestamps need timezone; [from,to), maximum 30 days. Fetch ALL pages: first call kind/from/to/limit, then ONLY cursor=nextCursor and optional limit until null; check count against total and stable revision. A changed dataset requires restarting. Completeness only covers synced relay data, not all phone data. Glucose remains mg/dL even when the app displays mmol/L.',
    historyShape, readOnly,
    guard(async args => text(await api('/api/history?' + new URLSearchParams(args))))
  )
  server.tool(
    'trio_get_data_quality',
    'Counts, first/last timestamps, duplicate timestamps and glucose gaps for a range (default last 30 days). 5-minute bin coverage is an estimate, not proven sensor uptime. Reports missing leading/trailing data and explicit gap-list truncation. Does not fetch fresh iPhone data.',
    rangeShape, readOnly,
    guard(async args => text(await api('/api/history/quality?' + new URLSearchParams(args))))
  )
  server.tool(
    'trio_compare_periods',
    'Compare two explicit time windows, at most 30 days each: sample-based glucose statistics and data quality, with differences B minus A. No causal conclusion or therapy recommendation. Use trio_get_history for exact raw charts; these statistics are rounded and filtered like trio_get_history_stats.',
    compareShape, readOnly,
    guard(async args => text(await api('/api/history/compare', { method: 'POST', body: JSON.stringify(args) })))
  )

  server.tool(
    'trio_get_meals',
    'AI meal analyses logged in Trio (photo and/or text description, provider, web search flag, item breakdown, AI estimate and the values the user actually applied). Newest first; page with offset until nextOffset is null. Optional ISO from/to with timezone. Synced from the iPhone with the KI-Bridge; meals analyzed while the bridge was off appear after the next sync.',
    mealsShape, readOnly,
    guard(async args => text(await api('/api/meals?' + new URLSearchParams(Object.entries(args).filter(([, v]) => v !== undefined)))))
  )
  server.tool(
    'trio_get_meal_photo',
    'The original meal photo (JPEG) of one logged AI meal, by id from trio_get_meals. Text-only analyses have no photo.',
    mealPhotoShape, readOnly,
    guard(async ({ id }) => {
      const { meal, mimeType, data } = await api(`/api/meals/${encodeURIComponent(id)}/photo`)
      return {
        content: [
          { type: 'image', data, mimeType },
          { type: 'text', text: JSON.stringify({ id: meal.id, createdAt: meal.createdAt, description: meal.description, estimate: meal.estimate, applied: meal.applied }, null, 2) }
        ]
      }
    })
  )

  server.tool(
    'trio_get_status',
    'Current Trio status from the last iPhone sync: glucose, trend, delta, IOB, COB, last loop time, app version, and how old the snapshot is.',
    {},
    readOnly,
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
    readOnly,
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
    readOnly,
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
      changes: z.record(z.string(), z.unknown()).describe('catalog key → new JSON value (including arrays/objects)'),
      reason: z.string().min(5).describe('Why this change is suggested (shown to the user)')
    },
    proposal,
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
    proposal,
    guard(async ({ target, schedule, reason }) => {
      const p = await api('/api/proposals', { method: 'POST', body: JSON.stringify({ target, schedule, reason }) })
      return text({ proposal: p, next: 'Waiting for approval on the iPhone (Trio → Settings → KI).' })
    })
  )

  server.tool(
    'trio_list_proposals',
    'List recent proposals and their status (pending, applying, applied, rejected, failed, cancelled). applying means the iPhone has reserved the approved change; do not retry an uncertain hardware operation.',
    { status: z.enum(['pending', 'applying', 'applied', 'rejected', 'failed', 'cancelled']).optional() },
    readOnly,
    guard(async ({ status }) => text(await api('/api/proposals' + (status ? `?status=${status}` : ''))))
  )

  server.tool(
    'trio_get_proposal',
    'Get one proposal including the result message reported by Trio after approval/rejection.',
    { id: z.uuid() },
    readOnly,
    guard(async ({ id }) => {
      const list = await api('/api/proposals')
      const p = list.find((x) => x.id === id)
      return p ? text(p) : { ...text('Proposal not found'), isError: true }
    })
  )

  server.tool(
    'trio_cancel_proposal',
    'Withdraw a pending proposal so it no longer shows up in Trio.',
    { id: z.uuid() },
    { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    guard(async ({ id }) => text(await api(`/api/proposals/${encodeURIComponent(id)}/cancel`, { method: 'POST' })))
  )

  server.tool(
    'trio_get_history_stats',
    'Aggregated statistics of the last up to 30 days from Trio: TIR/TBR/TAR, mean, CV, GMI per period and per day, hour-of-day glucose percentiles with loop adjustments (sensitivityRatio, temp basal minus scheduled basal), hypo events, meal responses, TDD. Use this before proposing therapy changes.',
    { include: z.enum(['summary', 'daily', 'hourly', 'meals', 'all']).default('all') },
    readOnly,
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
    readOnly,
    guard(async ({ count }) => text((await api('/api/reports')).slice(0, count)))
  )

  server.tool(
    'trio_run_daily_analysis',
    'Optional separate Mac-side API analysis; run only when the user explicitly requests it. Not needed for analysis in the current chat. Sends synced data to the configured AI provider using its model and credentials, creates a report and pending proposals for local approval in Trio, and withdraws older pending automatic proposals.',
    {},
    { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    guard(async () => text(await api('/api/analyze', { method: 'POST' })))
  )

  return server
}
