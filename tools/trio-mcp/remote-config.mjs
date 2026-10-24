import { createHash, randomBytes, randomUUID } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { normalizeBridgeURL } from './setup.mjs'

function origin(value) {
  const result = normalizeBridgeURL(value)
  if (!result.startsWith('https://')) throw new Error('Remote MCP benötigt eine öffentliche HTTPS-Adresse.')
  return result
}

function privateWrite(file, value) {
  const tmp = file + '.' + randomUUID() + '.tmp'
  try {
    fs.writeFileSync(tmp, value, { mode: 0o600, flag: 'wx' })
    fs.renameSync(tmp, file)
  } finally { fs.rmSync(tmp, { force: true }) }
}

function privateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  fs.chmodSync(directory, 0o700)
}

export function setupRemote(directory, publicUrl) {
  publicUrl = origin(publicUrl)
  privateDirectory(directory)
  const ownerKeyFile = path.join(directory, 'remote-owner-key.txt')
  if (!fs.existsSync(ownerKeyFile)) privateWrite(ownerKeyFile, randomBytes(32).toString('base64url') + '\n')
  const configFile = path.join(directory, 'remote.json')
  let port = 8766
  if (fs.existsSync(configFile)) port = loadRemoteConfig(directory).port
  privateWrite(configFile, JSON.stringify({ publicUrl, port }, null, 2) + '\n')
  return remoteInfo(loadRemoteConfig(directory))
}

export function loadRemoteConfig(directory) {
  const configFile = path.join(directory, 'remote.json')
  const ownerKeyFile = path.join(directory, 'remote-owner-key.txt')
  let saved, key
  try {
    saved = JSON.parse(fs.readFileSync(configFile, 'utf8'))
    key = fs.readFileSync(ownerKeyFile, 'utf8').trim()
  } catch { throw new Error('Remote-Einrichtung fehlt oder ist ungültig. Zuerst remote-setup HTTPS_ORIGIN ausführen.') }
  const publicUrl = origin(saved.publicUrl)
  if (!Number.isInteger(saved.port) || saved.port < 1024 || saved.port > 65535) throw new Error('Ungültiger Remote-Port (1024–65535).')
  if (!/^[A-Za-z0-9_-]{43}$/.test(key)) throw new Error('Ungültiger Remote-Anmeldeschlüssel.')
  privateDirectory(directory)
  fs.chmodSync(configFile, 0o600)
  fs.chmodSync(ownerKeyFile, 0o600)
  // A new public address gets its own grants; old credentials never cross issuers.
  const issuerId = createHash('sha256').update(publicUrl).digest('hex').slice(0, 24)
  return {
    publicUrl, port: saved.port, ownerKeyFile, configFile,
    ownerKeyHash: createHash('sha256').update(key).digest('hex'),
    stateFile: path.join(directory, `remote-auth-${issuerId}.json`)
  }
}

export function remoteInfo(config) {
  return {
    mcpUrl: config.publicUrl + '/mcp',
    listener: `127.0.0.1:${config.port}`,
    ownerKeyFile: config.ownerKeyFile,
    configFile: config.configFile
  }
}
