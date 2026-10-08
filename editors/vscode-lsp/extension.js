// Elpi LSP (experimental) -- VS Code client for the `elpi-lsp` server.
// Plain JavaScript, no build step.
'use strict';

const os = require('os');
const path = require('path');
const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client = undefined;
let outputChannel = undefined;
let traceChannel = undefined;

function expandHome(p) {
  if (p === '~') return os.homedir();
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

function serverOptions() {
  const config = vscode.workspace.getConfiguration('elpi-lsp');
  const command = expandHome(config.get('path') || 'elpi-lsp');
  const args = config.get('args') || [];
  const executable = { command, args, transport: TransportKind.stdio };
  return { run: executable, debug: executable };
}

function clientOptions() {
  return {
    documentSelector: [
      { scheme: 'file', language: 'elpi' },
      { scheme: 'untitled', language: 'elpi' },
    ],
    outputChannel,          // server stderr + client logs
    traceOutputChannel: traceChannel, // elpi-lsp.trace.server
  };
}

async function startClient() {
  const opts = serverOptions();
  outputChannel.appendLine(
    `[elpi-lsp] starting server: ${opts.run.command} ${opts.run.args.join(' ')}`);
  // The id 'elpi-lsp' makes vscode-languageclient read the
  // 'elpi-lsp.trace.server' setting.
  client = new LanguageClient('elpi-lsp', 'Elpi LSP', opts, clientOptions());
  try {
    await client.start();
    outputChannel.appendLine('[elpi-lsp] server started');
  } catch (e) {
    const msg = `Elpi LSP: cannot start server "${opts.run.command}": ${e && e.message ? e.message : e}. ` +
      'Check the setting elpi-lsp.path.';
    outputChannel.appendLine('[elpi-lsp] ' + msg);
    vscode.window.showErrorMessage(msg, 'Open settings', 'Show output').then(choice => {
      if (choice === 'Open settings')
        vscode.commands.executeCommand('workbench.action.openSettings', 'elpi-lsp');
      else if (choice === 'Show output')
        outputChannel.show(true);
    });
  }
}

async function stopClient() {
  if (!client) return;
  const c = client;
  client = undefined;
  try {
    if (c.isRunning()) await c.stop();
  } catch (e) {
    outputChannel.appendLine(`[elpi-lsp] error while stopping server: ${e}`);
  }
}

async function restart() {
  outputChannel.appendLine('[elpi-lsp] restarting server');
  await stopClient();
  await startClient();
}

async function activate(context) {
  outputChannel = vscode.window.createOutputChannel('Elpi LSP');
  traceChannel = vscode.window.createOutputChannel('Elpi LSP Trace');
  context.subscriptions.push(outputChannel, traceChannel);

  context.subscriptions.push(
    vscode.commands.registerCommand('elpi-lsp.restart', restart),
    vscode.commands.registerCommand('elpi-lsp.showOutput', () => outputChannel.show(true)),
    vscode.workspace.onDidChangeConfiguration(e => {
      if (e.affectsConfiguration('elpi-lsp.path') || e.affectsConfiguration('elpi-lsp.args')) {
        vscode.window.showInformationMessage(
          'Elpi LSP: server settings changed.', 'Restart server').then(choice => {
          if (choice === 'Restart server') restart();
        });
      }
    }),
  );

  await startClient();
}

function deactivate() {
  return stopClient();
}

module.exports = { activate, deactivate };
