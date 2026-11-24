// Minimal Alpine apk installer for DSH HOS.
// QEMU user-mode cannot mount /proc, so real apk --root fails before install.
// This tool resolves APKINDEX dependencies and extracts .apk (tar.gz) directly.
import https from 'node:https';
import net from 'node:net';
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = (process.env.IEC_SYSROOT || process.env.DSH_SYSROOT) + '/qemu-root';
const CACHE = path.join(ROOT, '.apk-cache');
const REPOS = [
  { name: 'main', url: 'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.20/main/x86_64' },
  { name: 'community', url: 'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.20/community/x86_64' }
];

function get(url, redirect = 0) {
  return new Promise((resolve, reject) => {
    if (redirect > 5) return reject(new Error('too many redirects'));
    https.get(url, { rejectUnauthorized: false, timeout: 60000, headers: { 'User-Agent': 'curl/8.20.0', 'Accept': '*/*' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume(); return resolve(get(new URL(res.headers.location, url).toString(), redirect + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('HTTP ' + res.statusCode + ' ' + url)); }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject).on('timeout', function () { this.destroy(new Error('timeout')); });
  });
}


function hostExec(command, args) {
  return new Promise((resolve, reject) => {
    const cwd = path.join(process.env.IEC_SYSROOT, '..', 'home');
    const lines = [cwd, command, ...args, ''];
    const socket = net.connect(47654, '127.0.0.1');
    let data = Buffer.alloc(0);
    socket.on('connect', () => socket.write(lines.join('\n') + '\n'));
    socket.on('data', (chunk) => {
      data = Buffer.concat([data, chunk]);
      const first = data.indexOf(10);
      const second = first < 0 ? -1 : data.indexOf(10, first + 1);
      if (second < 0) return;
      const code = Number(data.subarray(0, first).toString());
      const length = Number(data.subarray(first + 1, second).toString());
      if (data.length < second + 1 + length) return;
      socket.destroy();
      resolve({ code, body: data.subarray(second + 1, second + 1 + length) });
    });
    socket.on('error', reject);
    socket.setTimeout(120000, () => { socket.destroy(); reject(new Error('host timeout')); });
  });
}

function parseTar(buf) {
  const files = [];
  let off = 0;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    const name = header.subarray(0, 100).toString().replace(/\0.*$/, '');
    if (!name) break;
    const sizeText = header.subarray(124, 136).toString().replace(/\0.*$/, '').trim();
    const size = parseInt(sizeText, 8) || 0;
    const mode = parseInt(header.subarray(100, 108).toString().replace(/\0.*$/, '').trim(), 8) || 0o644;
    const type = String.fromCharCode(header[156] || 48);
    const link = header.subarray(157, 257).toString().replace(/\0.*$/, '');
    const data = buf.subarray(off + 512, off + 512 + size);
    files.push({ name, size, mode, type, link, data });
    off += 512 + Math.ceil(size / 512) * 512;
  }
  return files;
}

function parseIndex(gz) {
  const entries = parseTar(zlib.gunzipSync(gz));
  const idx = entries.find((e) => e.name === 'APKINDEX');
  if (!idx) throw new Error('APKINDEX missing');
  const out = [];
  for (const block of idx.data.toString('utf8').split(/\n\n+/)) {
    const fields = {};
    for (const line of block.split('\n')) {
      const m = /^([A-Za-z]):(.*)$/.exec(line);
      if (m) fields[m[1]] = m[2];
    }
    if (fields.P) out.push(fields);
  }
  return out;
}

function compareVer(a, b) { return String(a).localeCompare(String(b), undefined, { numeric: true }); }

function indexAll() {
  return Promise.all(REPOS.map(async (repo) => {
    const gz = await get(repo.url + '/APKINDEX.tar.gz');
    return parseIndex(gz).map((e) => ({ ...e, repo }));
  })).then((all) => {
    const map = new Map();
    for (const entry of all.flat()) {
      const old = map.get(entry.P);
      if (!old || compareVer(entry.V, old.V) > 0) map.set(entry.P, entry);
    }
    return map;
  });
}

function safeJoin(dest, name) {
  const p = path.normalize(path.join(dest, name));
  if (!p.startsWith(path.normalize(dest + '/'))) throw new Error('unsafe path ' + name);
  return p;
}

function extractApk(gz, dest) {
  const files = parseTar(zlib.gunzipSync(gz));
  for (const f of files) {
    if (f.name === '.PKGINFO' || f.name === '.SIGN.RSA' || f.name.startsWith('.SIGN')) continue;
    if (f.name === '.' || f.name === './') continue;
    const target = safeJoin(dest, f.name.replace(/^\.?\//, ''));
    if (f.type === '5') { fs.mkdirSync(target, { recursive: true }); continue; }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    if (f.type === '2') {
      try { fs.rmSync(target, { force: true }); fs.symlinkSync(f.link, target); }
      catch { try { fs.copyFileSync(safeJoin(dest, f.link.replace(/^\.?\//, '')), target); } catch {} }
      continue;
    }
    fs.writeFileSync(target, f.data, { mode: f.mode & 0o777 });
    try { fs.chmodSync(target, f.mode & 0o777); } catch {}
  }
}

function depNames(text) {
  if (!text) return [];
  return text.split(/\s+/).filter(Boolean).map((d) => d.replace(/^[!]/, '').split(/[<>=~]/)[0])
    .filter((d) => d && !d.startsWith('/') && !d.startsWith('so:') && !d.startsWith('cmd:') && !d.startsWith('pc:') && !d.startsWith('!'));
}

async function install(names, seen = new Set()) {
  const index = await indexAll();
  const queue = [...names];
  const order = [];
  while (queue.length) {
    const name = queue.shift();
    if (seen.has(name)) continue;
    seen.add(name);
    const pkg = index.get(name);
    if (!pkg) throw new Error('package not found: ' + name);
    for (const dep of depNames(pkg.D)) queue.push(dep);
    order.push(pkg);
  }
  for (const pkg of order) {
    const url = pkg.repo.url + '/' + (pkg.F || (pkg.P + '-' + pkg.V + '.apk'));
    console.log('installing', pkg.P, pkg.V);
    const gz = await get(url);
    const file = path.join(CACHE, pkg.P + '-' + pkg.V + '.apk');
    fs.writeFileSync(file, gz);
    const result = await hostExec('tar', ['-xzf', file, '-C', ROOT, '--no-same-owner']);
    if (result.code !== 0) {
      console.error('tar failed', result.code, result.body.toString('utf8').slice(0, 500));
      throw new Error('extract failed: ' + pkg.P);
    }
    fs.mkdirSync(path.join(ROOT, 'lib/apk/db'), { recursive: true });
    fs.appendFileSync(path.join(ROOT, 'lib/apk/db/installed'), '\n' + pkg.P + '-' + pkg.V + '\n');
  }
  console.log('done:', order.map((p) => p.P).join(' '));
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  fs.mkdirSync(CACHE, { recursive: true });
  if (!cmd || cmd === 'add') {
    if (!rest.length) throw new Error('usage: apk add <package...>');
    await install(rest);
  } else if (cmd === 'update') {
    const index = await indexAll();
    console.log('index packages:', index.size);
  } else if (cmd === 'info' || cmd === 'search') {
    const index = await indexAll();
    for (const p of [...index.values()].sort((a, b) => a.P.localeCompare(b.P))) {
      if (!rest.length || p.P.includes(rest[0])) console.log(p.P, p.V);
    }
  } else {
    throw new Error('unsupported: ' + cmd);
  }
}
main().catch((e) => { console.error('apk-install:', e.message); process.exit(1); });
