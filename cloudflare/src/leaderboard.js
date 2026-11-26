// Stickman Brawl leaderboard: one Durable Object holds every player's best numbers and serves the top 50.
// Boards: survival (best Survival wave), wins (total wins), level (total XP; the game turns it into a level).
// Players are an id plus a secret key kept in their browser; only the key's SHA-256 is stored, so nobody can
// post scores under someone else's id. Scores come from the player's own save, so every post is clamped and
// rate-limited: numbers can only grow about as fast as real play allows.
export const LB_ORIGINS = ['https://brawl.expresslearn.my', 'http://brawl.expresslearn.my', 'https://www.brawl.expresslearn.my', 'http://www.brawl.expresslearn.my', 'https://danishdanial058.github.io'];
const BOARDS = { survival: 's', wins: 'w', level: 'x' };
const CAP = { s: 999, w: 1e6, x: 1e8 };
const FIRST = { s: 60, w: 500, x: 200000 };          // most a brand-new player can bring from before the leaderboard
const TOP = 50;
const ipHits = new Map();

function cleanName(n) {
  n = String(n || '').normalize('NFKC').replace(/[^\p{L}\p{N} _.\-]/gu, '').replace(/\s+/g, ' ').trim().slice(0, 14);
  return n || 'Player';
}
async function sha(s) {
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join('');
}
const int = (v, hi) => { v = Math.floor(Number(v)); return Number.isFinite(v) && v > 0 ? Math.min(v, hi) : 0; };

export class Leaderboard {
  constructor(state) { this.state = state; this.p = null; this.top = {}; }
  async load() {
    if (this.p) return;
    this.p = new Map();
    const all = await this.state.storage.list({ prefix: 'p:' });
    for (const [k, v] of all) this.p.set(k.slice(2), v);
    this.rank();
  }
  rank() { for (const f of Object.values(BOARDS)) this.top[f] = [...this.p.entries()].filter(([, e]) => e[f] > 0).sort((a, b) => b[1][f] - a[1][f] || a[1].t - b[1].t).map(([id]) => id); }
  async fetch(req) {
    const url = new URL(req.url);
    await this.load();
    if (req.method === 'GET') {
      const f = BOARDS[url.searchParams.get('b')] || 's', me = url.searchParams.get('me') || '', L = this.top[f] || [];
      const top = L.slice(0, TOP).map((id, i) => ({ r: i + 1, n: this.p.get(id).n, v: this.p.get(id)[f], me: id === me }));
      const i = L.indexOf(me);
      return Response.json({ top, me: i >= 0 ? { r: i + 1, v: this.p.get(me)[f] } : null, players: L.length });
    }
    if (req.method !== 'POST') return Response.json({ ok: false }, { status: 405 });
    let b; try { b = await req.json(); } catch (e) { return Response.json({ ok: false, why: 'bad json' }, { status: 400 }); }
    if (!b || !/^[a-f0-9]{16}$/.test(b.id || '') || !/^[a-f0-9]{32}$/.test(b.key || '')) return Response.json({ ok: false, why: 'bad id' }, { status: 400 });
    const now = Date.now(), h = await sha(b.key), old = this.p.get(b.id);
    if (old && old.h !== h) return Response.json({ ok: false, why: 'wrong key' }, { status: 403 });
    if (old && now - old.t < 10000) return Response.json({ ok: true, wait: true });
    const e = old ? { ...old } : { h, s: 0, w: 0, x: 0, t: now };
    const mins = old ? (now - old.t) / 60000 : 0;
    // how far each number may rise since the last post (a fight takes at least ~15 s; a Survival wave ~10 s)
    const room = { s: old ? 3 + mins * 6 : FIRST.s, w: old ? 1 + mins * 4 : FIRST.w, x: old ? 400 + mins * 1600 : FIRST.x };
    for (const f of ['s', 'w', 'x']) { const v = int(b[f], CAP[f]); if (v > e[f]) e[f] = Math.min(v, Math.floor(e[f] + room[f])); }
    e.n = cleanName(b.name); e.t = now;
    this.p.set(b.id, e); await this.state.storage.put('p:' + b.id, e); this.rank();
    return Response.json({ ok: true });
  }
}

// the Worker side: CORS for the game's page, a per-address limit, then hand over to the one Leaderboard object
export async function leaderboard(req, env) {
  const origin = req.headers.get('Origin') || '';
  const h = { 'content-type': 'application/json', 'cache-control': 'no-store', 'vary': 'Origin' };
  if (!LB_ORIGINS.includes(origin)) return new Response('{"ok":false}', { status: 403, headers: h });
  h['access-control-allow-origin'] = origin;
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: { ...h, 'access-control-allow-methods': 'GET, POST', 'access-control-allow-headers': 'content-type', 'access-control-max-age': '86400' } });
  if (req.method !== 'GET' && req.method !== 'POST') return new Response('{"ok":false}', { status: 405, headers: h });
  const ip = req.headers.get('CF-Connecting-IP') || '?', now = Date.now();
  let e = ipHits.get(ip); if (!e || now - e.t > 60000) { e = { n: 0, t: now }; ipHits.set(ip, e); }
  if (++e.n > 60) return new Response('{"ok":false}', { status: 429, headers: h });
  if (ipHits.size > 5000) ipHits.clear();
  if (req.method === 'POST' && Number(req.headers.get('content-length') || 0) > 2048) return new Response('{"ok":false}', { status: 413, headers: h });
  const stub = env.LB.get(env.LB.idFromName('global-1'), { locationHint: 'apac' });
  const r = await stub.fetch(req);
  return new Response(r.body, { status: r.status, headers: h });
}
