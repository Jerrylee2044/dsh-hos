'use strict';
function requireBuiltin(id) {
  try {
    const value = require(id);
    process.stderr.write('[SHIM] ' + id + ' -> ' + typeof value + '\n');
    return value;
  } catch (error) {
    process.stderr.write('[SHIMERR] ' + id + ' -> ' + error.message + '\n');
    return undefined;
  }
}
function isAllowedInternalId(id) { return typeof id === 'string' && id.length > 0; }
function getBindingInfo() {
  return { mode: 'dsh-hos', product: 'dsh-node-addon-require-builtin', backend: 'napi', abi: 'napi-v9' };
}
module.exports = { requireBuiltin, isAllowedInternalId, getBindingInfo, default: { requireBuiltin, isAllowedInternalId, getBindingInfo } };
