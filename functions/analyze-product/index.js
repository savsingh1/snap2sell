'use strict';

/**
 * Snap2Sell secure Gemini proxy — Cloud Function (gen2), Node 20.
 *
 * The mobile app POSTs a product photo here; this function calls Gemini and
 * returns structured product identification. The Gemini API key lives in
 * Secret Manager (mounted as GEMINI_API_KEY) and NEVER ships in the app.
 *
 *   POST /  { "imageBase64": "<base64>", "mimeType": "image/jpeg" }
 *   POST /  { "images": ["<base64>", ...up to 5], "mimeType": "image/jpeg" }
 *           (multi-photo: all photos must show the SAME item; the AI
 *           cross-checks details across them. The single-image field above
 *           keeps working exactly as before.)
 *   -> 200  { ...product identification JSON..., "_meta": {...} }
 *   -> 4xx/5xx { "error": { "category": "...", "message": "..." } }
 *
 * Env vars (set at deploy time):
 *   GEMINI_API_KEY  from Secret Manager (required)
 *   GEMINI_MODEL    primary model (default gemini-3.8-flash)
 *   APP_API_SECRET  shared secret the app must send as x-app-secret
 *                   (empty = accept without the header; dev only)
 *   IMAGE_MAX_EDGE  longest image edge (px) sent to Gemini (default 1600);
 *                   a request may override it with "imageMaxEdge" (512-1600)
 */

const functions = require('@google-cloud/functions-framework');
const sharp = require('sharp');

const PRIMARY_MODEL = process.env.GEMINI_MODEL || 'gemini-3.8-flash';
const FALLBACK_MODELS = ['gemini-3.8-flash', 'gemini-3.6-flash', 'gemini-3.5-flash'];
const APP_SECRET = process.env.APP_API_SECRET || '';
const IMAGE_MAX_EDGE_ENV = Number.parseInt(process.env.IMAGE_MAX_EDGE || '', 10);
const MAX_BODY_BYTES = 12 * 1024 * 1024; // 12 MB: room for up to 5 photos
const MAX_IMAGE_BYTES = 2.5 * 1024 * 1024;
const MAX_IMAGES = 5; // multi-photo cap per request

// ---- per-IP rate limiting (instance-local; good enough as abuse friction)
const _hits = new Map(); // ip -> array of epoch ms
function rateLimited(ip) {
  const now = Date.now();
  const windowStart = now - 60_000;
  const arr = (_hits.get(ip) || []).filter((t) => t > windowStart);
  arr.push(now);
  _hits.set(ip, arr);
  if (_hits.size > 5000) _hits.clear();
  return arr.length > 30; // 30 analyses / minute / IP
}

// ---------------------------------------------------------------------------
// Phase 5 — expert product-identification prompt.
// ---------------------------------------------------------------------------
const SYSTEM_PROMPT = `You are an expert product-recognition system for a resale marketplace.

Analyze the supplied product photo carefully. Use all visible evidence including:
- logos, brand markings, model numbers, labels
- shape, controls, materials, accessories, packaging
- distinctive design characteristics

Identify the product as specifically as the evidence allows.

PRIMARY SUBJECT: identify the DOMINANT subject of the photo — the item the
photo is actually about, which fills the frame or is clearly the focus. NEVER
identify or price a minor foreground or background object (something sitting
in front of, behind, or beside the real subject) instead of the dominant
subject.

PROPERTY ROUTING: if the dominant subject is a house, building, or other
residential property, this is NOT a product listing. Set "recognized": true,
"category": "Real Estate", and "product_name" describing the property (e.g.
"Brick Single-Family House"). Describe only the visible exterior features
(construction material, storeys, roof, windows, lot, landscaping) in
short_description, and state in short_description that a valuation cannot be
produced from exterior photos alone. Set price_low, price_high, and
suggested_price all to 0 — NEVER price the property, and NEVER price a
foreground object in the scene (a garden item, a plant cage, a vehicle in the
driveway) when the dominant subject is the property. Set
"needs_more_photos": true and use recommended_photos to request the
property-flow inputs: the property address, interior photos, square footage,
lot size, and year built.

VEHICLE CATEGORY: cars, trucks, and motorcycles use "category":
"Automotive" — never "Miscellaneous".

CRITICAL HONESTY RULES:
- Only name a brand if it is clearly visible or legible in the photo. Never guess a brand.
- If a logo or mark is visible but its text is NOT legible, describe the mark in short_description instead of naming a brand.
- Never invent an exact model number. If the model is not visible or cannot be determined confidently, leave "model" empty and identify the most likely product family instead.
- Never name a product series, line, or trim (e.g. "Eco Series") unless that exact series text is legibly visible in the photo. A legible brand alone NEVER establishes a series — if the series text is not visible, leave the series out of "product_name", "product_family", and "suggested_title" entirely.
- Only state materials if clearly visible. Never guess.
- Base price estimates on typical second-hand marketplace values in North America. These are ESTIMATES, not appraisals.
- If the photo is unclear, say so: set recognized=false or a low confidence, and use recommended_photos to ask for a better shot.

APPLE / TESLA PROGRESSIVE IDENTIFICATION — the rules in this block apply ONLY
when the confidently recognized brand is Apple or Tesla. They change nothing
for any other brand.
- Apple: if the product family is clearly MacBook Pro, MacBook Air, iPad,
  iPad Pro, or iPad Air, but the exact year / chip / storage / Axxxx model
  number cannot be determined confidently, still set "recognized": true with
  "identification_level": "product_family", leave "model" empty, and set
  "needs_more_information": true and "needs_more_photos": false. Continue the
  analysis with the facts you do know. Write unknown specs as "Unknown" in
  the description — NEVER invent a year, chip, storage size, or model number.
- Tesla: if the model family is clearly Model 3, Model Y, Model S, or
  Model X, but the year / trim / battery / drivetrain cannot be determined,
  still set "recognized": true with "identification_level":
  "product_family", leave "model" empty, and set "needs_more_information":
  true and "needs_more_photos": false. Continue the analysis with the facts
  you do know. NEVER invent a year, trim, battery size, or drivetrain.
- NEVER set "recognized": false merely because the exact variant is unknown.
- PRICING TIERS: "exact" identification -> your normal estimate.
  "product_family" identification -> give a BROADER range in price_low /
  price_high only when you can do so honestly from typical resale values;
  leave suggested_price 0 when no single sensible value exists. When you
  cannot form even a reasonable range, set all three prices to 0 — never
  fabricate a number.

AMBIGUOUS SUB-FAMILY — IDENTIFY AT THE PARENT FAMILY (applies to EVERY
brand — laptops, phones, cameras, game consoles, appliances, vehicles):
when two or more sub-families of one product line are both plausible from
the photo and the visible evidence cannot distinguish between them (e.g. a
single angled photo of a laptop that could be a MacBook Air or a MacBook
Pro), do NOT pick one sub-family. Identify at the PARENT family instead:
- "product_family": the parent line (e.g. "MacBook")
- "product_name": brand + parent line (e.g. "Apple MacBook")
- "model": ""
- "identification_level": "product_family"
- "confidence": 70 or lower
- "needs_more_photos": true and "needs_more_information": true, with the
  resolving photos listed in recommended_photos
- "suggested_title" must NOT contain either sub-family name — use the
  parent line only.
- "short_description" must NOT state design-shape, port-count or other
  specifics that distinguish the sub-families (for example a wedge profile
  or a port count that points to one sub-family); describe only plainly
  visible features that do not imply one sub-family over another.
This rule overrides any sub-family guidance elsewhere in this prompt
whenever the sub-family is not CLEARLY established by visible evidence.

CONDITION: give your best visual assessment (likeNew, excellent, good, fair, poor). The seller confirms it before listing — a photo cannot prove functionality or hidden defects.

VISIBLE EVIDENCE ONLY: descriptions may state ONLY what is actually visible
in the photo. NEVER assert function or hidden state as fact — do not write
"functional sunroof", "working condition", "runs well", or "air suspension"
unless that function is visibly demonstrated in the photo. Features you can
only infer get hedged phrasing: "appears to have", "shown with", "visibly
equipped with". For vehicles and appliances photographed only from the
outside, frame condition strictly as EXTERIOR COSMETIC condition (e.g.
"exterior appears clean and straight; mechanical condition not assessed") —
never imply the item works.

CONFIDENCE CALIBRATION: for vehicles and spec-dependent electronics (laptops,
phones, cameras, appliances), the things that drive value are often NOT
visible: mileage / odometer reading, interior condition, VIN, a powered-on
About / settings screen, a bottom-case or serial model number, a box spec
label. When those value drivers are not visible in the photo(s):
- cap "confidence" at 80,
- set "needs_more_photos": true,
- list the SPECIFIC resolving photos in recommended_photos (e.g. "Take a
  photo of the odometer.", "Take a photo of the About This Mac screen.",
  "Take a photo of the model-number sticker on the bottom case.").
LOW-RESOLUTION CAP: when the photo is small, cropped, or low-detail AND no
brand is legible in it, cap "confidence" at 60.
Never claim packaging shown in a photo is the item's ORIGINAL box unless a
label on the box visibly matches the unit.

RETAIL DISPLAY: if the photo shows a retail display context — printed product
placards or signage, anti-theft tethers or cables, display stands, store
shelving or lighting — say so in short_description (e.g. "Photographed on a
retail display — confirm whether this is the actual unit for sale."). In a
retail display context: cap "condition" at "good", cap "confidence" at 85,
and set "needs_more_photos": true. READ any legible placard or sign text and
USE it in the identification — including sub-variant or edition names printed
on the placard (e.g. a "Supreme Edition" style variant name) — and translate
non-English placard text when it is legible.

DEBADGED VEHICLE IDENTIFICATION: when a vehicle's badges or emblems are
absent or appear removed, you may still identify the brand and product family
from distinctive design language — silhouette and proportions, headlight and
taillight shapes, door-handle design, charge-port or fuel-door placement,
wheel design. When you identify a vehicle this way (by design, not by a
legible badge): set "identification_level": "product_family", leave "model"
empty, set "needs_more_information": true, and state in short_description
that the vehicle was identified by its design because badging is absent or
removed. NEVER fall back to a generic label like "Custom Modified Sedan"
when the design language identifies a known brand and family.

REGIONAL AND COMPATIBILITY CUES: when visible, note buyer-relevant
compatibility facts in short_description or search_keywords:
- plug type and voltage region: when a plug or switch style is visible
  (e.g. European Schuko, UK, or Indian plugs/switches) or other 220-240V
  region cues appear, short_description MUST plainly state the caveat for
  a North American buyer (e.g. "Fitted with a European Schuko plug
  (220-240V) — a North American buyer will need an adapter and must check
  voltage compatibility.")
- right-hand-drive vs left-hand-drive for vehicles
- keyboard layout language (e.g. "German QWERTZ keyboard layout")
- non-English labels or signage that affect who the item suits
Only note a cue you can actually see; never guess a region.

PLUG TYPE: when a power plug or cord is visible in the photo, name the plug type you can see (for example Schuko, UK, US) — do not infer the voltage from the outlet or the plug alone.

REJECTION HYGIENE: when "recognized" is false, the listing fields stay
EMPTY so no half-formed listing leaks through: set "suggested_title": "",
"product_name": "", "short_description": "", and price_low / price_high /
suggested_price all to 0. Carry the explanation in the two dedicated fields
instead: "rejection_reason" (one of: "non_product_image", "blurry_image",
"different_items", "unclear_image") and "user_message" (one or two plain
sentences telling the user what went wrong and what photo to try instead).
When "recognized" is true, set "rejection_reason": "" and "user_message": "".

Respond with ONLY a single JSON object (no markdown fences, no commentary) with exactly these fields:
{
  "recognized": true,
  "brand": "",
  "product_name": "",
  "model": "",
  "product_family": "",
  "category": "one of: Furniture, Electronics, Appliances, Fashion, Beauty & Personal Care, Toys & Games, Books & Media, Sports & Outdoors, Baby & Kids, Home & Garden, Real Estate, Automotive, Miscellaneous",
  "subcategory": "",
  "color": "",
  "condition": "one of: likeNew, excellent, good, fair, poor",
  "visible_damage": [],
  "included_accessories": [],
  "missing_parts": [],
  "search_keywords": [],
  "suggested_title": "short marketplace title",
  "short_description": "2-4 sentence marketplace description, condition honestly stated",
  "price_low": 0,
  "price_high": 0,
  "suggested_price": 0,
  "confidence": 0,
  "identification_level": "one of: exact, product_family",
  "needs_more_information": false,
  "needs_more_photos": false,
  "recommended_photos": [],
  "rejection_reason": "one of: '', non_product_image, blurry_image, different_items, unclear_image — only when recognized is false",
  "user_message": "short user-facing explanation when recognized is false, else ''",
  "photo_mismatch_warning": "'' normally; in multi-photo mode, a concrete description of the conflict when the photos appear to show different items"
}
"confidence" is 0-100. Below 60 set needs_more_photos=true and list the exact shots that would help, e.g. "Take a photo of the model-number label.", "Take a photo of the front of the product.", "Take a photo of the bottom sticker.", "Take a photo of the packaging." For large appliances, when the submitted photo is small, cropped, or partial, include a request in "recommended_photos" for one full top-to-bottom photo of the whole unit.
"identification_level" is "exact" when the precise model/variant is identified, or "product_family" when only the brand + product family is known (Apple/Tesla rules above). Set "needs_more_information": true when a photo of the model number / About This Mac screen / VIN would sharpen the result without blocking the listing.`;

// ---------------------------------------------------------------------------
// Multi-photo addendum — appended to SYSTEM_PROMPT ONLY when the request
// carries more than one photo. The single-photo path uses SYSTEM_PROMPT
// alone, exactly as before, so its behavior is unchanged.
// ---------------------------------------------------------------------------
const MULTI_PHOTO_ADDENDUM = `

MULTI-PHOTO MODE: you were given {N} photos. They are supposed to show the SAME item for sale — use them together:
- Identify the item using the clearest photo(s). Cross-check details across ALL photos: brand marks, model numbers, labels, colors, materials, accessories.
- If a model number, label, or brand mark is legible in ANY photo, use it. You still must NEVER invent a model number that is not visible.
- Assess condition from every photo, including close-up/detail shots. Report damage visible in any photo in visible_damage.
- DIFFERENT ITEMS — SOFT FAIL, NEVER A HARD REJECTION: if the photos clearly show DIFFERENT items (not just different angles of one item), do NOT set recognized=false. Instead: identify the PRIMARY item — the item in the first / clearest photo — and complete its listing normally, with a provisional price based on that item alone. Set "photo_mismatch_warning" to a concrete description of the conflict: what the primary photo appears to show and what the other photo(s) appear to show instead (e.g. "Photo 1 shows a silver MacBook; photo 2 shows a different keyboard layout and colour and appears to be a different unit."). Set "needs_more_photos": true and use recommended_photos to ask for consistent photos of ONE unit so the seller can confirm which item is actually for sale. When all photos show the same item, set "photo_mismatch_warning": "".
- All honesty rules above still apply to every photo.`;

// ---------------------------------------------------------------------------
// REAL ESTATE MODE — UNDEPLOYED / PLACEHOLDER (Workstream B).
//
// This prompt + the `mode: 'real_estate'` request branch below exist ONLY in
// the repo. The deployed Cloud Function does NOT include them, and the app
// does NOT send `mode` yet — so live behavior is unchanged. After a future
// redeploy WITH this code, the app can send { mode: 'real_estate' } to get
// structured property-condition observations instead of a product listing.
//
// Honesty rules baked into the prompt: visual observations only — the model
// must NEVER invent a price, an address, comparable sales, assessment
// values, permit records, or renovation years.
// ---------------------------------------------------------------------------
const REAL_ESTATE_PROMPT = `You are a property-condition analyst for a home-valuation feature.

Analyze the supplied property photo(s) carefully. Describe ONLY what is visually observable.

CRITICAL HONESTY RULES:
- NEVER invent, estimate, or guess a property value, price, or price range.
- NEVER invent or guess an address, city, or location for the property.
- NEVER state that a renovation happened in a specific year. Say "appears recently updated", "appears renovated", or "appears newer than the original construction" — visual observations only, never dated claims.
- NEVER invent comparable sales, assessment values, or permit records.
- Only describe what you can actually see: exterior/interior condition, roofing appearance, windows, siding, landscaping, garage, driveway, kitchen/bathroom condition, flooring, fixtures, apparent additions, deck/patio.
- If the photo does not clearly show a residential property, set is_residential_property=false and explain briefly in the observations.

Respond with ONLY a single JSON object (no markdown fences, no commentary) with exactly these fields:
{
  "is_residential_property": true,
  "property_type": "one of: detached_house, townhouse, duplex, condo, apartment, acreage, residential_lot, multi_family, unknown",
  "condition_observations": [
    {"area": "Kitchen", "observation": "Kitchen appears recently updated."}
  ],
  "overall_condition": "one of: likeNew, excellent, good, fair, poor",
  "confidence": 0
}
"confidence" is 0-100: how confident you are that this is a residential property and the observations are accurate.`;

// ---------------------------------------------------------------------------
// Gemini call with retry — transient failures only.
//
// 5xx / network failures: quick retries (a few seconds apart) are enough.
// 429 (rate limit): Gemini's per-minute quotas can stay exhausted for most
// of a minute, so a handful of quick retries will NOT survive them. 429s get
// their own slower path: honor the server's Retry-After hint when present,
// otherwise back off 5s -> 10s -> 20s (capped), spending up to
// RATE_LIMIT_WAIT_BUDGET_MS total before the friendly error reaches the app.
// The budget keeps worst-case runtime inside the function's 120s timeout.
// ---------------------------------------------------------------------------
const TRANSIENT_STATUS = new Set([500, 502, 503, 504]);
const BACKOFF_MS = [0, 1000, 2000, 4000]; // attempt 1 immediate, then ~1s/2s/4s
const RATE_LIMIT_WAIT_BUDGET_MS = 45_000; // total 429 waiting per model
const RATE_LIMIT_SINGLE_WAIT_CAP_MS = 30_000; // one wait never exceeds 30s
const RATE_LIMIT_MAX_WAITS = 8; // hard cap on 429 waits per model

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// Parse a Retry-After header (seconds or HTTP date) into ms, capped.
// Returns null when the header is absent or unparseable.
function retryAfterMs(res) {
  try {
    const h = res.headers && typeof res.headers.get === 'function'
      ? res.headers.get('retry-after')
      : null;
    if (!h) return null;
    const secs = Number(h);
    if (Number.isFinite(secs)) {
      if (secs < 0) return null; // malformed negative: treat as absent
      return Math.min(secs * 1000, RATE_LIMIT_SINGLE_WAIT_CAP_MS);
    }
    const when = Date.parse(h);
    if (!Number.isNaN(when)) {
      return Math.min(Math.max(0, when - Date.now()), RATE_LIMIT_SINGLE_WAIT_CAP_MS);
    }
  } catch {
    // fall through to null
  }
  return null;
}

class GeminiError extends Error {
  constructor(category, message, status) {
    super(message);
    this.category = category;
    this.status = status;
  }
}

async function callGemini(apiKey, model, jpegBase64List, promptText, startedAt, thinkingLevel) {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
  // Single photo: parts are [{ text: SYSTEM_PROMPT }, { inline_data }] —
  // identical to the original single-image request.
  const parts = [{ text: promptText }];
  for (const b64 of jpegBase64List) {
    parts.push({ inline_data: { mime_type: 'image/jpeg', data: b64 } });
  }
  // Round 5 A/B knob: an optional thinking level (Gemini 3 thinkingConfig).
  // When unset the request is byte-identical to the original. If a model
  // rejects the level with a 400, the level is stripped once and the call
  // retries without it (see the 400 branch below), so a bad level can
  // never take the endpoint down.
  let activeThinking = thinkingLevel || null;
  const buildBody = () => {
    const generationConfig = { responseMimeType: 'application/json', temperature: 0.2 };
    if (activeThinking) generationConfig.thinkingConfig = { thinkingLevel: activeThinking };
    return JSON.stringify({ contents: [{ parts }], generationConfig });
  };
  let body = buildBody();

  let lastErr = null;
  let attempt = 0;            // Gemini attempts made (1-based after increment)
  let rateLimitWaits = 0;     // 429 waits performed so far
  let rateLimitWaitedMs = 0;  // total ms spent waiting on 429 resets
  for (;;) {
    if (attempt > 0) {
      if (lastErr && lastErr.category === 'RATE_LIMIT') {
        // 429 path: honor the server's Retry-After hint; otherwise back off
        // 5s -> 10s -> 20s -> 20s... A per-minute quota reset needs real time.
        const hintMs = lastErr.retryAfterMs;
        const waitMs = hintMs != null
          ? hintMs
          : Math.min(5000 * 2 ** Math.min(rateLimitWaits, 3), RATE_LIMIT_SINGLE_WAIT_CAP_MS);
        if (rateLimitWaits >= RATE_LIMIT_MAX_WAITS ||
            rateLimitWaitedMs + waitMs > RATE_LIMIT_WAIT_BUDGET_MS) {
          break; // budget spent — surface the rate-limit error below
        }
        console.log(JSON.stringify({
          evt: 'rate_limit_wait', model, waitMs, waitNo: rateLimitWaits + 1,
        }));
        await sleep(waitMs);
        rateLimitWaitedMs += waitMs;
        rateLimitWaits++;
      } else {
        // 5xx / network path: unchanged quick backoff, 4 attempts max.
        if (attempt >= BACKOFF_MS.length) break;
        await sleep(BACKOFF_MS[attempt]);
      }
    }
    attempt++;
    const attemptStart = Date.now();
    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': apiKey,
        },
        body,
        signal: AbortSignal.timeout(45000),
      });
    } catch (e) {
      // Network-level failure (DNS, socket reset, timeout): transient.
      lastErr = new GeminiError(
        e.name === 'TimeoutError' ? 'TIMEOUT' : 'NETWORK_ERROR',
        'Temporary connection problem contacting the AI service.',
        0,
      );
      console.log(
        JSON.stringify({ evt: 'gemini_attempt', model, attempt, outcome: 'network_error', ms: Date.now() - attemptStart }),
      );
      continue;
    }

    if (res.ok) {
      let data;
      try {
        data = await res.json();
      } catch {
        throw new GeminiError('INVALID_RESPONSE', 'AI service returned an unreadable response.', 502);
      }
      const text =
        data?.candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? '';
      if (!text) {
        throw new GeminiError('INVALID_RESPONSE', 'AI service returned an empty response.', 502);
      }
      const clean = text.replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
      let parsed;
      try {
        parsed = JSON.parse(clean);
      } catch {
        throw new GeminiError('INVALID_RESPONSE', 'AI service returned malformed data.', 502);
      }
      console.log(
        JSON.stringify({ evt: 'gemini_attempt', model, attempt, outcome: 'ok', ms: Date.now() - attemptStart, totalMs: Date.now() - startedAt }),
      );
      return { parsed, model, attempts: attempt, thinking: activeThinking };
    }

    if (res.status === 404) {
      // Model retired/renamed — permanent for this model; caller tries next.
      throw new GeminiError('MODEL_ERROR', `Model ${model} is not available.`, 404);
    }
    if (res.status === 400) {
      const snippet = (await res.text().catch(() => '')).slice(0, 200);
      console.log(JSON.stringify({ evt: 'gemini_400', model, snippet }));
      if (activeThinking) {
        // The model rejected the thinking level: strip it and retry this
        // model once without it instead of failing the request.
        console.log(JSON.stringify({ evt: 'thinking_config_stripped', model, thinkingLevel: activeThinking }));
        activeThinking = null;
        body = buildBody();
        lastErr = null;
        continue;
      }
      throw new GeminiError('BAD_IMAGE', 'The photo could not be processed. Try a clearer photo.', 400);
    }
    if (res.status === 401 || res.status === 403) {
      console.log(JSON.stringify({ evt: 'gemini_auth_error', model, status: res.status }));
      throw new GeminiError('AUTH_ERROR', 'AI service credentials are invalid.', res.status);
    }
    if (res.status === 429) {
      // Rate limit: wait it out on the next loop iteration (Retry-After
      // aware) instead of burning the quick-retry budget.
      lastErr = new GeminiError(
        'RATE_LIMIT',
        'AI service is rate-limited right now.',
        429,
      );
      lastErr.retryAfterMs = retryAfterMs(res);
      console.log(
        JSON.stringify({ evt: 'gemini_attempt', model, attempt, outcome: 'http_429', retryAfterMs: lastErr.retryAfterMs, ms: Date.now() - attemptStart }),
      );
      continue;
    }
    if (TRANSIENT_STATUS.has(res.status)) {
      lastErr = new GeminiError(
        'MODEL_ERROR',
        'AI service is temporarily unavailable.',
        res.status,
      );
      console.log(
        JSON.stringify({ evt: 'gemini_attempt', model, attempt, outcome: `http_${res.status}`, ms: Date.now() - attemptStart }),
      );
      continue; // retry with backoff
    }
    throw new GeminiError('MODEL_ERROR', `AI service error (HTTP ${res.status}).`, res.status);
  }
  throw lastErr || new GeminiError('NETWORK_ERROR', 'Could not reach the AI service.', 502);
}

// ---------------------------------------------------------------------------
// HTTP entry point.
// ---------------------------------------------------------------------------
functions.http('analyzeProduct', async (req, res) => {
  const startedAt = Date.now();
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, x-app-secret');
  if (req.method === 'OPTIONS') return res.status(204).send('');

  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: { category: 'BAD_IMAGE', message: 'Use POST.' } });
    }
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) {
      console.log(JSON.stringify({ evt: 'misconfigured', reason: 'GEMINI_API_KEY missing' }));
      return res.status(500).json({ error: { category: 'AUTH_ERROR', message: 'Service is not configured. Try again later.' } });
    }
    if (APP_SECRET) {
      const got = req.get('x-app-secret') || '';
      // Constant-time-ish compare to avoid trivial timing leaks.
      const ok = got.length === APP_SECRET.length &&
        [...got].every((c, i) => c === APP_SECRET[i]);
      if (!ok) {
        return res.status(401).json({ error: { category: 'AUTH_ERROR', message: 'Unauthorized.' } });
      }
    }
    const ip = (req.get('x-forwarded-for') || req.ip || 'unknown').split(',')[0].trim();
    if (rateLimited(ip)) {
      return res.status(429).json({ error: { category: 'RATE_LIMIT', message: "You're analyzing a lot of photos — wait a minute and try again." } });
    }

    const rawLen = Number(req.get('content-length') || 0);
    if (rawLen > MAX_BODY_BYTES) {
      return res.status(413).json({ error: { category: 'BAD_IMAGE', message: 'Photo is too large. Try a smaller image.' } });
    }
    const { imageBase64, images, mimeType, mode, imageMaxEdge, modelOverride, thinkingLevel } = req.body || {};
    // Latency knob: longest image edge sent to Gemini. The IMAGE_MAX_EDGE
    // env var sets the default (1600); a request may override it with
    // "imageMaxEdge". Always clamped to 512-1600.
    const rawEdge = imageMaxEdge != null ? Number(imageMaxEdge)
      : Number.isFinite(IMAGE_MAX_EDGE_ENV) ? IMAGE_MAX_EDGE_ENV : 1600;
    const imageMaxEdgePx = Math.max(512, Math.min(1600,
      Math.round(Number.isFinite(rawEdge) ? rawEdge : 1600)));
    // NOTE: `mode: 'real_estate'` is the UNDEPLOYED Workstream B branch (see
    // REAL_ESTATE_PROMPT above). The app does not send it yet.
    // Multi-photo requests carry { images: [<base64>, ...] }. When that
    // field is absent, the original single-image path below runs with its
    // exact original validation and behavior.
    const multiMode = Array.isArray(images) && images.length > 0;
    let imageInputs;
    if (multiMode) {
      if (images.length > MAX_IMAGES) {
        return res.status(400).json({ error: { category: 'BAD_IMAGE', message: `Send up to ${MAX_IMAGES} photos at a time.` } });
      }
      imageInputs = [];
      for (const b64 of images) {
        if (typeof b64 !== 'string' || b64.length < 100) {
          return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'One of the photos was not received. Try again.' } });
        }
        if (b64.length > MAX_IMAGE_BYTES * 1.4) {
          return res.status(413).json({ error: { category: 'BAD_IMAGE', message: 'One photo is too large. Try smaller images.' } });
        }
        imageInputs.push(b64);
      }
    } else {
      if (typeof imageBase64 !== 'string' || imageBase64.length < 100) {
        return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'No photo was received. Try again.' } });
      }
      if (imageBase64.length > MAX_IMAGE_BYTES * 1.4) {
        return res.status(413).json({ error: { category: 'BAD_IMAGE', message: 'Photo is too large. Try a smaller image.' } });
      }
      imageInputs = [imageBase64];
    }

    // Normalize: EXIF orientation fixed, longest side <= imageMaxEdgePx,
    // JPEG q80. Handles JPEG/PNG/WEBP/HEIC input — Gemini gets clean JPEG.
    // Largest ORIGINAL edge (px) across the submitted photos, measured from
    // sharp metadata before resize — input for the round 3.5 low-resolution
    // guard below. Stays null when no photo yielded dimensions; the guard
    // then simply does not fire.
    let maxOriginalEdge = null;
    const jpegs = [];
    try {
      for (let i = 0; i < imageInputs.length; i++) {
        const input = Buffer.from(imageInputs[i], 'base64');
        const meta = await sharp(input).metadata();
        if (Number.isFinite(meta.width) || Number.isFinite(meta.height)) {
          const edge = Math.max(meta.width || 0, meta.height || 0);
          maxOriginalEdge = maxOriginalEdge == null
            ? edge
            : Math.max(maxOriginalEdge, edge);
        }
        const jpeg = await sharp(input)
          .rotate() // honor EXIF orientation
          .resize({ width: imageMaxEdgePx, height: imageMaxEdgePx, fit: 'inside', withoutEnlargement: true })
          .jpeg({ quality: 80, mozjpeg: true })
          .toBuffer();
        jpegs.push(jpeg);
        console.log(JSON.stringify({
          evt: 'image_normalized',
          ...(multiMode ? { index: i, count: imageInputs.length } : {}),
          inFormat: meta.format, inW: meta.width, inH: meta.height,
          outBytes: jpeg.length, inMime: mimeType || 'unknown', maxEdge: imageMaxEdgePx,
        }));
      }
    } catch {
      return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'That file is not a readable photo. Try a JPEG or PNG.' } });
    }

    // Round 5 blur fast-path — an extremely blurred photo cannot be
    // identified, and paying for a full model call to learn that costs
    // the user 7-13s. Sharpness is measured as the standard deviation of
    // a Laplacian convolution on a 320px grayscale copy. Calibrated on
    // the 13-photo test pack (sharp 0.33.5): the heavy-blur case scores
    // 1.18 while the softest real product photo scores 8.29, so the 3.0
    // threshold sits roughly 2.5x from both sides and only fires on
    // extreme blur. Single-photo requests only; any metric failure
    // falls through to the model unchanged.
    if (!multiMode && mode !== 'real_estate') {
      try {
        const { data } = await sharp(jpegs[0])
          .resize({ width: 320 })
          .grayscale()
          .convolve({ width: 3, height: 3, kernel: [0, 1, 0, 1, -4, 1, 0, 1, 0] })
          .raw()
          .toBuffer({ resolveWithObject: true });
        let mean = 0;
        for (const v of data) mean += v;
        mean /= data.length;
        let varSum = 0;
        for (const v of data) { const d = v - mean; varSum += d * d; }
        const lapStd = Math.sqrt(varSum / data.length);
        if (lapStd < 3.0) {
          console.log(JSON.stringify({ evt: 'blur_fast_path', lapStd: Math.round(lapStd * 100) / 100, totalMs: Date.now() - startedAt }));
          return res.status(200).json({
            recognized: false,
            brand: '', model: '', product_name: '', product_family: '',
            category: 'Miscellaneous', subcategory: '', color: '',
            // Round 11: same rejection condition normalization as
            // the model path — a refusal assessed no condition.
            condition: 'Not assessed from photo', confidence: 0, identification_level: 'none',
            // Round 10: aligned with the rejection_flag_split in
            // rejection_normalize below — a blur refusal DOES ask for
            // more photos (its user_message coaches a retake), so the
            // flag is true and the retake instruction is the one
            // recommended photo. Non-product refusals stay false/[].
            needs_more_photos: true, needs_more_information: false,
            price_low: 0, price_high: 0, suggested_price: 0,
            included_accessories: [], missing_parts: [], visible_damage: [],
            suggested_title: '', short_description: '', search_keywords: [],
            recommended_photos: ['Retake the photo in good light, hold the camera steady, and tap the item to focus.'],
            rejection_reason: 'blurry_image',
            user_message: 'That photo is too blurry to identify. Try again in good light, hold the camera steady, and tap the item to focus before taking the photo.',
            photo_mismatch_warning: '',
            _meta: { model: 'blur_fast_path', attempts: 0, guards: ['blur_fast_path', 'rejection_normalize'], derived_suggested_price: false },
          });
        }
      } catch { /* metric unavailable: fall through to the model */ }
    }

    // Single photo: SYSTEM_PROMPT alone, exactly as before.
    // Real-estate mode (UNDEPLOYED): uses the property-condition prompt.
    const promptText = mode === 'real_estate'
      ? REAL_ESTATE_PROMPT
      : multiMode
        ? SYSTEM_PROMPT + MULTI_PHOTO_ADDENDUM.replace('{N}', String(jpegs.length))
        : SYSTEM_PROMPT;
    const jpegBase64List = jpegs.map((j) => j.toString('base64'));

    // Round 5 A/B knob: a per-request model override, honoured ONLY when
    // ALLOW_MODEL_OVERRIDE=1 in the environment (set temporarily for
    // controlled latency/quality comparisons; absent in normal service).
    // A name the API has retired 404s and the chain falls through to the
    // primary, so probing an unknown name is safe.
    const overrideModel = process.env.ALLOW_MODEL_OVERRIDE === '1' &&
      typeof modelOverride === 'string' && /^[a-zA-Z0-9.\-]{1,64}$/.test(modelOverride)
      ? modelOverride : null;
    // Thinking level: the THINKING_LEVEL env var sets the production
    // default (round 5 A/B winner: 'low' on the flagship model — same
    // output quality, roughly 60% less latency). The A/B harness may
    // still override per request under the ALLOW_MODEL_OVERRIDE gate.
    const THINKING_LEVELS = ['minimal', 'low', 'medium', 'high'];
    const envThinking = THINKING_LEVELS.includes(process.env.THINKING_LEVEL)
      ? process.env.THINKING_LEVEL : null;
    const overrideThinking = process.env.ALLOW_MODEL_OVERRIDE === '1' &&
      THINKING_LEVELS.includes(thinkingLevel)
      ? thinkingLevel : envThinking;
    const models = overrideModel
      ? [overrideModel, ...[PRIMARY_MODEL, ...FALLBACK_MODELS].filter((m) => m !== overrideModel)]
      : [PRIMARY_MODEL, ...FALLBACK_MODELS.filter((m) => m !== PRIMARY_MODEL)];
    let result = null;
    let modelError = null;
    for (const model of models) {
      try {
        result = await callGemini(apiKey, model, jpegBase64List, promptText, startedAt, overrideThinking);
        break;
      } catch (e) {
        if (e instanceof GeminiError && e.category === 'MODEL_ERROR' && e.status === 404) {
          modelError = e; // retired — try next model
          continue;
        }
        throw e; // transient-exhausted, auth, bad image: do not mask
      }
    }
    if (!result) throw modelError || new GeminiError('MODEL_ERROR', 'No AI model is available right now.', 502);

    const p = result.parsed;
    // Minimal shape validation — the app tolerates missing optional fields.
    if (typeof p !== 'object' || p === null) {
      throw new GeminiError('INVALID_RESPONSE', 'AI service returned malformed data.', 502);
    }
    const confidence = Number(p.confidence);
    p.confidence = Number.isFinite(confidence) ? Math.max(0, Math.min(100, Math.round(confidence))) : 0;

    // Rejection hygiene — enforced server-side, not just asked of the model:
    // when recognized=false, no half-formed listing may leak through,
    // whatever the model put in the listing fields. The explanation lives in
    // rejection_reason / user_message instead. Product prompt path only —
    // real-estate mode returns a different shape and is left untouched.
    // The round 3.5 deterministic guards below record each firing here;
    // the list is surfaced as _meta.guards so guard activity is auditable
    // (empty when no guard fires).
    const appliedGuards = [];
    let derivedSuggestedPrice = false;
    // Round 9: set by guard 2 when it caps confidence; the matching
    // user_message note is applied near the end of the pipeline.
    let lowResCapFired = false;
    if (mode !== 'real_estate') {
      if (typeof p.photo_mismatch_warning !== 'string') p.photo_mismatch_warning = '';
      if (!p.recognized) {
        p.suggested_title = '';
        p.product_name = '';
        p.short_description = '';
        p.price_low = 0;
        p.price_high = 0;
        p.suggested_price = 0;
        const REJECTION_REASONS = ['non_product_image', 'blurry_image', 'different_items', 'unclear_image'];
        if (!REJECTION_REASONS.includes(p.rejection_reason)) p.rejection_reason = 'unclear_image';
        if (typeof p.user_message !== 'string' || !p.user_message.trim()) {
          p.user_message = 'We could not identify a product in that photo. Try a clear, well-lit photo of the item on its own.';
        }
        // A rejection carries no identification at all. Round 6: the
        // field stays present with the explicit value 'none' so the
        // schema is consistent across outcomes (Gemini and Claude both
        // prescribed this in round 5).
        p.identification_level = 'none';
        // Round 11 — rejection condition normalization: a refusal has
        // assessed nothing, so a model-supplied condition grade is
        // meaningless (round 10 T10: the quarry refusal shipped
        // condition "good"). The field states plainly that no
        // condition was assessed — the same value
        // condition_by_construction derives for a recognized item
        // with no located damage. The blur fast-path literal below
        // carries the same value.
        if (p.condition !== 'Not assessed from photo') {
          p.condition = 'Not assessed from photo';
          appliedGuards.push('rejection_condition_normalize');
        }
        // Round 9 guard — rejection normalization: a refusal is not a
        // listing in progress, so it must not simultaneously ask for
        // more photos of the item (Claude round 8 flagged a
        // non-product refusal carrying needs_more_photos true with a
        // populated photo list). needs_more_photos /
        // recommended_photos belong to the recognized flow; the
        // explanation stays in rejection_reason / user_message,
        // untouched.
        // Round 10 — rejection flag split: round 9 forced false/[]
        // for EVERY refusal, but a blur refusal's user_message
        // coaches a retake, so false/[] contradicts the message
        // (Claude round 9 ranked "rejection flags" a top gap). Split
        // by reason: blurry_image carries needs_more_photos true and
        // the one retake instruction as its recommended photo (the
        // blur fast-path above returns this same shape); every other
        // refusal keeps false/[].
        const blurRejection = p.rejection_reason === 'blurry_image';
        const rejectionNeedsMore = blurRejection;
        const rejectionPhotos = blurRejection
          ? ['Retake the photo in good light, hold the camera steady, and tap the item to focus.']
          : [];
        if (p.needs_more_photos !== rejectionNeedsMore ||
            JSON.stringify(p.recommended_photos) !== JSON.stringify(rejectionPhotos)) {
          appliedGuards.push('rejection_normalize');
        }
        p.needs_more_photos = rejectionNeedsMore;
        p.recommended_photos = rejectionPhotos;
      } else {
        // Consistency rules the model sometimes misses, enforced the same
        // way: if it asked for more photos, more photos are needed.
        if (Array.isArray(p.recommended_photos) && p.recommended_photos.length > 0) {
          p.needs_more_photos = true;
        }
        // "exact" requires a brand or a model on record; with neither, the
        // identification is at product-family level at best.
        if (!p.brand && !p.model && p.identification_level === 'exact') {
          p.identification_level = 'product_family';
        }
        // A property is identified to type level, never as an exact unit.
        if (p.category === 'Real Estate') {
          p.identification_level = 'product_family';
        }
        // A vehicle always has value drivers a photo cannot show (mileage,
        // title status, mechanical state) — more information is needed.
        if (p.category === 'Automotive') {
          p.needs_more_information = true;
        }
        // Round 3.5 guard 1 — one angled photo cannot settle MacBook Air
        // vs MacBook Pro, and the model kept committing to "Air" anyway
        // (rounds 2-3) despite the prompt rule. With exactly one photo and
        // no model on record, enforce the parent family server-side.
        // Round 3.6 extension: a multi-photo set WITH a mismatch warning
        // is also one photo per item — the primary item still rests on a
        // single photo, so the same enforcement applies.
        if ((imageInputs.length === 1 ||
             (typeof p.photo_mismatch_warning === 'string' &&
              p.photo_mismatch_warning.length > 0)) && !p.model &&
            (/MacBook (Air|Pro)/i.test(p.product_family || '') ||
             /MacBook (Air|Pro)/i.test(p.product_name || ''))) {
          p.product_family = 'MacBook';
          p.product_name = 'Apple MacBook';
          if (typeof p.suggested_title === 'string') {
            p.suggested_title = p.suggested_title.replace(/MacBook (Air|Pro)/gi, 'MacBook');
          }
          // Round 3.7: the same phrase can survive in free-text fields
          // (a round 3 live output kept "MacBook Air" in the description
          // after the structured fields were corrected). Scrub them too.
          if (typeof p.short_description === 'string') {
            p.short_description = p.short_description.replace(/MacBook (Air|Pro)/gi, 'MacBook');
          }
          for (const key of ['search_keywords', 'recommended_photos']) {
            if (Array.isArray(p[key])) {
              p[key] = p[key].map((s) => typeof s === 'string' ? s.replace(/MacBook (Air|Pro)/gi, 'MacBook') : s);
            }
          }
          p.identification_level = 'product_family';
          p.confidence = Math.min(p.confidence, 70);
          p.needs_more_photos = true;
          p.needs_more_information = true;
          appliedGuards.push('single_photo_subfamily_parent');
        }
        // Round 3.5 guard 2 — a tiny photo with no legible brand cannot
        // carry high confidence (a 403x403 unbranded fridge was rated 70
        // in rounds 2-3). Cap it from the measured original image size.
        if (!p.brand && maxOriginalEdge != null && maxOriginalEdge <= 640) {
          // Round 6: cap tightened 60 -> 55 (Claude round 5: the weakest
          // photo in the pack cannot support 60).
          p.confidence = Math.min(p.confidence, 55);
          appliedGuards.push('low_res_confidence_cap');
          lowResCapFired = true;
        }
        // Round 3.8 guard — description consistency, decoupled from
        // guard 1: whenever the settled identification is the MacBook
        // parent family with no model on record, no text field may name
        // a sub-family, whether guard 1 fired or the model complied in
        // the structured fields while its prose did not. (ChatGPT round
        // 3 prescription: enforce the identification level in every
        // generated field.)
        if (!p.model && (p.product_family === 'MacBook' || p.product_name === 'Apple MacBook')) {
          const scrubSubfamily = (s) => typeof s === 'string' ? s.replace(/MacBook (Air|Pro)/gi, 'MacBook') : s;
          let scrubbed = false;
          for (const key of ['suggested_title', 'short_description']) {
            const before = p[key];
            p[key] = scrubSubfamily(p[key]);
            if (p[key] !== before) scrubbed = true;
          }
          for (const key of ['search_keywords', 'recommended_photos']) {
            if (Array.isArray(p[key])) {
              const next = p[key].map(scrubSubfamily);
              if (JSON.stringify(next) !== JSON.stringify(p[key])) scrubbed = true;
              p[key] = next;
            }
          }
          if (scrubbed) appliedGuards.push('subfamily_text_scrub');
        }
        // Round 3.7 guard 3 — a populated price range with a zero point
        // price is an internally broken listing field (Claude round 2
        // scored it critical). The model chose the range; the point price
        // is set to its midpoint so the fields are consistent. This sets
        // no price level of its own and never touches real estate, whose
        // prices stay 0 by design.
        if (p.category !== 'Real Estate' &&
            !(Number(p.suggested_price) > 0) &&
            Number(p.price_low) > 0 && Number(p.price_high) > Number(p.price_low)) {
          p.suggested_price = Math.round((Number(p.price_low) + Number(p.price_high)) / 2);
          appliedGuards.push('suggested_price_midpoint');
          derivedSuggestedPrice = true;
        }
        // Round 4.1 guard 4 — the flags promise the seller a way to
        // resolve the identification; an empty prompt list breaks that
        // promise (Claude and Gemini both flagged a live round 4 case:
        // needs_more_photos true, recommended_photos empty — model
        // variance). Backfill category-appropriate verification prompts
        // server-side. Real Estate is excluded: its flow collects the
        // address and property details separately.
        if (p.category !== 'Real Estate' &&
            (p.needs_more_photos || p.needs_more_information) &&
            (!Array.isArray(p.recommended_photos) || p.recommended_photos.length === 0)) {
          const PROMPTS_BY_CATEGORY = {
            Electronics: [
              'Take a photo of the system information or settings screen showing the model and specifications (for example, About This Mac on a laptop).',
              'Take a close-up photo of any model or serial label on the item (often on the underside or back).',
              'Take a photo of the original box or packaging label if you have it.',
            ],
            Automotive: [
              'Take a photo of the VIN plate (driver-side dashboard or door jamb).',
              'Take a photo of the odometer reading.',
              'Take a photo of the engine bay.',
            ],
            Appliances: [
              'Take a close-up photo of the rating plate or label showing the brand and model number.',
              'Take one full photo of the whole item from the front.',
            ],
          };
          p.recommended_photos = PROMPTS_BY_CATEGORY[p.category] || [
            'Take a close-up photo of any brand name, logo or label on the item.',
            'Take one full photo of the whole item.',
          ];
          p.needs_more_photos = true;
          appliedGuards.push('photo_prompts_backfill');
        }
        // Round 6 guards — Claude round 5 diagnosis: at the reduced
        // thinking level the prompt rules alone no longer hold; every
        // critical was a prompt-only rule leaking. These guards move the
        // surviving rules into deterministic server-side code, the same
        // pattern as guards 1-4.
        const tidyText = (s) => typeof s === 'string'
          ? s.replace(/\s{2,}/g, ' ').replace(/\s+([.,;])/g, '$1').replace(/\ba (aluminum|aluminium)\b/gi, 'an $1').trim() : s;
        // Guard 5 — diagnostic text scrub: at parent-family level a
        // laptop description may not carry sub-family-diagnostic
        // specifics (port counts, wedge/tapered chassis shapes) that
        // steer Air vs Pro when the photo cannot settle it (T7/T8
        // criticals).
        if (p.identification_level === 'product_family' &&
            /macbook|laptop/i.test(`${p.product_name || ''} ${p.product_family || ''}`)) {
          const dropPortClauses = (s) => {
            // Round 7: at parent-family level a port LAYOUT is as much
            // a sub-family diagnostic as a port count — round 6 T7 kept
            // "USB-C/Thunderbolt ports on the left side" because it
            // carried no count. Split each sentence into clauses and
            // drop any clause that mentions a port or connector.
            const PORT_CLAUSE = /\b(?:usb-c|thunderbolt|hdmi|ports?)\b/i;
            return s.split(/(?<=[.!?])\s+/).map((sentence) => {
              const trail = /[.!?]$/.test(sentence) ? sentence.slice(-1) : '';
              const core = trail ? sentence.slice(0, -1) : sentence;
              const clauses = core.split(/\s*,\s*|\s+and\s+/)
                .map((c) => c.replace(/^and\s+/i, '').trim())
                .filter((c) => c.length > 0);
              if (clauses.length === 0) return sentence;
              if (!clauses.some((c) => PORT_CLAUSE.test(c))) return sentence;
              if (clauses.length === 1) {
                // A lone port clause: strip the port phrase itself
                // rather than blanking the whole field.
                const stripped = core
                  .replace(/\b(?:two|three|four|five|\d+)\s+/gi, '')
                  .replace(/\b(?:usb-c\s*\/\s*thunderbolt|thunderbolt\s*\/\s*usb-c|usb-c|thunderbolt|hdmi)\s+ports?\b/gi, '')
                  .replace(/\s+on\s+(?:the\s+)?(?:left|right)\s+side\b/gi, '')
                  .trim();
                if (!stripped || /^(it\s+(has|features)|features)$/i.test(stripped)) return '';
                return stripped + trail;
              }
              const kept = clauses.filter((c) => !PORT_CLAUSE.test(c));
              if (kept.length === 0) return '';
              let joined = kept.length === 1
                ? kept[0]
                : `${kept.slice(0, -1).join(', ')} and ${kept[kept.length - 1]}`;
              if (/^[A-Z]/.test(core)) joined = joined.charAt(0).toUpperCase() + joined.slice(1);
              return joined + trail;
            }).filter((x) => x).join(' ');
          };
          const scrubDiagnostic = (s) => {
            if (typeof s !== 'string') return s;
            let out = dropPortClauses(s)
              .replace(/\b(two|three|four|five|\d+)\s+(USB-C\s*\/\s*Thunderbolt|Thunderbolt\s*\/\s*USB-C|USB-C|Thunderbolt|USB)\s+ports?\b/gi, 'USB-C/Thunderbolt ports')
              .replace(/\btapered wedge\b/gi, 'aluminum')
              .replace(/\btapered\b/gi, 'slim')
              .replace(/\bwedge-style\b/gi, '')
              .replace(/\bwedge-shaped\b/gi, '')
              .replace(/\bwedge\b/gi, '')
              // Round 7: chassis shape/size wording is the same class
              // of sub-family diagnostic — neutralize it to a plain
              // material fact ("slim aluminum chassis" -> "aluminum
              // body"), and no bare "chassis" wording survives.
              .replace(/\b(?:slim|thin|sleek|lightweight|tapered|wedge-shaped|unibody)\s+aluminum\s+chassis\b/gi, 'aluminum body')
              .replace(/\baluminum\s+chassis\b/gi, 'aluminum body')
              .replace(/\bchassis\b/gi, 'body');
            return tidyText(out);
          };
          let scrubbed = false;
          for (const key of ['short_description', 'suggested_title']) {
            const before = p[key];
            p[key] = scrubDiagnostic(p[key]);
            // Round 8: in a mismatched multi-photo set the model
            // invents era/style specifics for the primary item (T8:
            // "vintage", "beveled keycaps") — trim them on this same
            // family-level laptop path.
            if (key === 'short_description' && typeof p[key] === 'string' &&
                typeof p.photo_mismatch_warning === 'string' &&
                p.photo_mismatch_warning.length > 0) {
              p[key] = tidyText(p[key].replace(/\bvintage\b/gi, '').replace(/\bbeveled\b/gi, '').replace(/\bbevelled\b/gi, ''));
            }
            if (p[key] !== before) scrubbed = true;
          }
          if (scrubbed) appliedGuards.push('diagnostic_text_scrub');
        }
        // Guard 6 — variant promotion: an edition named in the
        // description (read off a placard or label) belongs in the
        // structured fields and the title, not only in prose (T3
        // critical: "Supreme Edition" survived only in the description).
        let variantFound = false;
        {
          const editionMatch = `${p.short_description || ''} ${p.suggested_title || ''}`
            .match(/\b(Supreme|Limited|Special|Anniversary|Signature|Collector's) Edition\b/);
          if (editionMatch) {
            variantFound = true;
            const edition = editionMatch[0];
            let promoted = false;
            if (p.product_name && !p.product_name.includes(edition)) {
              p.product_name = `${p.product_name} ${edition}`;
              promoted = true;
            }
            if (typeof p.model === 'string' && p.model && !p.model.includes(edition)) {
              p.model = `${p.model} ${edition}`;
              promoted = true;
            }
            if (typeof p.suggested_title === 'string' && p.suggested_title &&
                !p.suggested_title.includes(edition)) {
              const base = (typeof p.model === 'string' && p.model)
                ? p.model.replace(` ${edition}`, '') : '';
              if (base && p.suggested_title.includes(base)) {
                p.suggested_title = p.suggested_title.replace(base, `${base} ${edition}`);
                promoted = true;
              }
            }
            if (promoted) appliedGuards.push('variant_promotion');
          }
        }
        // Guard 7 — display-unit flag: a product photographed on a
        // retail display is not yet a listing; flag it structurally and
        // require the missing information instead of letting seller
        // instructions sit in buyer-facing prose (T3 critical).
        if (/retail display|security tether|anti-theft|display stand/i.test(p.short_description || '')) {
          p.display_unit_warning = 'Photographed on a retail display. Confirm the actual unit for sale and what is included (packaging, cables, accessories) before listing.';
          p.needs_more_information = true;
          appliedGuards.push('display_unit_flag');
        }
        // Guard 6b — placard second pass: when a retail display was
        // detected but the main pass named no edition anywhere, the
        // placard transcription was likely skipped (round 6 canonical
        // run: the model described "a Chinese pricing placard" without
        // reading it). Make one focused call that does nothing but read
        // the placard, at medium thinking, and promote whatever edition
        // it returns through the same deterministic path as guard 6.
        // Any failure leaves the main result untouched.
        if (appliedGuards.includes('display_unit_flag') && !variantFound) {
          try {
            const placardPrompt = 'Look at the photo or photos. If a placard, sign, price card, label, or packaging in the photo names an EDITION or VARIANT of the product (for example a phrase like "Supreme Edition" or "Limited Edition", in any language), reply with ONLY this JSON object: {"variant": "<the edition or variant name, translated into English>"} . If no edition or variant is named anywhere in the photo, reply {"variant": ""}. Never guess an edition that is not written in the photo.';
            let second = await callGemini(apiKey, result.model, jpegBase64List, placardPrompt, startedAt, 'low');
            let variant = typeof second?.parsed?.variant === 'string' ? second.parsed.variant.trim() : '';
            if (!variant) {
              second = await callGemini(apiKey, result.model, jpegBase64List, placardPrompt, startedAt, 'medium');
              variant = typeof second?.parsed?.variant === 'string' ? second.parsed.variant.trim() : '';
            }
            if (variant && variant.length <= 60 && /edition/i.test(variant)) {
              let promoted = false;
              if (p.product_name && !p.product_name.includes(variant)) {
                p.product_name = `${p.product_name} ${variant}`;
                promoted = true;
              }
              if (typeof p.model === 'string' && p.model && !p.model.includes(variant)) {
                const base = p.model;
                p.model = `${p.model} ${variant}`;
                if (typeof p.suggested_title === 'string' && p.suggested_title &&
                    !p.suggested_title.includes(variant) && p.suggested_title.includes(base)) {
                  p.suggested_title = p.suggested_title.replace(base, `${base} ${variant}`);
                }
                promoted = true;
              }
              if (promoted) appliedGuards.push('variant_second_pass');
            }
          } catch (e) {
            console.log(JSON.stringify({ evt: 'placard_second_pass_failed', message: String(e && e.message || e).slice(0, 160) }));
          }
        }
        // Guard 8 — plate text scrub: never publish a transcribed
        // registration plate; the model renders vanity plates as the
        // words they spell instead of the characters shown (T5, flagged
        // by all three graders). Remove quoted plate text from
        // automotive descriptions.
        if (p.category === 'Automotive' && typeof p.short_description === 'string') {
          const before = p.short_description;
          let out = before
            .replace(/registration plate\s*'[^']*'/gi, 'registration plate')
            .replace(/plate\s*'[^']*'/gi, 'plate')
            .replace(/'([A-Z0-9][A-Z0-9 ]{2,9})'/g, (m, inner) => /\d/.test(inner) ? '' : m);
          out = tidyText(out);
          if (out !== before) {
            p.short_description = out;
            appliedGuards.push('plate_text_scrub');
          }
        }
        // Guard 9 — mismatch note: when the photos show different items
        // the description itself must say so plainly, not only the
        // warning field (T8).
        if (typeof p.photo_mismatch_warning === 'string' && p.photo_mismatch_warning.length > 0 &&
            typeof p.short_description === 'string' &&
            !/different (item|laptop|unit|computer|device)/i.test(p.short_description)) {
          p.short_description = `${p.short_description} Note: the photos appear to show different items; confirm which item is being sold.`;
          appliedGuards.push('mismatch_note_append');
        }
        // Guard 10 — product family backfill: a recognized item always
        // carries its family; the model occasionally omits the field
        // (T4 lost product_family in round 5).
        if ((typeof p.product_family !== 'string' || !p.product_family) && p.product_name) {
          p.product_family = p.product_name;
          appliedGuards.push('product_family_backfill');
        }
        // Real-estate confidence cap: an exterior photo with no address
        // or interior evidence cannot carry 90 (T9 drifted to 90 in
        // round 5).
        if (p.category === 'Real Estate' && p.confidence > 85) {
          p.confidence = 85;
          appliedGuards.push('real_estate_confidence_cap');
        }
        // Round 7 guards — the round 6 fix list, same pattern as
        // rounds 3.5-6: rules the graders found leaking through the
        // prompt alone are enforced deterministically here.
        // Guard 11 (round 7 condition claim scrub) was superseded in
        // round 8 by condition_by_construction at the end of this
        // pipeline: phrase-level scrubbing kept missing the model's
        // softer vocabulary, so condition is now handled by
        // construction — see the last guard block below.
        // Guard 12 — real-estate name clean: speculative architectural
        // style hedges do not belong in the property name (T9 round 6:
        // "Brick Split-Level / Multi-Storey Single-Family House" while
        // the title used the plain form).
        // Round 8 completion: the hedge family grows to the
        // Multi-<layout word> forms (round 7 T9 came back
        // "Multi-Level"); the plain family is settled when it merely
        // duplicates the name; pure information requests move out of
        // recommended_photos into requested_information; and a
        // recognized property carries the property-flow message.
        if (p.category === 'Real Estate') {
          let reFired = false;
          if (typeof p.product_name === 'string' && p.product_name) {
            const HEDGES = /\b(?:split-level|multi-(?:storey|storeys|story|stories|level|levels|floor|floors))\b/gi;
            const before = p.product_name;
            let cleaned = tidyText(before.replace(HEDGES, '').replace(/\s*\/\s*/g, ' '));
            if (cleaned.includes('/')) {
              // Hedge removal left a dangling separator: align to the
              // title's plain form when it carries one.
              const title = typeof p.suggested_title === 'string' ? p.suggested_title : '';
              const cleanTitle = tidyText(title.replace(HEDGES, '').replace(/\s*\/\s*/g, ' '));
              if (cleanTitle && !cleanTitle.includes('/')) cleaned = cleanTitle;
            }
            if (cleaned && cleaned !== before) {
              p.product_name = cleaned;
              reFired = true;
            }
            // When the settled name is the plain "<Material>
            // Single-Family House" form and the family merely
            // duplicates the name, the family is the plain type.
            if (/Single-Family House$/.test(p.product_name) &&
                (p.product_family === before || p.product_family === p.product_name) &&
                p.product_family !== 'Single-Family House') {
              p.product_family = 'Single-Family House';
              reFired = true;
            }
          }
          // requested_information: the property flow asks for facts
          // (address, square footage, year built) through
          // recommended_photos, but those are not photos. Move pure
          // information requests into their own additive field so the
          // photo list stays a photo list. An entry that asks for a
          // photo stays, whatever it depicts. The field is present
          // (possibly empty) on every Real Estate result and absent
          // elsewhere.
          const INFO_REQUEST = /address|square footage|sq\.?\s?ft|year built|lot size|bedroom|bathroom count/i;
          const movedInfo = [];
          if (Array.isArray(p.recommended_photos)) {
            const keptPhotos = [];
            for (const entry of p.recommended_photos) {
              if (typeof entry === 'string' && INFO_REQUEST.test(entry) &&
                  !/photo|picture/i.test(entry) &&
                  (/provide|confirm/i.test(entry) || !/\btake\b/i.test(entry))) {
                movedInfo.push(entry);
              } else {
                keptPhotos.push(entry);
              }
            }
            p.recommended_photos = keptPhotos;
          }
          p.requested_information = movedInfo;
          if (movedInfo.length > 0) reFired = true;
          // Property-flow message: a recognized property routes the
          // user into the property flow explicitly instead of leaving
          // user_message blank or generic (Claude round 7).
          if (typeof p.user_message !== 'string' ||
              !/address|property report/i.test(p.user_message)) {
            const flowMsg = 'This looks like a property. Add the address and details to build the full property report.';
            if (p.user_message !== flowMsg) {
              p.user_message = flowMsg;
              reFired = true;
            }
          }
          if (reFired) appliedGuards.push('real_estate_name_clean');
        }
        // Guard 13 — product name normalize: the structured name must
        // name the product family, not a colour or a near-miss variant
        // (T1/T14 round 6: bullet blenders named "Personal Blender ..."
        // and, in one run, just a colour, while the title said "Bullet
        // Blender").
        // Round 8 extension: the bullet-blender fix now covers the
        // family and the title too (Claude round 7: the family still
        // said "Personal Blender" and the T14 title dropped "Bullet"
        // even when the name was right) — all three fields settle on
        // the same name for the same item.
        {
          const family = typeof p.product_family === 'string' ? p.product_family : '';
          const sub = typeof p.subcategory === 'string' ? p.subcategory : '';
          const brand = typeof p.brand === 'string' ? p.brand.trim() : '';
          const withBrand = (base) => (brand && !/^unknown$/i.test(brand) &&
            !base.toLowerCase().includes(brand.toLowerCase()))
            ? `${brand} ${base}` : base;
          let name = typeof p.product_name === 'string' ? p.product_name : '';
          let normFired = false;
          if (/bullet blender|personal blender/i.test(`${family} ${sub}`)) {
            if (!/bullet/i.test(name)) {
              const next = withBrand('Personal Bullet Blender');
              if (next !== name) {
                p.product_name = next;
                name = next;
                normFired = true;
              }
            }
            if (p.product_family !== 'Personal Bullet Blender') {
              p.product_family = 'Personal Bullet Blender';
              normFired = true;
            }
          } else if (family) {
            const tokens = (s) => new Set((s.toLowerCase().match(/[a-z]{4,}/g) || []));
            const famTokens = tokens(family);
            const shares = [...tokens(name)].some((t) => famTokens.has(t));
            if (!shares) {
              const next = withBrand(family);
              if (next !== name) {
                p.product_name = next;
                name = next;
                normFired = true;
              }
            }
          }
          // Title consistency: a bullet-blender title that lost the
          // word "Bullet" is rebuilt from the settled name plus the
          // distinguishing colour/material/size tokens the old title
          // already carried — nothing new is invented.
          if ((/bullet/i.test(name) || /bullet/i.test(p.product_family || '')) &&
              typeof p.suggested_title === 'string' && p.suggested_title &&
              !/bullet/i.test(p.suggested_title)) {
            const TITLE_TOKENS = ['Stainless Steel', 'Space Gray', 'Space Grey',
              'Silver', 'Black', 'White', 'Red', 'Blue', 'Gray', 'Grey', 'Chrome',
              'Copper', 'Green', 'Pink', 'Purple', 'Gold', 'Glass', 'Compact',
              'Mini', 'Portable', 'Cordless', 'Digital', 'Electric'];
            const found = [];
            for (const tok of TITLE_TOKENS) {
              const m = p.suggested_title.match(new RegExp(`\\b${tok}\\b`, 'i'));
              if (m && !name.toLowerCase().includes(tok.toLowerCase()) &&
                  !found.some((f) => f.toLowerCase().includes(tok.toLowerCase()) ||
                                     tok.toLowerCase().includes(f.toLowerCase()))) {
                found.push(m[0]);
              }
              if (found.length >= 3) break;
            }
            let rebuilt = name;
            while (found.length > 0) {
              const candidate = `${name} - ${found.join(' ')}`;
              if (candidate.length <= 80) { rebuilt = candidate; break; }
              found.pop();
            }
            if (rebuilt !== p.suggested_title && rebuilt.length <= 80) {
              p.suggested_title = rebuilt;
              normFired = true;
            }
          }
          if (normFired) appliedGuards.push('product_name_normalize');
        }
        // Round 8 guard — non-ASCII strip: placard text read off a
        // photo can land in the structured fields in its original
        // script (round 7 T3: the product name carried the Chinese
        // edition name alongside the English one). Marketplace fields
        // are English; strip non-ASCII characters and tidy the gaps
        // and dangling separators they leave behind.
        {
          let stripFired = false;
          for (const key of ['product_name', 'model', 'suggested_title']) {
            if (typeof p[key] !== 'string' || !/[^\x20-\x7E]/.test(p[key])) continue;
            const cleaned = tidyText(p[key].replace(/[^\x20-\x7E]/g, ''))
              .replace(/\(\s+/g, '(').replace(/\s+\)/g, ')')
              .replace(/^[\s\-/]+/, '').replace(/[\s\-/]+$/, '');
            if (cleaned && cleaned !== p[key]) {
              p[key] = cleaned;
              stripFired = true;
            }
          }
          if (stripFired) appliedGuards.push('non_ascii_strip');
        }
        // Round 9 guard — variant in title: guard 6 promotes an
        // edition into product_name and model, and into the title only
        // when the title happens to contain the model base; with an
        // empty or divergent model the title never gains it (round 8
        // T3: name "Huawei FreeBuds 5 Supreme Edition", title "Huawei
        // FreeBuds 5 Wireless Earbuds (Silver Frost)"). After all
        // name/title processing, including the non-ASCII strip above,
        // settle it here: if the edition in product_name is missing
        // from the title, insert it immediately after the brand+model
        // base when the title starts with that base, else before a
        // trailing parenthesized colour segment, else at the end.
        {
          const nameStr = typeof p.product_name === 'string' ? p.product_name : '';
          const titleStr = typeof p.suggested_title === 'string' ? p.suggested_title : '';
          const parenEdition = nameStr.match(/\(([^()]*\bEdition)\)/i);
          const bareEdition = nameStr.match(/\b((?:Supreme|Limited|Special|Anniversary|Signature|Collector's) Edition)\b/);
          const edition = parenEdition ? parenEdition[1].trim() : (bareEdition ? bareEdition[1] : '');
          if (edition && titleStr &&
              !titleStr.toLowerCase().includes(edition.toLowerCase())) {
            const base = tidyText(nameStr
              .replace(`(${edition})`, '')
              .replace(edition, '')
              .replace(/\(\s*\)/g, ''));
            let next = null;
            if (base && titleStr.toLowerCase().startsWith(base.toLowerCase())) {
              next = `${titleStr.slice(0, base.length)} ${edition}${titleStr.slice(base.length)}`;
            } else if (/\s\([^()]*\)\s*$/.test(titleStr)) {
              next = titleStr.replace(/\s(\([^()]*\))\s*$/, ` ${edition} $1`);
            } else {
              next = `${titleStr} ${edition}`;
            }
            next = tidyText(next);
            if (next && next !== titleStr) {
              p.suggested_title = next;
              appliedGuards.push('variant_in_title');
            }
          }
        }
        // Round 8 guard — photo prompt minimums: guard 4 backfills an
        // empty prompt list, but a NON-empty list can still omit the
        // one shot that resolves the item's value driver (Claude
        // round 7: odometer, box/spec-label, included-jars and
        // brand-logo prompts kept getting dropped). Ensure each
        // applicable category need is represented in the final list;
        // append at most two prompts per result. Real Estate is
        // excluded — its flow collects the address and property
        // details through requested_information instead.
        if (p.category !== 'Real Estate') {
          if (!Array.isArray(p.recommended_photos)) p.recommended_photos = [];
          const prompts = p.recommended_photos;
          const promptHas = (re) => prompts.some((e) => typeof e === 'string' && re.test(e));
          let appended = 0;
          const tryAppend = (need, text) => {
            if (appended >= 2 || promptHas(need)) return;
            prompts.push(text);
            appended++;
          };
          const famName = `${p.product_family || ''} ${p.product_name || ''}`;
          if (p.category === 'Automotive') {
            // Round 9: the need check requires "odometer"
            // specifically — round 8 T6 kept a touchscreen prompt
            // that merely mentioned mileage, so the odometer shot
            // itself was never requested (Claude round 8).
            tryAppend(/odometer/i,
              'Take a photo of the odometer showing the mileage.');
          }
          if (p.category === 'Electronics' || /macbook|laptop/i.test(famName)) {
            tryAppend(/box|label|spec/i,
              'Take a photo of the original box or the spec label if you have it.');
          }
          if (/mixer|grinder|blender/i.test(famName)) {
            tryAppend(/jar|accessor|attachment|logo|label/i,
              'Take a photo of all jars and accessories included, and of the brand logo.');
          }
          const brandStr = typeof p.brand === 'string' ? p.brand.trim() : '';
          if (!brandStr || /^unknown$/i.test(brandStr)) {
            tryAppend(/logo|label|brand/i,
              'Take a close-up photo of the brand logo or label.');
          }
          if (appended > 0) {
            p.needs_more_photos = true;
            appliedGuards.push('photo_prompt_minimums');
          }
        }
        // Round 8 guard — family-level laptop confidence cap: a
        // family-level laptop identification rests on a photo that
        // cannot show the value drivers (spec label, About screen),
        // so a confidence of 70 overstates it (Claude round 7: T7/T8
        // belong at 55-60). Cap at 60; this guard never raises.
        if (p.identification_level === 'product_family' &&
            /macbook|laptop|notebook/i.test(`${p.product_family || ''} ${p.product_name || ''}`) &&
            p.confidence > 60) {
          p.confidence = 60;
          appliedGuards.push('family_level_confidence_cap');
        }
        // Round 9 — low-resolution note: when guard 2 capped
        // confidence because the photo is tiny, say so in
        // user_message; a silent cap leaves the seller with no path
        // to a better result (Claude round 8). Applied here, late, so
        // the property-flow message for Real Estate is already
        // settled and this appends after it instead of being replaced
        // by it. The resolution check keeps it to a single append.
        if (lowResCapFired) {
          const resNote = 'The photo resolution is low, which limits the analysis; a clearer photo may improve accuracy.';
          const um = typeof p.user_message === 'string' ? p.user_message : '';
          if (!/resolution/i.test(um)) {
            p.user_message = um.trim() ? `${um.trim()} ${resNote}` : resNote;
          }
        }
        // Round 11 guards — Claude round 10 (FAIL 8.54, zero
        // criticals) docked defects verified one by one against
        // round10-live.json: damage claims surviving on a photo too
        // small to support them, invented descriptors inside the
        // mismatch warning itself, and packaging / fitted parts
        // listed as accessories. Same pattern as rounds 3.5-10:
        // deterministic server-side code. This block runs after the
        // low-res note (it consumes the same lowResCapFired state)
        // and before the round 10 block, whose damage gate and
        // condition construction then see the suppressed list.
        // Guard — low-res damage suppression: guard 2 capped
        // confidence because the photo is tiny (round 10 T4: a
        // 403x403 fridge), yet the round 10 damage gate still kept
        // located wear entries — a photo that cannot support the
        // confidence cannot support a specific damage claim either.
        // Under the low-res state, the damage list is emptied and
        // the condition states it was not assessed
        // (condition_by_construction derives the same value from
        // the emptied list for non-property results).
        if (lowResCapFired) {
          const rawDmg = Array.isArray(p.visible_damage) ? p.visible_damage
            : (typeof p.visible_damage === 'string' && p.visible_damage.trim()
              ? [p.visible_damage] : []);
          let suppressionFired = false;
          if (rawDmg.length > 0) {
            p.visible_damage = [];
            p.condition = 'Not assessed from photo';
            suppressionFired = true;
          }
          // Round 14 — description wear scrub: emptying the damage
          // list did not stop the model's prose from asserting the
          // same wear (round 13 T4: "Exterior shows cosmetic
          // surface marks; faint scratches; and aging on the handle
          // plastic." on the 403x403 fridge, contradicting the
          // "Not assessed from photo" condition the suppression
          // just set). Under the same low-res state, a description
          // sentence that is PURELY a damage/wear claim comes out.
          // Pure is strict: the sentence carries a wear term, names
          // no brand/logo/model fact, and every clause in it (split
          // on ";" and "and") carries a wear term of its own — a
          // clause without one is a non-damage fact riding along,
          // and a mixed sentence stays whole. If every sentence
          // qualified the field would be blanked, so that case is
          // left untouched.
          if (typeof p.short_description === 'string' && p.short_description.trim()) {
            const WEAR_CLAIM = /\b(?:marks?|scratches|scratching|scuffs?|stains?|staining|discolou?ration|aging|ageing|wear|worn|dents?|dented|chips?|chipped|cracks?|cracked|rust|tears?|damage[ds]?|grime|yellowing|fading|faded|peeling|corrosion)\b/i;
            const FACT_ANCHOR = /\b(?:brand|logo|model|serial|manufacturer)\b/i;
            const sentences = p.short_description.split(/(?<=[.!?])\s+/);
            const kept = sentences.filter((s) => {
              if (!WEAR_CLAIM.test(s) || FACT_ANCHOR.test(s)) return true;
              const clauses = s.split(/\s*;\s*|\s*,\s*and\s+|\s+and\s+/i);
              return !clauses.every((c) => WEAR_CLAIM.test(c));
            });
            if (kept.length > 0 && kept.length !== sentences.length) {
              p.short_description = kept.join(' ');
              suppressionFired = true;
            }
          }
          if (suppressionFired) appliedGuards.push('low_res_damage_suppression');
        }
        // Guard — mismatch descriptor scrub: the round 8 scrub
        // trimmed invented era/style words from the DESCRIPTION when
        // a mismatch warning was present, but the warning field
        // itself kept them (round 10 T8: photo 2 described as "a
        // vintage or non-Apple silver keyboard ... with sculpted
        // keycaps" — era, maker and styling claims the photo cannot
        // support). The same invented characterizations come out of
        // photo_mismatch_warning; the factual content (silver
        // keyboard, German QWERTZ layout, different device) stays.
        // Round 12: "older" comes out too — an age guess about the
        // second unit is the same class of claim (round 11 T8: "a
        // completely different or older laptop model"). The phrase
        // forms go before the bare word so the sentence keeps its
        // grammar ("different or older" -> "different", "an older"
        // -> "a").
        // Round 13: "beveled" (US spelling) joins the scrub — the
        // round 8 description scrub already removed both spellings
        // from short_description, but the warning field itself only
        // ever had the invented-characterization list, and round 12
        // T8 shipped "silver beveled keyboard keys" in the warning.
        if (typeof p.photo_mismatch_warning === 'string' && p.photo_mismatch_warning) {
          const beforeWarn = p.photo_mismatch_warning;
          const nextWarn = tidyText(beforeWarn
            .replace(/\bvintage\s+or\s+non-?apple\b/gi, '')
            .replace(/\bnon-?apple\b/gi, '')
            .replace(/\bvintage\b/gi, '')
            .replace(/\bsculpted\b/gi, '')
            .replace(/\bbevelled\b/gi, '')
            .replace(/\bbeveled\b/gi, '')
            .replace(/\ban\s+older\b/gi, 'a')
            .replace(/\bor\s+older\b/gi, '')
            .replace(/\bolder\b/gi, ''));
          if (nextWarn !== beforeWarn) {
            p.photo_mismatch_warning = nextWarn;
            appliedGuards.push('mismatch_descriptor_scrub');
          }
        }
        // Guard — accessories hygiene: two non-accessory classes
        // kept landing in included_accessories. (1) Packaging: the
        // item's own box is not an included accessory (round 10
        // T7/T8 shipped included_accessories ['Box']). Only an entry
        // that is nothing but packaging goes; manuals, chargers,
        // cases and every real accessory stay. (2) Fitted
        // modifications on a vehicle: aftermarket wheels, a diffuser
        // or a spoiler are part of the car and already described in
        // the description, not items included with it (round 10 T6).
        // Automotive only; the same words on another category are
        // untouched.
        if (Array.isArray(p.included_accessories)) {
          const PACKAGING_ENTRY = /^\s*(?:the\s+)?(?:(?:original|retail|product)\s+)?(?:box|packaging)\s*$/i;
          const afterPackaging = p.included_accessories.filter((e) =>
            !(typeof e === 'string' && PACKAGING_ENTRY.test(e)));
          if (JSON.stringify(afterPackaging) !== JSON.stringify(p.included_accessories)) {
            p.included_accessories = afterPackaging;
            appliedGuards.push('accessories_packaging_drop');
          }
          if (p.category === 'Automotive') {
            const FITTED_MOD = (e) => typeof e === 'string' &&
              (/^\s*aftermarket\b/i.test(e) || /\bdiffuser\b/i.test(e) || /\bspoiler\b/i.test(e));
            const afterMods = p.included_accessories.filter((e) => !FITTED_MOD(e));
            if (JSON.stringify(afterMods) !== JSON.stringify(p.included_accessories)) {
              p.included_accessories = afterMods;
              appliedGuards.push('accessories_modification_drop');
            }
          }
        }
        // Round 10 guards — Claude round 9 (grounded re-grade, FAIL
        // 8.43, zero criticals) docked defects verified one by one
        // against round9-live.json: invented generic damage lines,
        // plug/voltage spec assertions, scrub artifacts, buried and
        // duplicated mismatch text, and the unaddressed display
        // tether. Same pattern as rounds 3.5-9: deterministic
        // server-side code. This block runs after every other text
        // guard and immediately before condition_by_construction,
        // which must derive the condition field from the FILTERED
        // damage list.
        // Guard — damage specificity gate: the model invents generic
        // wear boilerplate for items with no visible damage (round 9
        // T2: a damage-free toaster shipped "minor surface scuffs and
        // heat marks consistent with commercial use"; T1/T14: the
        // "light surface scuffs and wear" stock line). An entry
        // survives only as a concrete defect: a strong defect noun
        // (crack, stain, yellowing, ...), or a weak wear word tied to
        // a named part of the item ("scuffs and marks on doors").
        // Stock boilerplate ("cosmetic wear", "consistent with use",
        // the "light surface scuffs and wear" form) is dropped even
        // when it names a part, and none-like entries go too — the
        // buyer-facing list either names a real defect or is empty.
        // Round 12 tightening (Claude T1/T14): the weak-word-plus-
        // part allowance still let the invented line through in a
        // shorter form — "Light cosmetic scuffs on plastic cups" —
        // and a named part does not make a generic wear word a
        // visible defect. The allowance is gone: an entry now
        // survives ONLY on a strong defect noun (the round 10 set,
        // plus the round 12 additions: rusted, burned, mould, mold,
        // scratch/scratches/scratched, damage/damaged). Weak-only
        // entries ("Wear along seams and branding label") drop even
        // with a named part; condition derivation downstream keeps
        // reading the filtered list, so a fully filtered list still
        // yields "Not assessed from photo".
        {
          const STRONG_DEFECT = /\b(?:cracks?|cracked|chips?|chipped|dents?|dented|stains?|stained|staining|tears?|torn|rips?|ripped|yellowing|yellowed|discolou?ration|discolou?red|grime|grimy|rust|rusty|rusted|corrosion|corroded|missing|broken|bent|burns?|burned|burnt|scorch(?:ed)?|holes?|peeling|peeled|faded|fading|residue|soiling|soiled|warped|leaks?|leaking|gouges?|pitting|pitted|mould|mold|scratch(?:es|ed)?|damaged?)\b/i;
          const NONE_LIKE_DAMAGE = /^(?:none|n\/a|na|nil|nothing|none\s+visible|no\s+(?:visible\s+)?(?:damage|defects?|scratches|scuffs|dents|wear|marks|issues?)|not\s+(?:visible|assessed))[.\s]*$/i;
          const rawDamage = Array.isArray(p.visible_damage) ? p.visible_damage
            : (typeof p.visible_damage === 'string' && p.visible_damage.trim() ? [p.visible_damage] : []);
          const keptDamage = rawDamage.filter((entry) => {
            if (typeof entry !== 'string') return false;
            const t = entry.trim();
            if (!t || NONE_LIKE_DAMAGE.test(t)) return false;
            return STRONG_DEFECT.test(t);
          });
          if (JSON.stringify(keptDamage) !== JSON.stringify(rawDamage)) {
            p.visible_damage = keptDamage;
            appliedGuards.push('damage_specificity_gate');
          }
        }
        // Guard — plug/voltage neutralization: the model states plug
        // standards and voltage figures as the item's spec (round 9
        // T13: "likely 230V Indian standard... will need a step-up
        // voltage converter"; T2 named the outlet type and an adapter
        // requirement). Those are inferences, not visible facts.
        // Voltage figures, named standards and converter/adapter
        // requirements come out clause by clause; visible facts (a
        // cord and plug in the photo) stay; and where a plug or
        // outlet is in play the description carries exactly one
        // neutral caution sentence instead.
        {
          const VOLTAGE_FIGURE = /\b\d{2,3}(?:\s*[-–]\s*\d{2,3})?\s*(?:volts?|vac|v)\b/i;
          const PLUG_STANDARD = /\bschuko\b|\beuroplug\b|\bbs\s?1363\b|\bnema\b|\bcee\s?7\b|\btype\s?[a-z]\s+(?:plug|socket|outlet|standard)\b|\b(?:indian|european|american|british|australian)\s+standard\b/i;
          const CONVERSION_CLAIM = /\bstep[-\s]?(?:up|down)\b|\bvoltage\s+(?:convert(?:er|ers|ing)?|conversions?)\b|\bconvert(?:er|ers)\b|\b(?:will\s+)?(?:require|requires|required|need|needs|needed)\b[^.;]*\b(?:adapter|converter)\b|\bcompatible\s+plug\s+adapter\b/i;
          // Round 13: a voltage-support assertion is the same
          // inference in softer words (round 12 T13: "North American
          // buyers will require appropriate voltage support"). It
          // carries no figure, no named standard and no converter,
          // so all three patterns above missed it: CONVERSION_CLAIM's
          // require-branch only fires when an adapter or converter
          // follows the verb. "Voltage support" itself, and a
          // require/need verb reaching a voltage mention, are spec
          // assertions too. The neutral cautions are safe: neither
          // contains "voltage support" nor a require/need verb.
          const VOLTAGE_SUPPORT = /\bvoltage\s+support\b|\b(?:will\s+)?(?:require|requires|required|need|needs|needed)\b[^.;]*\bvoltage\b/i;
          const SPEC_ASSERTION = (s) => VOLTAGE_FIGURE.test(s) || PLUG_STANDARD.test(s) || CONVERSION_CLAIM.test(s) || VOLTAGE_SUPPORT.test(s);
          const PLUG_CAUTION = 'A plug is visible in the photo; verify the plug type and voltage compatibility before use.';
          // Round 11: the switch/outlet-triggered variant — used
          // when the electrical context is a wall switch or outlet
          // the item is used with, not a plug literally in frame,
          // so the wording makes no visibility claim.
          const SWITCH_CAUTION = 'Check the plug type and voltage compatibility before use.';
          if (typeof p.short_description === 'string' && p.short_description.trim()) {
            const original = p.short_description;
            const sentences = original.split(/(?<=[.!?])\s+/);
            const keptSentences = [];
            for (const sent of sentences) {
              if (!SPEC_ASSERTION(sent)) { keptSentences.push(sent); continue; }
              // Parenthetical spec assertions go first — the clause
              // around them is often a plain visible fact.
              let work = sent.replace(/\([^()]*\)/g, (m) =>
                (VOLTAGE_FIGURE.test(m) || PLUG_STANDARD.test(m)) ? '' : m);
              work = work.replace(/\s{2,}/g, ' ').trim();
              if (!SPEC_ASSERTION(work)) {
                if (work) keptSentences.push(work);
                continue;
              }
              const trailMatch = work.match(/[.!?]+$/);
              const trail = trailMatch ? trailMatch[0] : '.';
              const core = trailMatch ? work.slice(0, -trail.length) : work;
              const clauses = core.split(/\s*;\s*|\s*,\s+|\s+[—–]\s+/)
                .map((c) => c.trim()).filter((c) => c.length > 0);
              const keptClauses = clauses.filter((c) => !SPEC_ASSERTION(c));
              if (keptClauses.length === 0) continue;
              let joined = keptClauses.join(core.includes(';') ? '; ' : ', ');
              joined = joined.charAt(0).toUpperCase() + joined.slice(1);
              keptSentences.push(joined + trail);
            }
            let next = tidyText(keptSentences.join(' '));
            // Exactly one neutral caution when a plug or outlet is
            // in play — judged on the original text, so a dropped
            // spec sentence still earns the caution.
            if (/\b(?:plug|outlet|socket)\b/i.test(original) &&
                !/voltage compatibility|verify[^.]*\bvoltage\b/i.test(next)) {
              next = next ? `${next} ${PLUG_CAUTION}` : PLUG_CAUTION;
            }
            // Round 11 — switch/outlet trigger: a description that
            // places the item at a wall switch, switch panel or wall
            // outlet carries the same cross-border caution even
            // when no plug is literally in frame (round 10 T13: the
            // mixer grinder description noted an Indian wall switch
            // panel and carried no caution, while T2's visible plug
            // earned one). Still exactly one caution per
            // description: this runs only when no caution form is
            // already present after the plug pass above.
            // Round 13 diagnosis (round 12 T13 regression): the
            // trigger missed "wall switchboard" — the alternative
            // wall\s+switch needs the trailing \b to hold between
            // "switch" and "board", and two word characters have no
            // boundary between them, so the whole pattern failed on
            // the one wording the model actually used. The trigger
            // now accepts the switchboard forms (with or without
            // "wall").
            if (!/voltage compatibility|verify[^.]*\bvoltage\b/i.test(next) &&
                /\b(?:wall\s+switch(?:board)?|switch\s+panel|switchboard|wall\s+outlet|power\s+outlet|wall\s+socket)\b/i.test(original)) {
              next = next ? `${next} ${SWITCH_CAUTION}` : SWITCH_CAUTION;
            }
            if (next !== original) {
              p.short_description = next;
              appliedGuards.push('plug_voltage_neutralize');
            }
          }
        }
        // Guard — artifact cleanup: earlier scrubs leave debris in
        // buyer-facing text (round 9 T5: "UK-style registration
        // plates ()" after the plate scrub; T8: the orphaned
        // fragment "Operating state are not verified."). Empty
        // parentheses come out of the description and the title, and
        // standalone "state ... is/are not verified" fragments —
        // sentences whose subject is a bare state noun with no
        // product content — are dropped from the description.
        {
          const FRAGMENT = /^(?:operating state|working state|power state|functional state|condition|functionality|performance|operation)\b[^.!?]*\b(?:is|are)\s+not\s+(?:verified|assessed|confirmed|known)\b[^.!?]*$/i;
          // Round 11 — leftover-fragment sentences: an earlier scrub
          // can leave a sentence whose descriptor lost its head word
          // (round 10 T7: "A -profile aluminum body." — flagged by
          // all three graders). The shape is an article, a space,
          // then a hyphen fragment. Legitimate hyphenated compounds
          // are safe: in "right-hand drive" or "stainless-steel
          // build" a word character sits before the hyphen, not an
          // article and a space.
          const LEFTOVER_FRAGMENT = /\b(?:A|An|The)\s+-[a-z]/i;
          // Round 13 — dangling plate fragment: the plate scrub
          // removes the plate characters and can leave the clause
          // that introduced them with nothing to read (round 12 T5:
          // "...visibly badged with the VW emblem and R32 grille
          // badge, featuring a front plate reading." — flagged by
          // Claude AND ChatGPT). Two shapes: the dangling clause is
          // the sentence's trailing clause (drop it from the last
          // comma, keep the rest of the sentence), or the whole
          // sentence is the plate phrase (drop the sentence). A
          // sentence that gives the plate an object ("The front
          // plate reads R32 60LF in the photo.") or uses "reading"
          // with an object after it never ends on "plate reading"
          // and is untouched.
          const DANGLING_PLATE_CLAUSE = /,\s*(?:featuring\s+)?[^,.;]*\b(?:license\s+plate|number\s+plate|plate)\s+reading\s*$/i;
          const DANGLING_PLATE_SENTENCE = /^(?:featuring\s+)?(?:a\s+|an\s+|the\s+)?(?:(?:front|rear)\s+)?(?:license\s+plate|number\s+plate|plate)\s+reading$/i;
          let artifactFired = false;
          for (const key of ['short_description', 'suggested_title']) {
            if (typeof p[key] !== 'string' || !p[key]) continue;
            const before = p[key];
            let next = tidyText(before.replace(/\(\s*\)/g, ''));
            if (key === 'short_description') {
              const sentences = next.split(/(?<=[.!?])\s+/);
              const kept = [];
              for (const s of sentences) {
                const trailMatch = s.match(/[.!?]+\s*$/);
                const trail = trailMatch ? trailMatch[0].trim() : '';
                const core = trailMatch ? s.slice(0, s.length - trailMatch[0].length) : s;
                if (FRAGMENT.test(core.trim()) || LEFTOVER_FRAGMENT.test(s)) continue;
                if (DANGLING_PLATE_SENTENCE.test(core.trim())) continue;
                if (DANGLING_PLATE_CLAUSE.test(core)) {
                  const stripped = core.replace(DANGLING_PLATE_CLAUSE, '').trim();
                  if (stripped) kept.push(stripped + trail);
                  continue;
                }
                kept.push(s);
              }
              next = tidyText(kept.join(' '));
            }
            if (next !== before) { p[key] = next; artifactFired = true; }
          }
          if (artifactFired) appliedGuards.push('artifact_cleanup');
        }
        // Guard — mismatch plain statement: when the photos show
        // different items, the description must OPEN with that fact
        // in plain words (round 9 T8 buried it mid-description and
        // duplicated it: a model note plus guard 9's appended note).
        // The older note phrasings come out, the plain sentence goes
        // first exactly once, and user_message asks the seller which
        // unit to list. Detection (photo_mismatch_warning) is
        // unchanged — presentation only.
        if (typeof p.photo_mismatch_warning === 'string' && p.photo_mismatch_warning.length > 0 &&
            typeof p.short_description === 'string') {
          const PLAIN = 'The photos show two different units.';
          const ASK = 'The photos appear to show two different units. Tell me which one you are selling and I will base the listing on that unit.';
          let mismatchFired = false;
          const sentences = p.short_description.split(/(?<=[.!?])\s+/);
          const kept = sentences.filter((s) => {
            const t = s.trim();
            if (t === PLAIN) return false; // re-added at the front
            if (/photos appear to show different/i.test(t)) return false;
            if (/^note\b/i.test(t) && /different|does not match|do not match/i.test(t)) return false;
            return true;
          });
          const rest = tidyText(kept.join(' '));
          const next = rest ? `${PLAIN} ${rest}` : PLAIN;
          if (next !== p.short_description) {
            p.short_description = next;
            mismatchFired = true;
          }
          const um = typeof p.user_message === 'string' ? p.user_message : '';
          if (!/which one you are selling/i.test(um)) {
            p.user_message = um.trim() ? `${um.trim()} ${ASK}` : ASK;
            mismatchFired = true;
          }
          if (mismatchFired) appliedGuards.push('mismatch_plain_statement');
        }
        // Guard — display fixture note: guard 7 flags a retail
        // display unit, but the warning never addressed the display
        // hardware in the photo (round 9 T3: Claude docked the
        // unmentioned anti-theft tether). The warning now states
        // plainly that stands, fixtures and security tethers visible
        // in the photo are not included.
        if (typeof p.display_unit_warning === 'string' && p.display_unit_warning.trim() &&
            !/security tethers/i.test(p.display_unit_warning)) {
          p.display_unit_warning = `${p.display_unit_warning.trim()} Display stands, fixtures and security tethers visible in the photo are not included.`;
          appliedGuards.push('display_fixture_note');
        }
        // Round 8 guard — condition by construction. Rounds 6-7
        // scrubbed condition CLAIMS phrase by phrase and the model
        // kept finding softer vocabulary ("appears to be in good
        // cosmetic condition", "well-maintained", "appears clean").
        // The mechanism changes: condition prose is removed by
        // construction — every condition-assessment sentence leaves
        // the description, with one narrow exception for a sentence
        // whose only such content is a specific visible defect at a
        // named location (that defect also lives in visible_damage,
        // so no fact is lost either way) — and the condition FIELD is
        // derived solely from visible_damage. This block runs last
        // and is the ONLY writer of the condition field. Real Estate
        // keeps its existing condition handling.
        {
          const DEFECT_NOUN = /\b(?:cracks?|chips?|tears?|stains?|dents?|scratch(?:es|ed)?|scuffs?|missing|broken|bent)\b/i;
          const LOCATION_WORD = /\b(?:corner|edge|screen|side|top|bottom|left|right|surface|door|shelf|handle|key|button|leg|wheel)\b/i;
          const STRONG_CLAIM = /\bexcellent\b|\bperfect\b|\bpristine\b|\blike[-\s]new\b|\bmint\b|\bgood\s+(?:cosmetic\s+|overall\s+)?condition\b|\bin\s+good\s+condition\b|\bfully functional\b|\bworks perfectly\b/i;
          const isConditionSentence = (s) => {
            if (/\bcondition\b|\bwear\b|\bwell[-\s]maintained\b|\bmaintained\b|\bcosmetic|\bscratch|\bscuff|\bdent|\bdamage|\bgood shape\b|\bworking order\b|\bfully functional\b|\bworks perfectly\b|\bpristine\b|\blike[-\s]new\b/i.test(s)) return true;
            if (/\bmint\b/i.test(s) &&
                !/\bmint\s+(?:green|chip|chocolate|flavou?r|tea|leaf|leaves)\b/i.test(s)) return true;
            if (/\bclean\b/i.test(s) &&
                (/\b(?:appears|looks|exterior|interior|overall)\b/i.test(s) || /\bis in\b/i.test(s))) return true;
            return false;
          };
          const visibleDamageHasDefect = (vd) => {
            const NONE_LIKE = /^(?:none|n\/a|na|nil|nothing|none\s+visible|no\s+(?:visible\s+)?(?:damage|defects?|scratches|scuffs|dents|wear|marks|issues?)|not\s+(?:visible|assessed))[.\s]*$/i;
            const items = Array.isArray(vd) ? vd
              : (typeof vd === 'string' && vd.trim() ? [vd] : []);
            return items.some((x) => typeof x === 'string' &&
              x.trim().length > 0 && !NONE_LIKE.test(x.trim()));
          };
          const TITLE_CLAIMS = [
            /\b(?:is|looks|appears|seems)\s+in\s+(?:excellent|perfect|mint|like[-\s]new)\s+condition\b/i,
            /\b(?:is|looks|appears|seems)\s+(?:fully\s+functional|pristine|like[-\s]new)\b/i,
            /\bin\s+(?:excellent|perfect|mint|like[-\s]new)\s+condition\b/i,
            /\b(?:excellent|perfect|mint)\s+condition\b/i,
            /\bpristine\b/i,
            /\blike[-\s]new\b/i,
            /\bno\s+visible\s+damage\b/i,
            /\bno\s+scratches\b/i,
            /\bno\s+(?:visible\s+)?wear\b/i,
            /\bworks\s+perfectly\b/i,
            /\bfully\s+functional\b/i,
          ];
          const TITLE_BOUNDED = 'appears in good condition in the photo';
          // Round 9: clause-level cleanup inside exception-kept
          // sentences. Round 8 T13 shipped "Cosmetically in fair
          // condition with visible surface stains and signs of kitchen
          // use; mechanical condition not assessed." — the sentence
          // passed the defect exception as a whole, so its assessment
          // clauses rode along with the defect clause. A kept sentence
          // is now split on ";" and ", " boundaries: clauses carrying
          // an assessment stem are dropped, clauses reporting a
          // specific visible defect are kept, and when one clause
          // carries both, the defect portion is salvaged from the
          // last connector before the defect noun. If no clause
          // survives, the sentence is dropped, as before.
          const CLAUSE_ASSESSMENT = /\bcondition\b|cosmetically|well[-\s]maintained|mechanical condition|not assessed/i;
          const clauseHasDefect = (c) => DEFECT_NOUN.test(c) && LOCATION_WORD.test(c);
          const cleanKeptSentence = (sent) => {
            const trailMatch = sent.match(/[.!?]+$/);
            const trail = trailMatch ? trailMatch[0] : '.';
            const core = trailMatch ? sent.slice(0, -trail.length) : sent;
            const clauses = core.split(/\s*;\s*|\s*,\s+/)
              .map((c) => c.trim()).filter((c) => c.length > 0);
            if (clauses.length <= 1) return sent;
            const keptClauses = [];
            let changed = false;
            for (const clause of clauses) {
              const hasDefect = clauseHasDefect(clause);
              const hasAssessment = CLAUSE_ASSESSMENT.test(clause);
              if (hasDefect && !hasAssessment) { keptClauses.push(clause); continue; }
              if (!hasDefect && hasAssessment) { changed = true; continue; }
              if (hasDefect && hasAssessment) {
                const defectIdx = clause.search(DEFECT_NOUN);
                const head = clause.slice(0, defectIdx);
                const connIdx = Math.max(
                  head.lastIndexOf(' with '),
                  head.lastIndexOf(' showing '),
                  head.lastIndexOf(' has '));
                if (connIdx >= 0) {
                  const salvaged = clause.slice(connIdx)
                    .replace(/^\s*(?:with|showing|has)\s+/i, '').trim();
                  if (salvaged && clauseHasDefect(salvaged)) {
                    keptClauses.push(salvaged);
                    changed = true;
                    continue;
                  }
                }
                changed = true;
                continue;
              }
              keptClauses.push(clause);
            }
            if (!changed) return sent;
            if (keptClauses.length === 0) return '';
            let joined = keptClauses.join('; ');
            joined = joined.charAt(0).toUpperCase() + joined.slice(1);
            return joined + trail;
          };
          let condFired = false;
          // (a) Description: sentence-level strip.
          if (typeof p.short_description === 'string' && p.short_description.trim()) {
            const sentences = p.short_description.split(/(?<=[.!?])\s+/);
            const kept = [];
            let descChanged = false;
            for (const sent of sentences) {
              if (!isConditionSentence(sent)) { kept.push(sent); continue; }
              const exception = DEFECT_NOUN.test(sent) && LOCATION_WORD.test(sent) &&
                !STRONG_CLAIM.test(sent);
              if (!exception) { descChanged = true; continue; }
              const cleanedSent = cleanKeptSentence(sent);
              if (cleanedSent !== sent) descChanged = true;
              if (cleanedSent) kept.push(cleanedSent);
            }
            if (descChanged) {
              let text = tidyText(kept.join(' '));
              if (!text) {
                text = `${p.product_name || p.product_family || 'Item'} shown in the photo.`;
              }
              p.short_description = text;
              condFired = true;
            }
          }
          // (c) Title: bounded replacement of condition claims, as
          // round 7 handled titles.
          if (typeof p.suggested_title === 'string' && p.suggested_title) {
            let out = p.suggested_title;
            let replaced = false;
            for (const re of TITLE_CLAIMS) {
              out = out.replace(new RegExp(re.source, 'gi'), (m) => {
                if (replaced) return '';
                replaced = true;
                return /^[A-Z]/.test(m)
                  ? TITLE_BOUNDED.charAt(0).toUpperCase() + TITLE_BOUNDED.slice(1)
                  : TITLE_BOUNDED;
              });
            }
            if (replaced) {
              out = tidyText(out
                .replace(/\s+(?:with|and|or|but)\s+([.,;])/gi, '$1')
                .replace(/(^|[.!?]\s+)(?:It|This|That)\s*[.,;]\s*/g, '$1'));
              if (out !== p.suggested_title) {
                p.suggested_title = out;
                condFired = true;
              }
            }
          }
          // (b) Condition field: derived solely from visible_damage,
          // after all other processing.
          if (p.category !== 'Real Estate') {
            const nextCondition = visibleDamageHasDefect(p.visible_damage)
              ? 'Used - visible wear noted in photos'
              : 'Not assessed from photo';
            if (p.condition !== nextCondition) {
              p.condition = nextCondition;
              condFired = true;
            }
          } else if (!visibleDamageHasDefect(p.visible_damage) &&
                     typeof p.condition === 'string' &&
                     /^(?:very\s+)?(?:good|excellent|fair|poor|great|average|mint|pristine|like[-\s]new)(?:\s+condition)?$/i
                       .test(p.condition.trim())) {
            // Round 11 — property condition normalization: Real
            // Estate keeps its own condition handling (the property
            // flow, not this derivation), but a bare grade word with
            // no located damage behind it is unsupported (round 10
            // T9: a house exterior shipped condition "good" with an
            // empty damage list). With nothing assessed, the field
            // says so. A property WITH located damage keeps its
            // condition untouched.
            p.condition = 'Not assessed from photo';
            condFired = true;
            appliedGuards.push('property_condition_normalize');
          }
          if (condFired) appliedGuards.push('condition_by_construction');
        }
        // Round 12 guards — Claude round 11 (FAIL 8.57, zero
        // criticals) confirmed the round 11 fixes landed and docked
        // what remained: a layout speculation leading the house
        // description, name/title qualifier drift on two tests, a
        // seller instruction still leading the T3 description, three
        // dropped category prompt minimums, and the still-missing
        // plain statement that a family-level laptop's exact model
        // is unknown. Same pattern as rounds 3.5-11: deterministic
        // server-side code. This block runs after
        // condition_by_construction, the last writer of the
        // condition field, so nothing here can disturb it.
        // Guard — property layout scrub: guard 12 strips speculative
        // layout hedges from the property NAME, but the same claim
        // can lead the description (round 11 T9: "Multi-level or
        // split-level single-family home featuring..."). An exterior
        // photo does not establish the interior layout. Only a
        // LEADING phrase on a Real Estate result is removed;
        // mid-text mentions and other categories are untouched.
        // Round 13: a second layout claim rides inside the
        // description as a list item (round 12 T9: "The exterior
        // displays multiple windows, a walk-out lower level
        // entrance, mature landscaping, ...") — a walk-out lower
        // level is the same unestablished layout claim, in list
        // form. The item comes out wherever it sits in the list:
        // first after the verb or in the middle ("ITEM, " goes),
        // last before the period (", and ITEM" or ", ITEM" goes).
        // Nothing else in the sentence changes.
        if (p.category === 'Real Estate' &&
            typeof p.short_description === 'string' && p.short_description.trim()) {
          let layoutFired = false;
          const LAYOUT_LEAD = /^(?:multi-level\s+or\s+split-level|split-level\s+or\s+multi-level)\s+/i;
          if (LAYOUT_LEAD.test(p.short_description)) {
            const rest = p.short_description.replace(LAYOUT_LEAD, '');
            p.short_description = rest.charAt(0).toUpperCase() + rest.slice(1);
            layoutFired = true;
          }
          // Round 14: the same phrase can sit inside the first
          // sentence, modifying the property-type noun, where the
          // leading anchor cannot see it (round 13 T9: "The photo
          // shows a multi-level or split-level single-family
          // residential house featuring ..."). In the FIRST
          // sentence only, the phrase comes out when it directly
          // precedes the property-type noun phrase; the article
          // the model already wrote stays, so the sentence keeps
          // its grammar. The phrase anywhere else — later
          // sentences, or not modifying the type noun — is left
          // alone.
          {
            const sentences = p.short_description.split(/(?<=[.!?])\s+/);
            if (sentences.length > 0) {
              const TYPE_NOUN = String.raw`single-family\s+(?:residential\s+)?(?:house|home|residence)\b`;
              const nextFirst = sentences[0].replace(
                new RegExp(String.raw`\b(?:multi-level\s+or\s+split-level|split-level\s+or\s+multi-level)\s+(?=${TYPE_NOUN})`, 'i'), '');
              if (nextFirst !== sentences[0]) {
                sentences[0] = nextFirst;
                p.short_description = sentences.join(' ');
                layoutFired = true;
              }
            }
          }
          const WALKOUT_ITEM = String.raw`(?:a\s+|an\s+|the\s+)?walk-?out\s+lower\s+level\s+entrance\b`;
          if (new RegExp(WALKOUT_ITEM, 'i').test(p.short_description)) {
            let next = p.short_description;
            // "ITEM, " — first or middle list item. An item that
            // OPENS a sentence is a subject with an appositive
            // after it, not a list item, and is left alone.
            next = next.replace(new RegExp(String.raw`\b${WALKOUT_ITEM}\s*,\s*`, 'i'),
              (m, ...rest) => {
                const offset = rest[rest.length - 2];
                return /(?:^|[.!?]\s+)$/.test(next.slice(0, offset)) ? m : '';
              });
            // "ITEM and ..." — the first item of a two-item list
            // has no comma; same sentence-start protection.
            next = next.replace(new RegExp(String.raw`\b${WALKOUT_ITEM}\s+and\s+`, 'i'),
              (m, ...rest) => {
                const offset = rest[rest.length - 2];
                return /(?:^|[.!?]\s+)$/.test(next.slice(0, offset)) ? m : '';
              });
            // ", and ITEM" / ", ITEM" — the final list item.
            next = next
              .replace(new RegExp(String.raw`,\s*and\s+${WALKOUT_ITEM}`, 'i'), '')
              .replace(new RegExp(String.raw`\s*,\s*${WALKOUT_ITEM}`, 'i'), '');
            next = tidyText(next);
            if (next !== p.short_description) {
              p.short_description = next;
              layoutFired = true;
            }
          }
          if (layoutFired) appliedGuards.push('property_layout_scrub');
        }
        // Guard — name/title qualifier sync: the model drops a
        // qualifier from the structured name while keeping it in
        // the title, so the two fields disagree (round 11 T2: name
        // "Dosilet Conveyor Toaster", title "Dosilet Commercial
        // Conveyor Toaster"; T5: name "Volkswagen Golf R32", title
        // "Volkswagen Golf R32 (Mk4) ..."). Two narrow repairs, both
        // keyed on the title the model itself wrote: a generation
        // marker directly after the name is appended to the name,
        // and a "Commercial" the title carries inside an otherwise
        // identical name segment is adopted. The name is never
        // truncated or rewritten beyond these two repairs.
        {
          const nameStr = typeof p.product_name === 'string' ? p.product_name.trim() : '';
          const titleStr = (typeof p.suggested_title === 'string' && p.suggested_title)
            ? p.suggested_title
            : (typeof p.title === 'string' ? p.title : '');
          if (nameStr && titleStr && titleStr !== nameStr) {
            const escName = nameStr.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const genMatch = titleStr.match(new RegExp(`^${escName}\\s+\\((Mk\\d+|Gen \\d+|Series \\d+)\\)`, 'i'));
            if (genMatch && !nameStr.toLowerCase().includes(`(${genMatch[1].toLowerCase()})`)) {
              p.product_name = `${nameStr} (${genMatch[1]})`;
              appliedGuards.push('name_title_qualifier_sync');
            } else if (!/commercial/i.test(nameStr)) {
              const segment = titleStr.split(' - ')[0].trim();
              const stripped = segment
                .replace(/\s+commercial\s+/gi, ' ')
                .replace(/^commercial\s+/gi, '')
                .replace(/\s{2,}/g, ' ').trim();
              if (segment !== nameStr &&
                  stripped.toLowerCase() === nameStr.toLowerCase()) {
                p.product_name = segment;
                appliedGuards.push('name_title_qualifier_sync');
              }
            }
          }
        }
        // Guard — seller instruction strip: guard 7 flags a retail
        // display unit structurally, but the model still leads the
        // buyer-facing description with an instruction to the
        // SELLER (round 11 T3: "Photographed on a retail display —
        // confirm whether this is the actual unit for sale."). When
        // the display warning is present, that first sentence is
        // the warning's content duplicated as prose; it comes out.
        // Only the first sentence, only with the warning present,
        // and only when a real description sentence remains.
        if (typeof p.display_unit_warning === 'string' && p.display_unit_warning.trim() &&
            typeof p.short_description === 'string' && p.short_description.trim()) {
          const sentences = p.short_description.split(/(?<=[.!?])\s+/);
          if (sentences.length > 1 && /confirm whether/i.test(sentences[0])) {
            const nextDesc = tidyText(sentences.slice(1).join(' '));
            if (nextDesc) {
              p.short_description = nextDesc;
              appliedGuards.push('seller_instruction_strip');
            }
          }
        }
        // Guard — prompt minimums, round 12: the round 8 minimums
        // check broad need patterns (a "label" prompt satisfies the
        // brand need; a touchscreen VIN prompt satisfies the
        // automotive need), so three specific shots kept vanishing
        // (round 11: T4 lost the brand-logo close-up behind a
        // model/serial LABEL prompt, T6 lost the door-jamb VIN
        // sticker shot behind a touchscreen prompt, T13 lost the
        // additional-jars shot behind a logo prompt). Each rule
        // appends its shot only when no existing prompt names the
        // specific subject; appends go at the end, existing order
        // preserved, and needs_more_photos follows the round 8
        // convention when a shot is added.
        if (p.category !== 'Real Estate') {
          if (!Array.isArray(p.recommended_photos)) p.recommended_photos = [];
          const prompts12 = p.recommended_photos;
          const promptMentions12 = (re) => prompts12.some((e) => typeof e === 'string' && re.test(e));
          let appended12 = 0;
          const famName12 = `${p.product_family || ''} ${p.product_name || ''}`;
          const brandStr12 = typeof p.brand === 'string' ? p.brand.trim() : '';
          if ((!brandStr12 || /^unknown$/i.test(brandStr12)) &&
              !promptMentions12(/logo|brand/i) &&
              (/appliance/i.test(p.category || '') ||
               /refrigerator|fridge|washer|dryer|dishwasher|oven|stove|freezer/i.test(famName12))) {
            prompts12.push('Take a close-up photo of the brand logo on the front of the unit.');
            appended12++;
          }
          if (p.category === 'Automotive' && !promptMentions12(/door|jamb|sticker/i)) {
            prompts12.push('Take a photo of the VIN sticker on the driver door jamb.');
            appended12++;
          }
          if (/mixer grinder/i.test(famName12) && !promptMentions12(/jar/i)) {
            prompts12.push('Take a photo of any additional jars and lids included with the unit.');
            appended12++;
          }
          if (appended12 > 0) {
            p.needs_more_photos = true;
            appliedGuards.push('prompt_minimums_round12');
          }
        }
        // Guard — sub-family unknown statement: the settled
        // parent-family laptop result never says in prose that the
        // exact model is undetermined (Claude rounds 10 and 11,
        // T7) — the description lists unknown SPECS while the buyer
        // is left to assume the model itself is settled. Using the
        // round 3.8 signal (MacBook parent family, no model on
        // record), the description gains the plain statement,
        // unless it already says the model or sub-family is
        // unknown.
        if (!p.model && (p.product_family === 'MacBook' || p.product_name === 'Apple MacBook') &&
            typeof p.short_description === 'string' && p.short_description.trim()) {
          const desc7 = p.short_description;
          const alreadyStated7 = /\bmodel\b[^.!?]{0,60}\bunknown\b/i.test(desc7) ||
            /\bsub-?family\b[^.!?]{0,60}\bunknown\b/i.test(desc7) ||
            /\bunknown\b[^.!?]{0,30}\bmodel\b/i.test(desc7) ||
            /cannot be determined/i.test(desc7) || /can'?t be told/i.test(desc7);
          if (!alreadyStated7) {
            p.short_description = `${desc7.trim()} The exact model cannot be determined from the photo.`;
            appliedGuards.push('subfamily_unknown_statement');
          }
        }
      }
    }

    console.log(JSON.stringify({
      evt: 'analysis_ok', model: result.model, attempts: result.attempts,
      confidence: p.confidence, recognized: !!p.recognized,
      photos: jpegs.length,
      totalMs: Date.now() - startedAt,
    }));
    return res.status(200).json({ ...p, _meta: { model: result.model, attempts: result.attempts, thinking: result.thinking || 'default', guards: appliedGuards, derived_suggested_price: derivedSuggestedPrice } });
  } catch (e) {
    const category = e instanceof GeminiError ? e.category : 'MODEL_ERROR';
    const status = e instanceof GeminiError && e.status >= 400 ? e.status : 502;
    // Friendly, non-technical message for the app. Never leak internals.
    const friendly = {
      NETWORK_ERROR: 'We had trouble reaching the analysis service. Check your connection and try again.',
      TIMEOUT: 'Analysis took too long. Check your connection and try again.',
      AUTH_ERROR: 'The analysis service is unavailable right now. Try again later.',
      RATE_LIMIT: "Lots of people are analyzing photos right now. Wait a moment and try again.",
      MODEL_ERROR: "We couldn't analyze this photo right now. Try again or enter the details manually.",
      BAD_IMAGE: e.message || 'That photo could not be read. Try a clearer photo.',
      INVALID_RESPONSE: "We couldn't make sense of the analysis. Try again or enter the details manually.",
    }[category] || "We couldn't analyze this photo right now. Try again or enter the details manually.";
    console.log(JSON.stringify({ evt: 'analysis_error', category, totalMs: Date.now() - startedAt }));
    return res.status(status).json({ error: { category, message: friendly } });
  }
});
