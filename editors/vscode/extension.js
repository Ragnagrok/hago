// The Hago extension: runs `hago check` on a .hgo file when it is opened and
// whenever it is saved, and shows the error it prints as a diagnostic. Plain
// JavaScript with no dependencies, so the folder can be installed as it is.
'use strict';

const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const { parseCheckOutput } = require('./diagnostics');

let diagnostics;
let output;
// for each checked file, the files its last check put diagnostics on
const reported = new Map();
// the check running for each file, so a new save cancels the old one
const running = new Map();
let warnedMissing = false;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection('hago');
  output = vscode.window.createOutputChannel('Hago');
  context.subscriptions.push(diagnostics, output);

  const onSave = doc => {
    if (doc.languageId === 'hago' && config().get('checkOnSave', true)) check(doc);
  };
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument(onSave),
    vscode.workspace.onDidOpenTextDocument(onSave),
    vscode.workspace.onDidCloseTextDocument(doc => {
      if (doc.languageId === 'hago') forget(doc.uri.fsPath);
    }),
    vscode.commands.registerCommand('hago.check', () => {
      const editor = vscode.window.activeTextEditor;
      if (editor && editor.document.languageId === 'hago') check(editor.document);
    }),
  );
  vscode.workspace.textDocuments.forEach(onSave);
}

function deactivate() {
  for (const child of running.values()) child.kill();
}

function config() {
  return vscode.workspace.getConfiguration('hago');
}

function forget(file) {
  for (const uri of reported.get(file) || []) diagnostics.delete(vscode.Uri.file(uri));
  reported.delete(file);
}

function check(doc) {
  if (doc.uri.scheme !== 'file') return;
  const file = doc.uri.fsPath;
  const previous = running.get(file);
  if (previous) previous.kill();
  const cwd = path.dirname(file);
  const child = execFile(config().get('path', 'hago'), ['check', file], { cwd, timeout: 60000 }, (err, stdout, stderr) => {
    if (running.get(file) === child) running.delete(file);
    if (err && err.killed) return;
    if (err && err.code === 'ENOENT') {
      if (!warnedMissing) {
        warnedMissing = true;
        vscode.window.showWarningMessage(
          'Hago: cannot run "' + config().get('path', 'hago') + '". Set hago.path to the hago binary.');
      }
      return;
    }
    forget(file);
    if (!err) return;
    const text = (stderr || '') + (stdout || '');
    output.appendLine(text.trim());
    publish(file, parseCheckOutput(text, cwd));
  });
  running.set(file, child);
}

// Puts each problem on the file it is in, or on the checked file when that
// file is not on disk (a module of the library compiled into hago) or the
// error names no place.
function publish(checked, problems) {
  const byFile = new Map();
  for (const p of problems) {
    let file = p.file;
    let line = p.line;
    let column = p.column;
    let width = p.width;
    let message = p.message;
    if (!file || !fs.existsSync(file)) {
      if (file) message = path.basename(file) + ':' + (p.line + 1) + ':' + (p.column + 1) + ': ' + message;
      file = checked;
      line = 0;
      column = 0;
      width = 0;
    }
    add(byFile, file, rangeOf(file, line, column, width), message);
    // an error in a module the file imports is also shown on the file itself
    if (file !== checked) {
      add(byFile, checked, rangeOf(checked, 0, 0, 0),
        'in ' + path.relative(path.dirname(checked), file) + ':' + (line + 1) + ':' + (column + 1) + ': ' + message);
    }
  }
  for (const [file, ds] of byFile) diagnostics.set(vscode.Uri.file(file), ds);
  reported.set(checked, [...byFile.keys()]);
}

function add(byFile, file, range, message) {
  const d = new vscode.Diagnostic(range, message, vscode.DiagnosticSeverity.Error);
  d.source = 'hago';
  if (!byFile.has(file)) byFile.set(file, []);
  byFile.get(file).push(d);
}

// hago counts columns as its lexer does, with a tab moving to the next
// multiple of 8; the editor counts characters.
function rangeOf(file, line, column, width) {
  const doc = vscode.workspace.textDocuments.find(d => d.uri.fsPath === file);
  let text = null;
  if (doc && line < doc.lineCount) text = doc.lineAt(line).text;
  if (text === null) {
    try { text = fs.readFileSync(file, 'utf8').split('\n')[line] || ''; } catch (e) { text = ''; }
  }
  let visual = 0;
  let index = 0;
  while (index < text.length && visual < column) {
    visual = text[index] === '\t' ? (Math.floor(visual / 8) + 1) * 8 : visual + 1;
    index++;
  }
  const end = width > 0 ? Math.min(text.length, index + width) : text.length;
  return new vscode.Range(line, index, line, end);
}

module.exports = { activate, deactivate };
