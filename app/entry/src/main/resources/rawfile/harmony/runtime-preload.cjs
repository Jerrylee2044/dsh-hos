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

