// ArkWeb Agent browser over the app's DevTools endpoint (localhost:9222).
// Uses a full-screen iframe inside the DSH page so the app UI is not navigated away.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';

const SYSROOT = process.env.IEC_SYSROOT || process.env.DSH_SYSROOT || '';
const HOME = SYSROOT ? path.join(SYSROOT, '..', 'home') : (process.env.HOME || process.cwd());
const STATE = path.join(HOME, '.dsh-browser.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function getJson(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(e); }
      });
    }).on('error', reject);
  });
}

function connectWs(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const key = crypto.randomBytes(16).toString('base64');
    const sock = net.connect(Number(u.port || 80), u.hostname);
    let buffer = Buffer.alloc(0);
    let upgraded = false;
    let closed = false;
    const pending = new Map();
    let next = 0;
    const fail = (error) => { if (!closed) { closed = true; try { sock.destroy(); } catch {} reject(error); } };
    const parseFrames = () => {
      while (buffer.length >= 2) {
        const b0 = buffer[0];
        const b1 = buffer[1];
        let len = b1 & 0x7f;
        let off = 2;
        if (len === 126) {
          if (buffer.length < 4) return;
          len = buffer.readUInt16BE(2); off = 4;
        } else if (len === 127) {
          if (buffer.length < 10) return;
          len = Number(buffer.readBigUInt64BE(2)); off = 10;
        }
        const masked = (b1 & 0x80) !== 0;
        let mask = null;
        if (masked) { if (buffer.length < off + 4) return; mask = buffer.subarray(off, off + 4); off += 4; }
        if (buffer.length < off + len) return;
        let payload = Buffer.from(buffer.subarray(off, off + len));
        if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
        buffer = buffer.subarray(off + len);
        const opcode = b0 & 0x0f;
        if (opcode === 8) { closed = true; try { sock.destroy(); } catch {} return; }
        if (opcode !== 1) continue;
        let msg;
        try { msg = JSON.parse(payload.toString('utf8')); } catch { continue; }
        if (msg.id && pending.has(msg.id)) {
          const { resolve: done, reject: deny } = pending.get(msg.id);
          pending.delete(msg.id);
          if (msg.error) deny(new Error(msg.error.message || JSON.stringify(msg.error)));
          else done(msg);
        }
      }
    };
    sock.on('connect', () => {
      sock.write(
        'GET ' + (u.pathname || '/') + ' HTTP/1.1\r\n' +
        'Host: ' + u.host + '\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Key: ' + key + '\r\n' +
        'Sec-WebSocket-Version: 13\r\n\r\n'
      );
    });
    sock.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const idx = buffer.indexOf('\r\n\r\n');
        if (idx < 0) return;
        const head = buffer.subarray(0, idx).toString('utf8');
        if (!/HTTP\/1\.1 101/i.test(head)) return fail(new Error('websocket handshake failed'));
        buffer = buffer.subarray(idx + 4);
        upgraded = true;
        const send = (method, params = {}) => new Promise((done, deny) => {
          const id = ++next;
          pending.set(id, { resolve: done, reject: deny });
          const text = Buffer.from(JSON.stringify({ id, method, params }));
          const mask = crypto.randomBytes(4);
          const masked = Buffer.from(text);
          for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
          let header;
          if (masked.length < 126) header = Buffer.from([0x81, 0x80 | masked.length]);
          else if (masked.length < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0xfe; header.writeUInt16BE(masked.length, 2); }
          else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 0xff; header.writeBigUInt64BE(BigInt(masked.length), 2); }
          sock.write(Buffer.concat([header, mask, masked]));
        });
        resolve({ sock, send });
      }
      parseFrames();
    });
    sock.on('error', fail);
    sock.on('close', () => { closed = true; });
  });
}

async function connect() {
  const list = await getJson('http://127.0.0.1:9222/json');
  const target = list.find((t) => t.type === 'page') || list[0];
  if (!target) throw new Error('no ArkWeb debug target; start the app with debugging enabled');
  const ws = await connectWs(target.webSocketDebuggerUrl);
  await ws.send('Page.enable');
  await ws.send('Runtime.enable');
  return { ws, send: ws.send };
}

async function mainEval(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.error) throw new Error(r.error.message);
  const res = r.result?.result;
  if (res?.subtype === 'error') throw new Error(res.description || 'evaluation failed');
  return res?.value;
}

async function findFrame(cdp) {
  const r = await cdp.send('Page.getFrameTree');
  const stack = [r.result?.frameTree];
  while (stack.length) {
    const node = stack.pop();
    if (!node) continue;
    const f = node.frame;
    if (f?.name === 'dsh-agent-browser') return f;
    for (const child of node.childFrames || []) stack.push(child);
  }
  return null;
}

async function frameEval(cdp, expression) {
  const frame = await findFrame(cdp);
  if (!frame) throw new Error('browser iframe is not open; run browser open <url> first');
  const w = await cdp.send('Page.createIsolatedWorld', { frameId: frame.id, worldName: 'dsh-agent' });
  if (w.error) throw new Error(w.error.message);
  const r = await cdp.send('Runtime.evaluate', {
    expression, contextId: w.result.executionContextId, returnByValue: true, awaitPromise: true,
  });
  if (r.error) throw new Error(r.error.message);
  const res = r.result?.result;
  if (res?.subtype === 'error') throw new Error(res.description || 'evaluation failed');
  return res?.value;
}

async function open(cdp, url) {
  await mainEval(cdp, `(() => {
    let f = document.getElementById('dsh-agent-browser');
    if (!f) {
      f = document.createElement('iframe');
      f.id = 'dsh-agent-browser';
      f.setAttribute('name', 'dsh-agent-browser');
      f.style.cssText = 'position:fixed;inset:0;width:100vw;height:100vh;border:0;z-index:2147483647;background:#fff';
      document.body.appendChild(f);
    }
    f.src = ${JSON.stringify(url)};
    return 'ok';
  })()`);
  await sleep(1800);
  const info = await frameEval(cdp, `JSON.stringify({url: location.href, title: document.title})`).catch(() => null);
  return { url, info: info ? JSON.parse(info) : null };
}

async function main() {
  const [action, ...rest] = process.argv.slice(2);
  const cdp = await connect();
  try {
    if (action === 'open') {
      if (!rest[0]) throw new Error('usage: browser open <url>');
      console.log(JSON.stringify(await open(cdp, rest[0])));
    } else if (action === 'dom') {
      const html = await frameEval(cdp, 'document.documentElement.outerHTML');
      console.log(String(html));
    } else if (action === 'text') {
      console.log(String(await frameEval(cdp, 'document.body ? document.body.innerText : ""')));
    } else if (action === 'eval') {
      const r = await frameEval(cdp, rest.join(' '));
      console.log(typeof r === 'string' ? r : JSON.stringify(r));
    } else if (action === 'click') {
      if (!rest[0]) throw new Error('usage: browser click <selector>');
      const sel = JSON.stringify(rest[0]);
      console.log(JSON.stringify(await frameEval(cdp, `(() => { const e = document.querySelector(${sel}); if (!e) return {ok:false}; e.click(); return {ok:true, tag:e.tagName}; })()`)));
    } else if (action === 'type') {
      if (!rest[0]) throw new Error('usage: browser type <selector> <text>');
      const sel = JSON.stringify(rest[0]);
      const text = JSON.stringify(rest.slice(1).join(' '));
      console.log(JSON.stringify(await frameEval(cdp, `(() => {
        const e = document.querySelector(${sel}); if (!e) return {ok:false};
        e.focus();
        if ('value' in e) { e.value = ${text}; } else { e.textContent = ${text}; }
        e.dispatchEvent(new Event('input', {bubbles:true}));
        e.dispatchEvent(new Event('change', {bubbles:true}));
        return {ok:true};
      })()`)));
    } else if (action === 'screenshot') {
      const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
      if (!r.result?.data) throw new Error('screenshot failed');
      const file = path.join(HOME, 'dsh-browser.png');
      fs.writeFileSync(file, Buffer.from(r.result.data, 'base64'));
      console.log(file);
    } else if (action === 'userscript') {
      let script = rest.join(' ');
      try { if (script && fs.existsSync(script)) script = fs.readFileSync(script, 'utf8'); } catch {}
      if (!script) throw new Error('usage: browser userscript <script|file>');
      const r = await frameEval(cdp, `(() => { ${script} ; return 'ok'; })()`);
      console.log(typeof r === 'string' ? r : JSON.stringify(r));
    } else if (action === 'close') {
      await mainEval(cdp, `(() => { const f = document.getElementById('dsh-agent-browser'); if (f) f.remove(); return 'ok'; })()`);
      console.log('closed');
    } else {
      throw new Error('usage: browser <open|dom|text|eval|click|type|screenshot|userscript|close> ...');
    }
  } finally {
    cdp.ws.sock.destroy();
  }
}
main().catch((e) => { console.error('browser:', e.message); process.exit(1); });
