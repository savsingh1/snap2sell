'use strict';

/**
 * Snap2Sell secure Gemini proxy — Cloud Function (gen2), Node 20.
 *
 * The mobile app POSTs a product photo here; this function calls Gemini and
 * returns structured product identification. The Gemini API key lives in
 * Secret Manager (mounted as GEMINI_API_KEY) and NEVER ships in the app.
 *
 *   POST /  { "imageBase64": "<base64>", "mimeType": "image/jpeg" }
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
const MAX_BODY_BYTES = 3 * 1024 * 1024; // 3 MB is plenty for a compressed photo
const MAX_IMAGE_BYTES = 2.5 * 1024 * 1024;

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
// Gemini call with retry — transient failures only.
// ---------------------------------------------------------------------------
const TRANSIENT_STATUS = new Set([429, 500, 502, 503, 504]);
const BACKOFF_MS = [0, 1000, 2000, 4000]; // attempt 1 immediate, then ~1s/2s/4s

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

class GeminiError extends Error {
  constructor(category, message, status) {
    super(message);
    this.category = category;
    this.status = status;
  }
}

async function callGemini(apiKey, model, jpegBase64, startedAt) {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
  const body = JSON.stringify({
    contents: [
      {
        parts: [
          { text: SYSTEM_PROMPT },
          { inline_data: { mime_type: 'image/jpeg', data: jpegBase64 } },
        ],
      },
    ],
    generationConfig: { responseMimeType: 'application/json', temperature: 0.2 },
  });

  let lastErr = null;
  for (let attempt = 0; attempt < BACKOFF_MS.length; attempt++) {
    if (attempt > 0) await sleep(BACKOFF_MS[attempt]);
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
      return { parsed, model, attempts: attempt + 1 };
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
    if (TRANSIENT_STATUS.has(res.status)) {
      lastErr = new GeminiError(
        res.status === 429 ? 'RATE_LIMIT' : 'MODEL_ERROR',
        res.status === 429
          ? 'AI service is rate-limited right now.'
          : 'AI service is temporarily unavailable.',
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
    const { imageBase64, mimeType } = req.body || {};
    if (typeof imageBase64 !== 'string' || imageBase64.length < 100) {
      return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'No photo was received. Try again.' } });
    }
    if (imageBase64.length > MAX_IMAGE_BYTES * 1.4) {
      return res.status(413).json({ error: { category: 'BAD_IMAGE', message: 'Photo is too large. Try a smaller image.' } });
    }

    // Normalize: EXIF orientation fixed, longest side <=1600, JPEG q80.
    // Handles JPEG/PNG/WEBP/HEIC input — Gemini always gets clean JPEG.
    let jpeg;
    try {
      const input = Buffer.from(imageBase64, 'base64');
      const meta = await sharp(input).metadata();
      jpeg = await sharp(input)
        .rotate() // honor EXIF orientation
        .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 80, mozjpeg: true })
        .toBuffer();
      console.log(JSON.stringify({
        evt: 'image_normalized',
        inFormat: meta.format, inW: meta.width, inH: meta.height,
        outBytes: jpeg.length, inMime: mimeType || 'unknown',
      }));
    } catch {
      return res.status(400).json({ error: { category: 'BAD_IMAGE', message: 'That file is not a readable photo. Try a JPEG or PNG.' } });
    }

    const models = [PRIMARY_MODEL, ...FALLBACK_MODELS.filter((m) => m !== PRIMARY_MODEL)];
    let result = null;
    let modelError = null;
    for (const model of models) {
      try {
        result = await callGemini(apiKey, model, jpeg.toString('base64'), startedAt);
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
