import { spawn } from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { loadRemoteConfig, setupRemote } from './remote-config.mjs'

export function parseTunnelURL(line) {
  for (const candidate of line.match(/https:\/\/[^\s|]+/g) || []) {
    try {
      const url = new URL(candidate)
      if (!url.port && /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.trycloudflare\.com$/.test(url.hostname) && candidate === url.origin) return url.origin
    } catch { /* Ignore non-URL log text. */ }
  }
}

async function closeReservation(listener) {
  if (listener?.listening) await new Promise(resolve => listener.close(resolve))
}

async function terminate(child) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return
  const exited = new Promise(resolve => child.once('exit', resolve))
  child.kill('SIGTERM')
  const timer = setTimeout(() => child.kill('SIGKILL'), 2500)
  try { await exited } finally { clearTimeout(timer) }
}

async function ready(port, origin) {
  try {
    const get = route => fetch(`http://127.0.0.1:${port}${route}`, { redirect: 'error', signal: AbortSignal.timeout(1000) })
    const [health, unauthenticated, metadata] = await Promise.all([get('/health'), get('/mcp'), get('/.well-known/oauth-protected-resource/mcp')])
    if (health.status !== 200 || unauthenticated.status !== 401 || metadata.status !== 200) return false
    const [status, resource] = await Promise.all([health.json(), metadata.json()])
    await unauthenticated.arrayBuffer()
    return status.ok === true && status.service === 'trio-mcp-remote' && resource.resource === `${origin}/mcp` &&
      resource.scopes_supported?.includes('trio') && unauthenticated.headers.get('www-authenticate')?.includes(`${origin}/.well-known/oauth-protected-resource/mcp`)
  } catch { return false }
}

export async function runTestTunnel({ binary, directory, script }) {
  const children = []
  let reservation
  let startupTimer
  let stopped = false
  let exitCode = 1
  let finish
  const ended = new Promise(resolve => { finish = resolve })
  const abort = new AbortController()
  const stop = (code, message) => {
    if (stopped) return
    stopped = true
    exitCode = code
    if (message) console.error(message)
    abort.abort()
    finish()
  }
  const onSignal = () => stop(0)
  const watch = child => {
    children.push(child)
    child.once('error', () => stop(1, 'Remote-Test konnte nicht gestartet werden.'))
    child.once('exit', () => stop(1, 'Remote-Test beendet: Ein Teilprozess wurde beendet.'))
    return child
  }
  process.once('SIGINT', onSignal)
  process.once('SIGTERM', onSignal)
  try {
    if (![binary, directory, script].every(value => typeof value === 'string' && path.isAbsolute(value))) throw new Error()
    const port = fs.existsSync(path.join(directory, 'remote.json')) ? loadRemoteConfig(directory).port : 8766
    // Reserve the free port until the new issuer is configured; expose no old service during startup.
    reservation = net.createServer(socket => socket.destroy())
    await new Promise((resolve, reject) => {
      reservation.once('error', reject)
      reservation.listen(port, '127.0.0.1', resolve)
    })
    if (stopped) return exitCode
    startupTimer = setTimeout(() => stop(1, 'Remote-Test konnte innerhalb von 45 Sekunden nicht bereitgestellt werden.'), 45_000)
    const tunnel = watch(spawn(binary, [
      'tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${port}`,
      '--metrics', '127.0.0.1:0', '--management-diagnostics=false', '--grace-period', '1s', '--loglevel', 'info'
    ], { stdio: ['ignore', 'pipe', 'pipe'] }))
    let found
    const address = new Promise(resolve => { found = resolve })
    for (const stream of [tunnel.stdout, tunnel.stderr]) {
      let buffer = ''
      stream.setEncoding('utf8')
      stream.on('data', text => {
        buffer += text
        const lines = buffer.split('\n')
        buffer = lines.pop().slice(-8192)
        for (const line of lines) {
          const url = parseTunnelURL(line)
          if (url) found(url)
        }
      })
    }
    const origin = await Promise.race([address, ended.then(() => undefined)])
    if (!origin || stopped) return exitCode
    setupRemote(directory, origin)
    await closeReservation(reservation)
    if (stopped) return exitCode
    watch(spawn(process.execPath, [script, 'remote'], { env: { ...process.env, TRIO_MCP_DIR: directory }, stdio: 'ignore' }))
    while (!stopped) {
      if (await ready(port, origin)) {
        if (stopped) break
        clearTimeout(startupTimer)
        console.log(`Remote MCP test ready: ${origin}/mcp`)
        await ended
        break
      }
      await delay(100, undefined, { signal: abort.signal }).catch(() => {})
    }
  } catch {
    stop(1, 'Remote-Test konnte nicht gestartet werden. Port, Programm und Konfiguration prüfen.')
  } finally {
    clearTimeout(startupTimer)
    abort.abort()
    process.removeListener('SIGINT', onSignal)
    process.removeListener('SIGTERM', onSignal)
    await closeReservation(reservation)
    await Promise.all(children.map(terminate))
  }
  return exitCode
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , binary, directory = process.env.TRIO_MCP_DIR || path.join(os.homedir(), '.trio-mcp')] = process.argv
  process.exitCode = await runTestTunnel({ binary, directory, script: fileURLToPath(new URL('./trio-mcp.mjs', import.meta.url)) })
}
