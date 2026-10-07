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
 */

const functions = require('@google-cloud/functions-framework');
const sharp = require('sharp');

const PRIMARY_MODEL = process.env.GEMINI_MODEL || 'gemini-3.8-flash';
const FALLBACK_MODELS = ['gemini-3.8-flash', 'gemini-3.6-flash', 'gemini-3.5-flash'];
const APP_SECRET = process.env.APP_API_SECRET || '';
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

CRITICAL HONESTY RULES:
- Only name a brand if it is clearly visible or legible in the photo. Never guess a brand.
- If a logo or mark is visible but its text is NOT legible, describe the mark in short_description instead of naming a brand.
- Never invent an exact model number. If the model is not visible or cannot be determined confidently, leave "model" empty and identify the most likely product family instead.
- Only state materials if clearly visible. Never guess.
- Base price estimates on typical second-hand marketplace values in North America. These are ESTIMATES, not appraisals.
- If the photo is unclear, say so: set recognized=false or a low confidence, and use recommended_photos to ask for a better shot.

CONDITION: give your best visual assessment (likeNew, excellent, good, fair, poor). The seller confirms it before listing — a photo cannot prove functionality or hidden defects.

Respond with ONLY a single JSON object (no markdown fences, no commentary) with exactly these fields:
{
  "recognized": true,
  "brand": "",
  "product_name": "",
  "model": "",
  "product_family": "",
  "category": "one of: Furniture, Electronics, Appliances, Fashion, Beauty & Personal Care, Toys & Games, Books & Media, Sports & Outdoors, Baby & Kids, Home & Garden, Miscellaneous",
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
  "needs_more_photos": false,
  "recommended_photos": []
}
"confidence" is 0-100. Below 60 set needs_more_photos=true and list the exact shots that would help, e.g. "Take a photo of the model-number label.", "Take a photo of the front of the product.", "Take a photo of the bottom sticker.", "Take a photo of the packaging."`;

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
- If the photos clearly show DIFFERENT items (not just different angles of one item), set recognized=false and a low confidence, and explain in recommended_photos that the photos seem to show different items and should be retaken of the same item.
- All honesty rules above still apply to every photo.`;

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

async function callGemini(apiKey, model, jpegBase64List, promptText, startedAt) {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
  // Single photo: parts are [{ text: SYSTEM_PROMPT }, { inline_data }] —
  // identical to the original single-image request.
  const parts = [{ text: promptText }];
  for (const b64 of jpegBase64List) {
    parts.push({ inline_data: { mime_type: 'image/jpeg', data: b64 } });
  }
  const body = JSON.stringify({
    contents: [{ parts }],
    generationConfig: { responseMimeType: 'application/json', temperature: 0.2 },
  });

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
      return { parsed, model, attempts: attempt };
    }

    if (res.status === 404) {
      // Model retired/renamed — permanent for this model; caller tries next.
      throw new GeminiError('MODEL_ERROR', `Model ${model} is not available.`, 404);
    }
    if (res.status === 400) {
      const snippet = (await res.text().catch(() => '')).slice(0, 200);
      console.log(JSON.stringify({ evt: 'gemini_400', model, snippet }));
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
    const { imageBase64, images, mimeType } = req.body || {};
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

    // Normalize: EXIF orientation fixed, longest side <=1600, JPEG q80.
    // Handles JPEG/PNG/WEBP/HEIC input — Gemini always gets clean JPEG.
    const jpegs = [];
    try {
      for (let i = 0; i < imageInputs.length; i++) {
        const input = Buffer.from(imageInputs[i], 'base64');
        const meta = await sharp(input).metadata();
        const jpeg = await sharp(input)
          .rotate() // honor EXIF orientation
          .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
          .jpeg({ quality: 80, mozjpeg: true })
          .toBuffer();
        jpegs.push(jpeg);
        console.log(JSON.stringify({
          evt: 'image_normalized',
          ...(multiMode ? { index: i, count: imageInputs.length } : {}),
          inFormat: meta.format, inW: meta.width, inH: meta.height,
          outBytes: jpeg.length, inMime: mimeType || 'unknown',
        }));
      }
    } catch {
      return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'That file is not a readable photo. Try a JPEG or PNG.' } });
    }

    // Single photo: SYSTEM_PROMPT alone, exactly as before.
    const promptText = multiMode
      ? SYSTEM_PROMPT + MULTI_PHOTO_ADDENDUM.replace('{N}', String(jpegs.length))
      : SYSTEM_PROMPT;
    const jpegBase64List = jpegs.map((j) => j.toString('base64'));

    const models = [PRIMARY_MODEL, ...FALLBACK_MODELS.filter((m) => m !== PRIMARY_MODEL)];
    let result = null;
    let modelError = null;
    for (const model of models) {
      try {
        result = await callGemini(apiKey, model, jpegBase64List, promptText, startedAt);
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

    console.log(JSON.stringify({
      evt: 'analysis_ok', model: result.model, attempts: result.attempts,
      confidence: p.confidence, recognized: !!p.recognized,
      photos: jpegs.length,
      totalMs: Date.now() - startedAt,
    }));
    return res.status(200).json({ ...p, _meta: { model: result.model, attempts: result.attempts } });
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
