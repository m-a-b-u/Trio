// AI meal log uploaded by Trio: analysis metadata in meals.json, original JPEG photos in meals/.
import fs from 'node:fs'
import path from 'node:path'
import { z } from 'zod'

const MAX_PHOTO_BYTES = 8 * 1024 * 1024
const timestamp = z.iso.datetime({ offset: true })
const amount = z.number().finite().min(0).max(10000)
const id = z.string().regex(/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/)

const mealSchema = z.object({
  id,
  createdAt: timestamp,
  provider: z.string().max(64),
  model: z.string().max(200),
  webSearch: z.boolean(),
  description: z.string().max(4000),
  revision: z.number().int().min(1),
  estimate: z.object({
    carbs: amount, fat: amount, protein: amount,
    confidence: z.string().max(32),
    notes: z.string().max(4000),
    shortNote: z.string().max(200),
    items: z.array(z.object({
      name: z.string().max(200), carbs: amount,
      grams: amount.optional(), fat: amount.optional(), protein: amount.optional()
    }).strict()).max(100)
  }).strict(),
  applied: z.object({
    carbs: amount, fat: amount, protein: amount, note: z.string().max(200), at: timestamp
  }).strict().optional(),
  photo: z.string().max(Math.ceil(MAX_PHOTO_BYTES / 3) * 4).optional()
}).strict()
export const uploadSchema = z.object({ meals: z.array(mealSchema).max(20) }).strict()

export const mealsShape = {
  from: timestamp.optional(),
  to: timestamp.optional(),
  limit: z.number().int().min(1).max(200).default(50),
  offset: z.number().int().min(0).default(0)
}
export const mealPhotoShape = { id }

export function createMealStore(dir) {
  const file = path.join(dir, 'meals.json')
  const photos = path.join(dir, 'meals')
  const photoFile = (mealID) => path.join(photos, `${id.parse(mealID).toUpperCase()}.jpg`)

  function load() {
    if (!fs.existsSync(file)) return []
    const meals = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (!Array.isArray(meals)) throw new Error('Stored meals could not be read. Refusing to overwrite them.')
    return meals
  }
  function save(meals) {
    const tmp = `${file}.${process.pid}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(meals), { mode: 0o600 })
    fs.renameSync(tmp, file)
  }

  /** Inserts or updates meals; an older revision never replaces a newer one. */
  function upsert(body) {
    const { meals: incoming } = uploadSchema.parse(body)
    // Validate every photo before writing anything, so a bad entry cannot leave orphaned files behind.
    const photoBytes = incoming.map(({ id: mealID, photo }) => {
      if (photo === undefined) return undefined
      const bytes = Buffer.from(photo, 'base64')
      if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES || bytes[0] !== 0xFF || bytes[1] !== 0xD8) {
        throw new Error(`Meal ${mealID}: photo must be a JPEG of at most ${MAX_PHOTO_BYTES} bytes.`)
      }
      return bytes
    })
    const meals = load()
    let stored = 0
    for (const [position, { photo, ...meal }] of incoming.entries()) {
      meal.id = meal.id.toUpperCase()
      const index = meals.findIndex(m => m.id === meal.id)
      if (index >= 0 && meals[index].revision > meal.revision) continue
      let hasPhoto = index >= 0 ? meals[index].hasPhoto === true : false
      const bytes = photoBytes[position]
      if (bytes !== undefined) {
        fs.mkdirSync(photos, { recursive: true, mode: 0o700 })
        fs.writeFileSync(photoFile(meal.id), bytes, { mode: 0o600 })
        hasPhoto = true
      }
      const record = { ...meal, hasPhoto, receivedAt: new Date().toISOString() }
      if (index >= 0) meals[index] = record
      else meals.push(record)
      stored++
    }
    meals.sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt))
    save(meals)
    return { ok: true, stored, total: meals.length }
  }

  /** Newest first, with explicit total so clients can page through everything. */
  function list(input = {}) {
    const query = z.object(mealsShape).strict().parse(input)
    const start = query.from ? Date.parse(query.from) : -Infinity
    const end = query.to ? Date.parse(query.to) : Infinity
    if (!(start < end)) throw new Error('from must be before to.')
    const matching = load()
      .filter(m => { const t = Date.parse(m.createdAt); return t >= start && t < end })
      .reverse()
    const page = matching.slice(query.offset, query.offset + query.limit)
    const nextOffset = query.offset + page.length < matching.length ? query.offset + page.length : null
    return {
      total: matching.length, offset: query.offset, nextOffset,
      units: { carbs: 'g', fat: 'g', protein: 'g', grams: 'g portion weight' },
      note: 'estimate = AI suggestion; applied = values the user confirmed into the carb entry form (absent if not applied). Photos via trio_get_meal_photo.',
      meals: page
    }
  }

  function photo(mealID) {
    const meal = load().find(m => m.id === id.parse(mealID).toUpperCase())
    if (!meal) throw new Error('Meal not found.')
    if (!meal.hasPhoto || !fs.existsSync(photoFile(meal.id))) throw new Error('This meal has no photo (text-only analysis).')
    return { meal, mimeType: 'image/jpeg', data: fs.readFileSync(photoFile(meal.id)).toString('base64') }
  }

  return { upsert, list, photo }
}
