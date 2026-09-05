/**
 * Experiential Labs gateway client for the ad engine.
 * One call = one streamed chat completion. The key comes from the environment
 * (EXPLABS_API_KEY); it is never written to disk or a URL.
 *
 * The gateway (nginx) terminates any request near 600 s, streamed or not, so
 * `reasoning_effort: "max"` on a large prompt never returns. `callAstra` tries
 * the requested effort and, on a timeout or a 5xx, retries one step lower.
 */

const BASE = "https://api.experientiallabs.ai/v1/chat/completions";
const EFFORTS = ["max", "high", "medium", "low"];

function key() {
  const k = process.env.EXPLABS_API_KEY;
  if (!k) throw new Error("EXPLABS_API_KEY is not set in the environment.");
  return k;
}

// Parse an OpenAI SSE stream into the concatenated assistant text.
async function readStream(resp) {
  const reader = resp.body.getReader();
  const dec = new TextDecoder();
  let buf = "", out = "", usage = null;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop();
    for (const line of lines) {
      const s = line.trim();
      if (!s.startsWith("data:")) continue;
      const d = s.slice(5).trim();
      if (d === "[DONE]") continue;
      let j;
      try { j = JSON.parse(d); } catch { continue; }
      if (j.error) throw new Error("gateway error: " + JSON.stringify(j.error));
      if (j.usage) usage = j.usage;
      const c = j.choices?.[0]?.delta?.content;
      if (c) out += c;
    }
  }
  return { text: out, usage };
}

/**
 * callAstra(prompt, {effort, model, timeoutMs, label, image})
 * Returns { text, usage, effort }.  Falls back one effort tier on timeout/5xx.
 */
export async function callAstra(prompt, opts = {}) {
  const model = opts.model || "gpt-6-astra";
  const timeoutMs = opts.timeoutMs ?? 560000;
  const label = opts.label || "astra";
  let effort = opts.effort || "high";
  // one image (`image`) or several (`images`, in order): the critic can see our stills beside a reference's
  const imgs = opts.images || (opts.image ? [opts.image] : []);
  const content = imgs.length
    ? [{ type: "text", text: prompt }, ...imgs.map(url => ({ type: "image_url", image_url: { url } }))]
    : prompt;

  for (let tier = EFFORTS.indexOf(effort); tier < EFFORTS.length; tier++) {
    effort = EFFORTS[tier];
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    const t0 = Date.now();
    try {
      const resp = await fetch(BASE, {
        method: "POST",
        signal: ctl.signal,
        headers: { "Authorization": `Bearer ${key()}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model, reasoning_effort: effort, stream: true, messages: [{ role: "user", content }] })
      });
      if (!resp.ok) {
        clearTimeout(timer);
        const body = await resp.text().catch(() => "");
        // the free tier caps output tokens per hour and says so; a long pipeline should
        // stall until the top of the hour rather than degrade shot by shot (once only)
        if (resp.status === 429 && /free.*tier|resets at the top of the hour/i.test(body) && !opts._waitedForReset) {
          const now = new Date(), next = new Date(now); next.setMinutes(60, 20, 0);
          const ms = next - now;
          console.error(`[${label}] hourly free-tier cap; waiting ${Math.ceil(ms / 60000)} min for the reset at ${next.toTimeString().slice(0, 5)}`);
          await new Promise(r => setTimeout(r, ms));
          return callAstra(prompt, { ...opts, effort, _waitedForReset: true });
        }
        if (resp.status >= 500 && tier < EFFORTS.length - 1) {
          console.error(`[${label}] ${effort} -> HTTP ${resp.status}; retrying at ${EFFORTS[tier + 1]}`);
          continue;
        }
        throw new Error(`[${label}] HTTP ${resp.status}: ${body.slice(0, 200)}`);
      }
      const { text, usage } = await readStream(resp);
      clearTimeout(timer);
      if (!text.trim()) {
        if (tier < EFFORTS.length - 1) { console.error(`[${label}] ${effort} -> empty; retrying at ${EFFORTS[tier + 1]}`); continue; }
        throw new Error(`[${label}] empty response at ${effort}`);
      }
      console.error(`[${label}] ${effort} ok in ${((Date.now() - t0) / 1000).toFixed(0)}s (${usage?.completion_tokens ?? "?"} out tok)`);
      return { text, usage, effort };
    } catch (err) {
      clearTimeout(timer);
      const timedOut = err.name === "AbortError";
      // a stream the gateway cut (its ~600 s deadline, or a dropped connection) surfaces as
      // "terminated" / a network TypeError, not as an HTTP status: retry one tier lower, which is faster
      const cut = /terminated|ECONNRESET|network|socket|fetch failed|aborted/i.test(err.message || "");
      if ((timedOut || cut || /HTTP 5/.test(err.message)) && tier < EFFORTS.length - 1) {
        console.error(`[${label}] ${effort} ${timedOut ? "timed out" : cut ? "stream cut (" + err.message.slice(0, 40) + ")" : "failed"} after ${((Date.now() - t0) / 1000).toFixed(0)}s; retrying at ${EFFORTS[tier + 1]}`);
        continue;
      }
      throw err;
    }
  }
  throw new Error(`[${label}] exhausted all effort tiers`);
}

// Pull the first balanced JSON object/array out of a model reply (it may wrap
// it in prose or a ```json fence).
export function extractJson(text) {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const body = fence ? fence[1] : text;
  const start = body.search(/[[{]/);
  if (start < 0) throw new Error("no JSON found in reply");
  const open = body[start], close = open === "{" ? "}" : "]";
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < body.length; i++) {
    const ch = body[i];
    if (inStr) { if (esc) esc = false; else if (ch === "\\") esc = true; else if (ch === '"') inStr = false; continue; }
    if (ch === '"') inStr = true;
    else if (ch === open) depth++;
    else if (ch === close && --depth === 0) return JSON.parse(body.slice(start, i + 1));
  }
  throw new Error("unbalanced JSON in reply");
}
