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
            condition: '', confidence: 0, identification_level: '',
            needs_more_photos: true, needs_more_information: false,
            price_low: 0, price_high: 0, suggested_price: 0,
            included_accessories: [], missing_parts: [], visible_damage: [],
            suggested_title: '', short_description: '', search_keywords: [],
            recommended_photos: ['Take a new photo in good light, holding the camera steady, and tap the item on screen to focus before shooting.'],
            rejection_reason: 'blurry_image',
            user_message: 'That photo is too blurry to identify. Try again in good light, hold the camera steady, and tap the item to focus before taking the photo.',
            photo_mismatch_warning: '',
            _meta: { model: 'blur_fast_path', attempts: 0, guards: ['blur_fast_path'], derived_suggested_price: false },
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
    // Same gate for the thinking level: only the A/B harness may set it,
    // and only to a known Gemini 3 level.
    const overrideThinking = process.env.ALLOW_MODEL_OVERRIDE === '1' &&
      ['minimal', 'low', 'medium', 'high'].includes(thinkingLevel)
      ? thinkingLevel : null;
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
        // A rejection carries no identification at all.
        p.identification_level = '';
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
          p.confidence = Math.min(p.confidence, 60);
          appliedGuards.push('low_res_confidence_cap');
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
