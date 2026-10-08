// Smoke test of extension.js outside VS Code (node test/check_extension.js).
// 1. the real `vscode-languageclient/node` loads (with a stub `vscode` module);
// 2. extension.js loads and exports activate/deactivate;
// 3. activate() (with a stubbed LanguageClient) registers the commands and
//    starts a client with the configured path/args; restart stops/starts it.
'use strict';

const Module = require('module');
const assert = require('assert');
const path = require('path');

// ---- a permissive stub of the `vscode` API ---------------------------------
function permissive(name) {
  // any property access returns another permissive object; callable; constructible
  const f = function () { return permissive(name + '()'); };
  return new Proxy(f, {
    get(target, prop) {
      if (prop === Symbol.toPrimitive) return () => name;
      if (prop === 'then') return undefined; // not a thenable
      if (!(prop in target)) target[prop] = permissive(name + '.' + String(prop));
      return target[prop];
    },
    construct() { return permissive('new ' + name); },
  });
}

const registered = {};
const outputLines = [];
const settings = { path: '~/bin/elpi-lsp', args: ['--foo'], 'trace.server': 'off' };
const vscodeStub = permissive('vscode');
Object.assign(vscodeStub, {
  window: {
    createOutputChannel: (n) => ({ name: n, appendLine: (l) => outputLines.push(l), show() {}, dispose() {} }),
    showErrorMessage: async () => undefined,
    showInformationMessage: async () => undefined,
  },
  commands: {
    registerCommand: (id, fn) => { registered[id] = fn; return { dispose() {} }; },
    executeCommand: async () => undefined,
  },
  workspace: Object.assign(permissive('vscode.workspace'), {
    getConfiguration: (section) => ({ get: (k) => (section === 'elpi-lsp' ? settings[k] : undefined) }),
    onDidChangeConfiguration: () => ({ dispose() {} }),
  }),
});

const origResolve = Module._resolveFilename;
const origLoad = Module._load;
let stubClient = false;
const created = [];
class FakeLanguageClient {
  constructor(id, name, serverOptions, clientOptions) {
    this.id = id; this.serverOptions = serverOptions; this.clientOptions = clientOptions;
    this.running = false; this.starts = 0; this.stops = 0;
    created.push(this);
  }
  async start() { this.running = true; this.starts++; }
  async stop() { this.running = false; this.stops++; }
  isRunning() { return this.running; }
}
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  if (stubClient && request === 'vscode-languageclient/node')
    return { LanguageClient: FakeLanguageClient, TransportKind: { stdio: 0 } };
  return origLoad.apply(this, arguments);
};

(async () => {
  // 1. real client library loads
  const lc = require('vscode-languageclient/node');
  assert.strictEqual(typeof lc.LanguageClient, 'function', 'LanguageClient exported');
  assert.ok('stdio' in lc.TransportKind, 'TransportKind.stdio exported');
  console.log('ok: vscode-languageclient/node loads');

  // 2. extension loads with the real library
  const extPath = path.join(__dirname, '..', 'extension.js');
  let ext = require(extPath);
  assert.strictEqual(typeof ext.activate, 'function');
  assert.strictEqual(typeof ext.deactivate, 'function');
  console.log('ok: extension.js loads and exports activate/deactivate');

  // 3. activate with a stubbed client
  delete require.cache[require.resolve(extPath)];
  stubClient = true;
  ext = require(extPath);
  const context = { subscriptions: [] };
  await ext.activate(context);
  const pkg = require('../package.json');
  for (const c of pkg.contributes.commands)
    assert.ok(registered[c.command], `command ${c.command} registered`);
  assert.strictEqual(created.length, 1);
  const c = created[0];
  assert.strictEqual(c.id, 'elpi-lsp', 'client id matches the settings prefix (trace.server)');
  assert.strictEqual(c.serverOptions.run.command, path.join(require('os').homedir(), 'bin/elpi-lsp'));
  assert.deepStrictEqual(c.serverOptions.run.args, ['--foo']);
  assert.deepStrictEqual(c.clientOptions.documentSelector.map(d => d.language), ['elpi', 'elpi']);
  assert.strictEqual(c.starts, 1);
  console.log('ok: activate starts a client:', c.serverOptions.run.command, c.serverOptions.run.args.join(' '));

  await registered['elpi-lsp.restart']();
  assert.strictEqual(c.stops, 1);
  assert.strictEqual(created.length, 2);
  assert.strictEqual(created[1].starts, 1);
  console.log('ok: restart command stops and restarts the client');

  await ext.deactivate();
  assert.strictEqual(created[1].stops, 1);
  console.log('ok: deactivate stops the client');

  // package.json sanity
  assert.ok(pkg.activationEvents.includes('onLanguage:elpi'));
  assert.ok(pkg.contributes.languages.some(l => l.id === 'elpi' && l.extensions.includes('.elpi')));
  for (const k of ['elpi-lsp.path', 'elpi-lsp.args', 'elpi-lsp.trace.server'])
    assert.ok(pkg.contributes.configuration.properties[k], `setting ${k}`);
  console.log('ok: package.json contributions');
  console.log('ALL OK');
})().catch((e) => { console.error('FAILED:', e); process.exit(1); });
