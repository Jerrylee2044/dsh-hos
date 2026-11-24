'use strict';
/**
 * DSH HOS fetch polyfill (self-developed).
 *
 * Node 24 on HarmonyOS runs with --jitless, so WebAssembly is absent and
 * undici's built-in fetch cannot parse HTTP. This module implements the subset
 * DSH uses with node:http/https:
 *   - string / Buffer / Uint8Array / ArrayBuffer / URLSearchParams / Blob / FormData
 *   - streaming response bodies, gzip/deflate/br
 *   - redirects with method/header rewriting
 *   - AbortSignal
 *
 * Installed only when WebAssembly is unavailable. DSH_FORCE_FETCH_POLYFILL=1
 * forces it for local tests.
 */
(function () {
  var force = process.env.DSH_FORCE_FETCH_POLYFILL === '1';
  if (!force && typeof globalThis.WebAssembly !== 'undefined') { return; }

  var http = require('node:http');
  var https = require('node:https');
  var zlib = require('node:zlib');
  var stream = require('node:stream');

  var MAX_REDIRECTS = 20;
  var CROSS_ORIGIN_DROP = ['authorization', 'cookie', 'proxy-authorization', 'host'];

  function abortError() {
    var error = new Error('The operation was aborted.');
    error.name = 'AbortError';
    return error;
  }

  function normalizeHeaders(input) {
    var headers = new Headers();
    if (!input) { return headers; }
    if (typeof input.forEach === 'function') {
      input.forEach(function (value, key) { headers.append(key, value); });
      return headers;
    }
    Object.keys(input).forEach(function (key) {
      var value = input[key];
      if (value === undefined || value === null) { return; }
      if (Array.isArray(value)) { value.forEach(function (item) { headers.append(key, String(item)); }); }
      else { headers.set(key, String(value)); }
    });
    return headers;
  }

  async function bodyBytes(body) {
    if (body === undefined || body === null) { return null; }
    if (typeof body === 'string') { return { data: Buffer.from(body), type: 'text/plain;charset=UTF-8' }; }
    if (Buffer.isBuffer(body)) { return { data: body, type: null }; }
    if (body instanceof Uint8Array) { return { data: Buffer.from(body), type: null }; }
    if (body instanceof ArrayBuffer) { return { data: Buffer.from(body), type: null }; }
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      return { data: Buffer.from(body.toString()), type: 'application/x-www-form-urlencoded;charset=UTF-8' };
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) {
      return { data: Buffer.from(await body.arrayBuffer()), type: body.type || null };
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      var boundary = '----dshhos' + Math.random().toString(16).slice(2);
      var chunks = [];
      for (const pair of body.entries()) {
        var key = pair[0];
        var value = pair[1];
        chunks.push(Buffer.from('--' + boundary + '\r\n'));
        if (typeof Blob !== 'undefined' && value instanceof Blob) {
          var filename = value.name || 'blob';
          chunks.push(Buffer.from('Content-Disposition: form-data; name="' + key + '"; filename="' + filename + '"\r\n'));
          chunks.push(Buffer.from('Content-Type: ' + (value.type || 'application/octet-stream') + '\r\n\r\n'));
          chunks.push(Buffer.from(await value.arrayBuffer()));
        } else {
          chunks.push(Buffer.from('Content-Disposition: form-data; name="' + key + '"\r\n\r\n'));
          chunks.push(Buffer.from(String(value)));
        }
        chunks.push(Buffer.from('\r\n'));
      }
      chunks.push(Buffer.from('--' + boundary + '--\r\n'));
      return { data: Buffer.concat(chunks), type: 'multipart/form-data; boundary=' + boundary };
    }
    if (body && typeof body.pipe === 'function') {
      var chunks2 = [];
      for await (const chunk of body) { chunks2.push(Buffer.from(chunk)); }
      return { data: Buffer.concat(chunks2), type: null };
    }
    return { data: Buffer.from(String(body)), type: null };
  }

  function decoderFor(encoding) {
    var value = String(encoding || '').toLowerCase();
    if (value === 'gzip' || value === 'x-gzip') { return zlib.createGunzip(); }
    if (value === 'deflate') { return zlib.createInflate(); }
    if (value === 'br') { return zlib.createBrotliDecompress(); }
    return null;
  }

  function once(target, name) {
    return new Promise(function (resolve, reject) {
      target.once(name, resolve);
      target.once('error', reject);
    });
  }

  async function request(url, init, redirects) {
    init = init || {};
    var method = String(init.method || 'GET').toUpperCase();
    var headers = normalizeHeaders(init.headers);
    if (!headers.has('accept')) { headers.set('accept', '*/*'); }
    if (!headers.has('user-agent')) { headers.set('user-agent', 'DSH-HOS/1'); }
    var body = await bodyBytes(init.body);
    if (body && body.type && !headers.has('content-type')) { headers.set('content-type', body.type); }
    if (body) { headers.set('content-length', String(body.data.length)); }
    if (init.signal && init.signal.aborted) { throw abortError(); }

    var parsed;
    try { parsed = new URL(url); } catch (error) { throw new TypeError('Invalid URL: ' + url); }
    var transport = parsed.protocol === 'https:' ? https : http;
    var options = {
      protocol: parsed.protocol,
      hostname: parsed.hostname,
      port: parsed.port || undefined,
      path: parsed.pathname + parsed.search,
      method: method,
      headers: Object.fromEntries(headers.entries())
    };

    var response = await new Promise(function (resolve, reject) {
      var req = transport.request(options, resolve);
      var onAbort = function () { req.destroy(abortError()); };
      if (init.signal) { init.signal.addEventListener('abort', onAbort, { once: true }); }
      req.on('error', function (error) {
        if (init.signal) { init.signal.removeEventListener('abort', onAbort); }
        reject(init.signal && init.signal.aborted ? abortError() : error);
      });
      if (body) { req.write(body.data); }
      req.end();
    });

    if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
      response.resume();
      if (init.redirect === 'error') { throw new TypeError('Redirect not allowed'); }
      if (init.redirect !== 'manual') {
        if (redirects >= MAX_REDIRECTS) { throw new TypeError('Too many redirects'); }
        var location = new URL(response.headers.location, parsed).toString();
        var next = Object.assign({}, init);
        if (response.statusCode === 303 || ((response.statusCode === 301 || response.statusCode === 302) && method === 'POST')) {
          next.method = 'GET';
          next.body = undefined;
        }
        if (new URL(location).origin !== parsed.origin) {
          next.headers = Object.fromEntries(headers.entries());
          CROSS_ORIGIN_DROP.forEach(function (name) { delete next.headers[name]; });
        }
        return request(location, next, redirects + 1);
      }
    }

    var decode = decoderFor(response.headers['content-encoding']);
    var source = decode ? response.pipe(decode) : response;
    var web = stream.Readable.toWeb(source);
    var responseHeaders = new Headers();
    Object.keys(response.headers).forEach(function (key) {
      var value = response.headers[key];
      if (value === undefined) { return; }
      if (Array.isArray(value)) { value.forEach(function (item) { responseHeaders.append(key, item); }); }
      else { responseHeaders.set(key, value); }
    });
    var result = new Response(web, {
      status: response.statusCode,
      statusText: response.statusMessage || '',
      headers: responseHeaders
    });
    try {
      Object.defineProperty(result, 'url', { value: parsed.toString() });
      Object.defineProperty(result, 'redirected', { value: redirects > 0 });
    } catch (error) { /* 某些 Response 实现不可扩展 */ }
    if (method === 'HEAD' || response.statusCode === 204 || response.statusCode === 205 || response.statusCode === 304) {
      try { await result.body?.cancel(); } catch (error) { /* 已无 body */ }
    }
    return result;
  }

  globalThis.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input instanceof URL ? input.toString() : input.url);
    var options = init || {};
    if (!options.method && input && input.method) { options.method = input.method; }
    if (!options.headers && input && input.headers) { options.headers = input.headers; }
    return request(url, options, 0);
  };
})();
