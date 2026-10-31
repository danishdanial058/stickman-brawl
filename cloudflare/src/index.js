// Stickman Brawl online server for Cloudflare Workers.
// The same tiny MQTT 3.1.1-over-WebSocket relay as server/server.js (QoS 0, exact topics, game prefix only),
// running inside one Durable Object that uses the WebSocket Hibernation API, so idle time costs nothing.
const PREFIXES = ['sbx/', 'stickmanbrawl-dd058/'];   // only this game's topics are allowed
const MAX_CONN = 1000;                                // total connections
const MAX_PACKET = 32 * 1024;                         // bytes per MQTT packet
const MAX_SUBS = 16;                                  // topics per connection
const RATE = 120;                                     // messages per second per connection
const dec = new TextDecoder();

function topicOk(t) { return t.length < 200 && PREFIXES.some(p => t.startsWith(p)) && !/[#+\u0000]/.test(t); }
function pkt(type, body) {
  const len = []; let x = body.length;
  do { let d = x % 128; x = Math.floor(x / 128); if (x > 0) d |= 128; len.push(d); } while (x > 0);
  const out = new Uint8Array(1 + len.length + body.length);
  out[0] = type; out.set(len, 1); out.set(body, 1 + len.length);
  return out;
}
const u16 = (b, p) => (b[p] << 8) | b[p + 1];

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const stub = env.BROKER.get(env.BROKER.idFromName('main'));
    if (url.pathname === '/mqtt') {
      if ((req.headers.get('Upgrade') || '').toLowerCase() !== 'websocket') return new Response('Expected a WebSocket', { status: 426 });
      return stub.fetch(req);
    }
    if (url.pathname === '/') return stub.fetch(new Request(url.origin + '/status'));
    return new Response('Not found', { status: 404 });
  }
};

export class Broker {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.subs = new Map();      // topic -> Set(ws)
    this.rate = new WeakMap();  // ws -> {tokens, last}
    // after waking from hibernation, rebuild the topic map from what each socket remembers
    for (const ws of ctx.getWebSockets()) { const a = this.att(ws); for (const t of a.subs) this.add(t, ws); }
  }
  att(ws) { let a = null; try { a = ws.deserializeAttachment(); } catch (e) {} return a && Array.isArray(a.subs) ? a : { c: false, subs: [] }; }
  add(t, ws) { let s = this.subs.get(t); if (!s) this.subs.set(t, s = new Set()); s.add(ws); }
  drop(ws) {
    for (const t of this.att(ws).subs) { const s = this.subs.get(t); if (s) { s.delete(ws); if (!s.size) this.subs.delete(t); } }
  }
  kill(ws, code) { this.drop(ws); try { ws.serializeAttachment({ c: false, subs: [] }); } catch (e) {} try { ws.close(code || 1008, 'closed'); } catch (e) {} }
  send(ws, b) { try { ws.send(b); } catch (e) { this.drop(ws); } }

  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === '/status') {
      return new Response('Stickman Brawl server is running. Players connected: ' + this.ctx.getWebSockets().length + '\n',
        { headers: { 'content-type': 'text/plain', 'access-control-allow-origin': '*' } });
    }
    const protos = (req.headers.get('Sec-WebSocket-Protocol') || '').split(',').map(s => s.trim());
    if (!protos.includes('mqtt')) return new Response('MQTT subprotocol required', { status: 400 });
    if (this.ctx.getWebSockets().length >= MAX_CONN) return new Response('Server full', { status: 503 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ c: false, subs: [] });
    return new Response(null, { status: 101, webSocket: client, headers: { 'Sec-WebSocket-Protocol': 'mqtt' } });
  }

  async webSocketMessage(ws, msg) {
    if (typeof msg === 'string') { this.kill(ws); return; }
    const b = new Uint8Array(msg);
    if (b.length > MAX_PACKET) { this.kill(ws); return; }
    let o = 0;
    while (o < b.length) {
      if (b.length - o < 2) { this.kill(ws); return; }
      let mul = 1, len = 0, i = o + 1, x;
      do { if (i >= b.length || i > o + 4) { this.kill(ws); return; } x = b[i++]; len += (x & 127) * mul; mul *= 128; } while (x & 128);
      if (i + len > b.length) { this.kill(ws); return; }       // the game's client never splits a packet across messages
      if (!this.handle(ws, b[o], b.subarray(i, i + len))) return;
      o = i + len;
    }
  }

  // returns false when the connection was closed
  handle(ws, type, body) {
    const k = type >> 4, a = this.att(ws);
    try {
      if (!a.c && k !== 1) { this.kill(ws); return false; }
      if (k === 1) {                                  // CONNECT
        if (body.length < 10 || dec.decode(body.subarray(2, 6)) !== 'MQTT' || body[6] !== 4) { this.kill(ws); return false; }
        a.c = true; ws.serializeAttachment(a);
        this.send(ws, pkt(0x20, new Uint8Array([0, 0])));
      } else if (k === 8) {                           // SUBSCRIBE
        if (type !== 0x82) { this.kill(ws); return false; }
        const codes = [body[0], body[1]];
        let p = 2;
        while (p + 2 <= body.length) {
          const tl = u16(body, p), t = dec.decode(body.subarray(p + 2, p + 2 + tl));
          p += 2 + tl + 1;
          if (topicOk(t) && (a.subs.includes(t) || a.subs.length < MAX_SUBS)) {
            if (!a.subs.includes(t)) a.subs.push(t);
            this.add(t, ws); codes.push(0);
          } else codes.push(0x80);
        }
        ws.serializeAttachment(a);
        this.send(ws, pkt(0x90, new Uint8Array(codes)));
      } else if (k === 10) {                          // UNSUBSCRIBE
        let p = 2;
        while (p + 2 <= body.length) {
          const tl = u16(body, p), t = dec.decode(body.subarray(p + 2, p + 2 + tl));
          p += 2 + tl;
          const s = this.subs.get(t); if (s) { s.delete(ws); if (!s.size) this.subs.delete(t); }
          a.subs = a.subs.filter(x => x !== t);
        }
        ws.serializeAttachment(a);
        this.send(ws, pkt(0xB0, new Uint8Array([body[0], body[1]])));
      } else if (k === 3) {                           // PUBLISH (QoS 0 only)
        if ((type >> 1) & 3) { this.kill(ws); return false; }
        const now = Date.now();
        let r = this.rate.get(ws); if (!r) this.rate.set(ws, r = { tokens: RATE, last: now });
        r.tokens = Math.min(RATE, r.tokens + (now - r.last) / 1000 * RATE); r.last = now;
        if (r.tokens < 1) return true;
        r.tokens -= 1;
        const tl = u16(body, 0), t = dec.decode(body.subarray(2, 2 + tl));
        if (!topicOk(t)) return true;
        const s = this.subs.get(t);
        if (s && s.size) { const out = pkt(0x30, body); for (const o of s) this.send(o, out); }
      } else if (k === 12) {                          // PINGREQ
        this.send(ws, new Uint8Array([0xD0, 0]));
      } else if (k === 14) {                          // DISCONNECT
        this.kill(ws, 1000); return false;
      }
    } catch (e) { this.kill(ws); return false; }
    return true;
  }

  async webSocketClose(ws, code) { this.drop(ws); try { ws.close(code === 1005 || code === 1006 ? 1000 : code, 'bye'); } catch (e) {} }
  async webSocketError(ws) { this.drop(ws); }
}
