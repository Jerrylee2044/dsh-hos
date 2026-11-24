'use strict';
/**
 * DSH HOS runtime preload (self-developed).
 *
 * HarmonyOS runs Node with --jitless. Two small compatibility fixes are needed:
 *   1. process.report.getReport() walks every CPU sysfs entry and can block the
 *      event loop for ~30s on this device; callers only need a cheap answer.
 *   2. x64 libnode has a cold-start float modulo glitch; exercise it once.
 */
(function () {
  if (process.platform !== 'linux') { return; }
  if (!process.env.IEC_SYSROOT && !process.env.DSH_SYSROOT) { return; }

  if (process.arch === 'x64') {
    var a = 1.5;
    var b = 1.1;
    void (a % b);
  }

  var report = process.report;
  if (!report || typeof report.getReport !== 'function') { return; }
  if (process.env.DSH_LITE_REPORT === '0') { return; }
  var original = report.getReport.bind(report);
  report.getReport = function (options) {
    if (options === undefined) { return { header: {} }; }
    return original(options);
  };
})();

// HarmonyOS denies link(2) inside the app sandbox (EACCES). DSH uses link for
// atomic session commits; emulate it with copyFile, which is allowed.
try {
  const __fs = require('node:fs');
  const __link = __fs.link;
  if (typeof __link === 'function') {
    __fs.link = function (existingPath, newPath, callback) {
      __fs.copyFile(existingPath, newPath, (error) => {
        if (error) { if (callback) callback(error); return; }
        __fs.unlink(existingPath, () => { if (callback) callback(null); });
      });
    };
  }
  if (__fs.promises && typeof __fs.promises.link === 'function') {
    __fs.promises.link = async function (existingPath, newPath) {
      await __fs.promises.copyFile(existingPath, newPath);
      await __fs.promises.unlink(existingPath).catch(() => {});
    };
  }
} catch (error) { /* preload best effort */ }


// HarmonyOS cannot exec a bundled bash. Agent shell tools use Node's
// child_process.spawn('bash', ...); route those calls through the self-developed
// host, which loads libbash.so in-process. This keeps Agent and terminal on the
// same Bash 5.3 runtime.
try {
  const cp = require('node:child_process');
  const net = require('node:net');
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const events = require('node:events');
  const stream = require('node:stream');
  if (cp && typeof cp.spawn === 'function' && !cp.__dshHostBashPatched) {
    const originalSpawn = cp.spawn.bind(cp);
    cp.__dshHostBashPatched = true;
    cp.spawn = function (command, args, options) {
      const argv = Array.isArray(args) ? args.slice() : [];
      const opts = (args && !Array.isArray(args)) ? args : (options || {});
      const base = path.basename(String(command || ''));
      let script = null;
      if (base === 'bash' || base === 'sh') {
        let index = -1;
        for (let i = 0; i < argv.length; i++) {
          if (/^-[A-Za-z]*c[A-Za-z]*$/.test(argv[i])) { index = i; break; }
        }
        if (index >= 0 && typeof argv[index + 1] === 'string') { script = argv[index + 1]; }
      }
      if (script === null) { return originalSpawn(command, args, options); }

      const child = new events.EventEmitter();
      child.stdout = new stream.PassThrough();
      child.stderr = new stream.PassThrough();
      child.stdin = new stream.PassThrough();
      child.pid = 0;
      child.killed = false;
      child.kill = function () { child.killed = true; try { socket.destroy(); } catch (e) {} return true; };

      const cwd = opts.cwd || process.cwd();
      const tmp = path.join(os.tmpdir(), 'dsh-agent-' + process.pid + '-' + Date.now() + '-' + Math.random().toString(16).slice(2) + '.sh');
      let socket;
      try { fs.writeFileSync(tmp, script, { mode: 0o600 }); } catch (error) {
        process.nextTick(function () { child.emit('error', error); child.emit('close', 127, null); });
        return child;
      }

      const env = opts.env || process.env;
      const lines = [cwd, 'bash'];
      const rc = env.DSH_RC || process.env.DSH_RC;
      if (rc) { lines.push('DSH_ENV=BASH_ENV=' + rc); }
      for (const key of Object.keys(env)) {
        if (key === 'BASH_ENV') { continue; }
        const value = env[key];
        if (typeof value === 'string' && value.indexOf('\n') < 0 && value.indexOf('\r') < 0) {
          lines.push('DSH_ENV=' + key + '=' + value);
        }
      }
      lines.push(tmp);
      lines.push('');

      let buffer = Buffer.alloc(0);
      let finished = false;
      const finish = function (code, body) {
        if (finished) { return; }
        finished = true;
        try { fs.unlinkSync(tmp); } catch (e) {}
        if (body && body.length > 0) { child.stdout.write(body); }
        child.stdout.end();
        child.stderr.end();
        if (child.stdin && typeof child.stdin.end === 'function') { child.stdin.end(); }
        child.emit('exit', code, null);
        child.emit('close', code, null);
      };
      socket = net.connect(47654, '127.0.0.1');
      socket.setNoDelay(true);
      socket.on('connect', function () { socket.write(lines.join('\n') + '\n'); });
      socket.on('data', function (chunk) {
        buffer = Buffer.concat([buffer, chunk]);
        const first = buffer.indexOf(10);
        if (first < 0) { return; }
        const second = buffer.indexOf(10, first + 1);
        if (second < 0) { return; }
        const code = Number(buffer.subarray(0, first).toString());
        const length = Number(buffer.subarray(first + 1, second).toString());
        if (!Number.isFinite(code) || !Number.isFinite(length)) { socket.destroy(); finish(127, Buffer.alloc(0)); return; }
        if (buffer.length < second + 1 + length) { return; }
        const body = buffer.subarray(second + 1, second + 1 + length);
        finish(code, body);
        socket.destroy();
      });
      socket.on('error', function (error) {
        if (!finished) {
          child.emit('error', error);
          try { fs.unlinkSync(tmp); } catch (e) {}
          finish(127, Buffer.from(String(error && error.message || error)));
        }
      });
      socket.on('close', function () { if (!finished) { finish(127, Buffer.alloc(0)); } });
      return child;
    };
  }
} catch (error) { /* preload best effort */ }
