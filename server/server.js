// Stickman Brawl online server.
// A small MQTT 3.1.1 broker over WebSocket with no dependencies. It only relays game messages:
// QoS 0, exact topic names (no wildcards), and only topics that start with the game's prefix.
'use strict';
const http = require('http');
const crypto = require('crypto');

const PORT = Number(process.env.PORT) || 8899;
const HOST = process.env.HOST || '0.0.0.0';
const PREFIXES = ['sbx/', 'stickmanbrawl-dd058/'];   // only this game's topics are allowed (new short prefix, old one for older app builds)
const MAX_CONN = 1000;                    // total connections
const MAX_PACKET = 32 * 1024;             // bytes per MQTT packet
const MAX_SUBS = 16;                      // topics per connection
const RATE = 120;                         // messages per second per connection (burst bucket)
const IDLE_MS = 90 * 1000;                // drop silent connections

const subs = new Map();                   // topic -> Set(conn)
const conns = new Set();
const stats = { pub: 0, dropped: 0, started: Date.now() };

function wsFrame(payload) {
  const n = payload.length;
  let head;
  if (n < 126) head = Buffer.from([0x82, n]);
  else if (n < 65536) { head = Buffer.alloc(4); head[0] = 0x82; head[1] = 126; head.writeUInt16BE(n, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x82; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2); }
  return Buffer.concat([head, payload]);
}
function mqtt(type, body) {
  const len = [];
  let x = body.length;
  do { let d = x % 128; x = Math.floor(x / 128); if (x > 0) d |= 128; len.push(d); } while (x > 0);
  return Buffer.concat([Buffer.from([type, ...len]), body]);
}
function kill(c) {
  if (c.dead) return;
  c.dead = true;
  for (const t of c.mine) { const s = subs.get(t); if (s) { s.delete(c); if (!s.size) subs.delete(t); } }
  c.mine.clear();
  conns.delete(c);
  try { c.sock.destroy(); } catch (e) {}
}

const server = http.createServer((req, res) => {
  // Health check for Render, and a tiny status page.
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('Stickman Brawl server is running. Players connected: ' + conns.size + '\n');
});

server.on('upgrade', (req, sock) => {
  const key = req.headers['sec-websocket-key'];
  const protos = String(req.headers['sec-websocket-protocol'] || '').split(',').map(s => s.trim());
  if (!key || !protos.includes('mqtt') || conns.size >= MAX_CONN) { sock.destroy(); return; }
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + accept + '\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n');
  sock.setNoDelay(true);
  const c = { sock, ws: Buffer.alloc(0), mq: Buffer.alloc(0), frag: [], mine: new Set(), connected: false,
    tokens: RATE, lastFill: Date.now(), lastSeen: Date.now(), dead: false };
  c.send = b => { if (!c.dead) { try { sock.write(wsFrame(b)); } catch (e) { kill(c); } } };
  conns.add(c);
  sock.on('close', () => kill(c));
  sock.on('error', () => kill(c));
  sock.on('data', d => {
    c.lastSeen = Date.now();
    c.ws = Buffer.concat([c.ws, d]);
    if (c.ws.length > MAX_PACKET * 4) { kill(c); return; }
    for (;;) {
      if (c.ws.length < 2) return;
      const op = c.ws[0] & 15, fin = c.ws[0] & 128, masked = c.ws[1] & 128;
      let len = c.ws[1] & 127, off = 2;
      if (len === 126) { if (c.ws.length < 4) return; len = c.ws.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (c.ws.length < 10) return; len = Number(c.ws.readBigUInt64BE(2)); off = 10; }
      if (!masked || len > MAX_PACKET) { kill(c); return; }   // clients must mask; no huge frames
      if (c.ws.length < off + 4 + len) return;
      const mask = c.ws.subarray(off, off + 4);
      const data = Buffer.from(c.ws.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      c.ws = c.ws.subarray(off + 4 + len);
      if (op === 8) { kill(c); return; }
      if (op === 9) { try { sock.write(Buffer.concat([Buffer.from([0x8A, data.length]), data])); } catch (e) {} continue; }
      if (op === 10) continue;
      if (op === 2 || op === 0) {
        c.frag.push(data);
        if (fin) { const all = Buffer.concat(c.frag); c.frag = []; if (all.length > MAX_PACKET) { kill(c); return; } onMqtt(c, all); }
      } else { kill(c); return; }
      if (c.dead) return;
    }
  });
});

function topicOk(t) { return t.length < 200 && PREFIXES.some(p => t.startsWith(p)) && !/[#+\u0000]/.test(t); }

function onMqtt(c, data) {
  c.mq = Buffer.concat([c.mq, data]);
  for (;;) {
    if (c.mq.length < 2) return;
    let mul = 1, len = 0, i = 1, b;
    do { if (i >= c.mq.length) return; if (i > 4) { kill(c); return; } b = c.mq[i++]; len += (b & 127) * mul; mul *= 128; } while (b & 128);
    if (len > MAX_PACKET) { kill(c); return; }
    if (c.mq.length < i + len) return;
    const type = c.mq[0], body = c.mq.subarray(i, i + len);
    c.mq = c.mq.subarray(i + len);
    const k = type >> 4;
    try {
      if (!c.connected && k !== 1) { kill(c); return; }
      if (k === 1) {                                  // CONNECT
        if (body.length < 10 || body.subarray(2, 6).toString() !== 'MQTT' || body[6] !== 4) { kill(c); return; }
        c.connected = true;
        c.send(mqtt(0x20, Buffer.from([0, 0])));
      } else if (k === 8) {                           // SUBSCRIBE
        if (type !== 0x82) { kill(c); return; }
        const pid = body.subarray(0, 2), codes = [];
        let p = 2;
        while (p + 2 <= body.length) {
          const tl = body.readUInt16BE(p), t = body.subarray(p + 2, p + 2 + tl).toString();
          p += 2 + tl + 1;
          if (topicOk(t) && c.mine.size < MAX_SUBS) {
            if (!subs.has(t)) subs.set(t, new Set());
            subs.get(t).add(c); c.mine.add(t); codes.push(0);
          } else codes.push(0x80);                    // refused
        }
        c.send(mqtt(0x90, Buffer.concat([pid, Buffer.from(codes)])));
      } else if (k === 10) {                          // UNSUBSCRIBE
        const pid = body.subarray(0, 2);
        let p = 2;
        while (p + 2 <= body.length) {
          const tl = body.readUInt16BE(p), t = body.subarray(p + 2, p + 2 + tl).toString();
          p += 2 + tl;
          const s = subs.get(t); if (s) { s.delete(c); if (!s.size) subs.delete(t); }
          c.mine.delete(t);
        }
        c.send(mqtt(0xB0, pid));
      } else if (k === 3) {                           // PUBLISH (QoS 0 only)
        if ((type >> 1) & 3) { kill(c); return; }
        const now = Date.now();
        c.tokens = Math.min(RATE, c.tokens + (now - c.lastFill) / 1000 * RATE); c.lastFill = now;
        if (c.tokens < 1) { stats.dropped++; continue; }
        c.tokens -= 1;
        const tl = body.readUInt16BE(0), t = body.subarray(2, 2 + tl).toString();
        if (!topicOk(t)) continue;
        stats.pub++;
        const s = subs.get(t);
        if (s) { const out = mqtt(0x30, Buffer.from(body)); for (const o of s) o.send(out); }
      } else if (k === 12) {                          // PINGREQ
        c.send(Buffer.from([0xD0, 0]));
      } else if (k === 14) {                          // DISCONNECT
        kill(c); return;
      }
    } catch (e) { kill(c); return; }
  }
}

setInterval(() => {
  const now = Date.now();
  for (const c of conns) if (now - c.lastSeen > IDLE_MS) kill(c);
}, 15000);

server.listen(PORT, HOST, () => console.log('Stickman Brawl server listening on ' + HOST + ':' + PORT));
