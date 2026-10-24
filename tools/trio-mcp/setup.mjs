import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import fs from 'node:fs'
import { isIP } from 'node:net'
import os from 'node:os'
import path from 'node:path'

export function normalizeBridgeURL(value) {
  if (typeof value !== 'string' || value.length > 2048 || /[^\x21-\x7e]|\\/.test(value)) {
    throw new Error('Server muss eine gültige HTTP(S)-Basis-URL sein (maximal 2048 Zeichen).')
  }
  const match = /^(https?):\/\/(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?\/?$/i.exec(value)
  if (!match) throw new Error('Server darf keine Zugangsdaten, Pfade, Query oder Fragmente enthalten.')
  const scheme = match[1].toLowerCase()
  const host = match[2].toLowerCase()
  if (match[3] && (!Number.isInteger(Number(match[3])) || Number(match[3]) < 1 || Number(match[3]) > 65535)) {
    throw new Error('Server-Port muss zwischen 1 und 65535 liegen.')
  }
  const ip = isIP(host.startsWith('[') ? host.slice(1, -1) : host)
  const dns = host.length <= 253 && host.split('.').every(label =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))
  if (!ip && (!dns || /^[0-9.]+$/.test(host))) throw new Error('Ungültiger Server-Hostname.')
  let url
  try { url = new URL(value) } catch { throw new Error('Ungültige Server-URL.') }
  // WHATWG accepts abbreviated/hexadecimal IPv4; Foundation must see the same host.
  if (!ip && isIP(url.hostname)) throw new Error('IPv4-Adressen müssen vier dezimale Teile ohne führende Nullen haben.')
  if (scheme === 'http') {
    const [a, b] = host.split('.').map(Number)
    const privateIPv4 = ip === 4 && (a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 169 && b === 254))
    if (!(host === 'localhost' || (dns && host.endsWith('.local')) || privateIPv4)) {
      throw new Error('HTTP ist nur für localhost, .local und private/link-lokale/Loopback-IPv4-Adressen erlaubt; sonst HTTPS verwenden.')
    }
  }
  return url.origin
}

export function defaultSetupServer(port, hostname) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Ungültiger Relay-Port.')
  let name = hostname
  if (name === undefined) {
    try {
      name = execFileSync('/usr/sbin/scutil', ['--get', 'LocalHostName'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    } catch { name = os.hostname() }
  }
  if (typeof name !== 'string' || !name) throw new Error('Server-URL explizit angeben.')
  return normalizeBridgeURL(`http://${name.toLowerCase().endsWith('.local') ? name : name + '.local'}:${port}`)
}

export function createSetupLink({ baseURL, token, version = 1 }) {
  if (version !== 1) throw new Error('Unbekannte Einrichtungslink-Version.')
  if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{32,512}$/.test(token)) throw new Error('Ungültiges Bridge-Token-Format.')
  const server = normalizeBridgeURL(baseURL)
  return `Trio://ai-bridge-setup?${new URLSearchParams({ version: '1', server, token })}`
}

const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

export function renderSetupHTML({ server, png }) {
  if (!Buffer.isBuffer(png) || png.length < 8 || png.length > 2e6 || !png.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
    throw new Error('QR-Bild ist kein gültiges PNG.')
  }
  return `<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Private Trio-Einrichtung</title><style>body{font:18px system-ui;max-width:680px;margin:40px auto;padding:0 24px;color:#17202a;background:#fff}h1{font-size:28px}img{display:block;width:min(100%,420px);height:auto;margin:24px auto;image-rendering:pixelated}code{overflow-wrap:anywhere}li{margin:12px 0}small{display:block;line-height:1.5;color:#454545}</style></head>
<body><h1>Private KI-Bridge-Einrichtung</h1><p>Server: <code>${escapeHTML(server)}</code></p>
<img alt="Privater QR-Code zur Einrichtung der Trio-KI-Bridge" src="data:image/png;base64,${png.toString('base64')}">
<ol><li>Aktuellen Trio-Build am iPhone öffnen und dasselbe Netzwerk wie am Mac verwenden.</li>
<li>Diesen QR-Code mit der iPhone-Kamera scannen und in Trio öffnen.</li>
<li>Server in Trio prüfen, Verbindung testen und die Einrichtung lokal bestätigen.</li></ol>
<p>Der Verbindungstest überträgt keine Therapiedaten. Erst die aktivierte Synchronisierung überträgt Einstellungen und Verlauf.</p>
<small>Dieser private Einrichtungslink enthält deinen dauerhaften Bridge-Token. Er ist kein Einmalcode. Datei und QR-Code privat halten und die Datei nach der Einrichtung löschen. Anbieter-Schlüssel sind nicht enthalten.</small>
</body></html>\n`
}

// Constant program in argv; the credential-bearing request travels only through stdin.
const qrProgram = `import Foundation
import CoreImage
import ImageIO
struct Request: Decodable { let message: String; let destination: String }
do {
    let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard request.message.utf8.count <= 8192,
          let filter = CIFilter(name: "CIQRCodeGenerator") else { throw NSError(domain: "QR", code: 1) }
    filter.setValue(Data(request.message.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let qr = filter.outputImage else { throw NSError(domain: "QR", code: 2) }
    let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: qr.extent.insetBy(dx: -4, dy: -4))
    let image = qr.composited(over: background).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { throw NSError(domain: "QR", code: 3) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw NSError(domain: "QR", code: 4) }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "QR", code: 5) }
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: request.destination))
    try file.write(contentsOf: data as Data)
    try file.close()
} catch {
    FileHandle.standardError.write(Data("Lokale QR-Erzeugung fehlgeschlagen.\\n".utf8))
    exit(1)
}`

export function writePrivateSetup({ directory, baseURL, token }) {
  if (process.platform !== 'darwin') throw new Error('Die lokale QR-Erzeugung benötigt macOS mit Swift/CoreImage.')
  const server = normalizeBridgeURL(baseURL)
  const link = createSetupLink({ baseURL: server, token })
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  const temp = fs.mkdtempSync(path.join(directory, '.setup-'))
  fs.chmodSync(temp, 0o700)
  const destination = path.join(temp, 'qr.png')
  const file = path.resolve(directory, 'setup.html')
  const htmlTemp = path.join(directory, `.setup-${randomUUID()}.tmp`)
  try {
    fs.writeFileSync(destination, '', { mode: 0o600, flag: 'wx' })
    try {
      execFileSync('/usr/bin/swift', ['-e', qrProgram], {
        input: JSON.stringify({ message: link, destination }), timeout: 60000, maxBuffer: 1024 * 1024,
        stdio: ['pipe', 'ignore', 'pipe']
      })
    } catch { throw new Error('Lokale QR-Erzeugung fehlgeschlagen. Swift/CoreImage muss am Mac verfügbar sein.') }
    const html = renderSetupHTML({ server, png: fs.readFileSync(destination) })
    fs.writeFileSync(htmlTemp, html, { mode: 0o600, flag: 'wx' })
    fs.chmodSync(htmlTemp, 0o600)
    fs.renameSync(htmlTemp, file)
    return { file, server }
  } finally {
    fs.rmSync(temp, { recursive: true, force: true })
    fs.rmSync(htmlTemp, { force: true })
  }
}
