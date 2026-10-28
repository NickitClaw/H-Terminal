const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const projectRoot = path.resolve(__dirname, '../../..');
const ByteCodec = {
  encodeText: (text) => Buffer.from(text).toString('base64'),
  encodeBytes: (bytes) => Buffer.from(bytes).toString('base64'),
  decodeBytes: (text) => new Uint8Array(Buffer.from(text, 'base64')),
  decodeText: (text) => Buffer.from(text, 'base64').toString(),
  byteLength: (text) => Buffer.byteLength(text)
};

function createEtsLoader({ native = {}, display = {} } = {}) {
  const cache = new Map();
  const load = (relative) => {
    const filename = path.resolve(projectRoot, relative);
    if (cache.has(filename)) return cache.get(filename);
    if (filename.endsWith('/util/ByteCodec.ets')) return { ByteCodec };
    const module = { exports: {} };
    cache.set(filename, module.exports);
    const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    const requireEts = (specifier) => {
      if (specifier === 'libentry.so') return { default: native, ...native };
      if (specifier === '@kit.ArkUI') return { display };
      if (specifier.startsWith('@kit.')) return {};
      return load(path.resolve(path.dirname(filename), `${specifier}.ets`));
    };
    new Function('require', 'module', 'exports', output)(requireEts, module, module.exports);
    cache.set(filename, module.exports);
    return module.exports;
  };
  return load;
}

function createTerminalHarness(onMessage = () => {}) {
  const messages = [];
  const writes = [];
  let terminal;
  let textarea;
  class FakeTerminal {
    constructor(options) {
      this.options = options;
      this.modes = { applicationCursorKeysMode: false, bracketedPasteMode: false };
      this.cols = 80;
      this.rows = 24;
      this.buffer = { active: { length: 1, getLine: () => ({ translateToString: () => 'fixture <script>你好🙂</script>' }) } };
      terminal = this;
    }
    loadAddon() {} open() {} dispose() {} focus() {} clear() {}
    attachCustomKeyEventHandler(callback) { this.keyHandler = callback; }
    onData(callback) { this.dataHandler = callback; }
    onBinary(callback) { this.binaryHandler = callback; }
    hasSelection() { return false; }
    write(bytes, callback) { writes.push(Buffer.from(bytes)); callback(); }
  }
  const host = {
    clientWidth: 800, clientHeight: 600, addEventListener() {},
    style: {},
    querySelector: () => (textarea = { readOnly: true, blur() {}, setAttribute() {} })
  };
  const selectionHost = { style: {}, textContent: '', hidden: true };
  const searches = [];
  const window = {
    Terminal: FakeTerminal,
    FitAddon: { FitAddon: class { fit() {} } },
    SearchAddon: { SearchAddon: class {
      findNext(query, options) { searches.push({ query, options, backward: false }); return query === 'fixture'; }
      findPrevious(query, options) { searches.push({ query, options, backward: true }); return query === 'fixture'; }
      clearDecorations() {}
    } },
    getSelection: () => ({ toString: () => selectionHost.textContent, removeAllRanges() {} }),
    HTerminalBridge: { postMessage: (json) => {
      const message = JSON.parse(json);
      messages.push(message);
      onMessage(message);
    } }
  };
  vm.runInNewContext(fs.readFileSync(path.join(projectRoot,
    'entry/src/main/resources/rawfile/terminal/terminal.js'), 'utf8'), {
    window, document: { getElementById: id => id === 'local-selection' ? selectionHost : host, addEventListener() {} },
    TextEncoder, TextDecoder, Uint8Array,
    btoa: (text) => Buffer.from(text, 'binary').toString('base64'),
    atob: (text) => Buffer.from(text, 'base64').toString('binary')
  });
  return {
    messages, writes, selectionHost, searches,
    receive: (message) => window.HTerminal.receive(JSON.stringify(message)),
    setInbox: (take) => { window.HTerminalBridge.takeMessage = take; },
    drain: () => window.HTerminal.drain(),
    get terminal() { return terminal; },
    get textarea() { return textarea; }
  };
}

// ArkUI's build DSL is not TypeScript. Extract only the real page methods
// under test, leaving rendering and platform interfaces to the fixture.
function loadPageMethods(names, globals) {
  const text = fs.readFileSync(path.join(projectRoot, 'entry/src/main/ets/pages/Index.ets'), 'utf8')
    .replace('struct Index {', 'class Index {');
  const source = ts.createSourceFile('Index.ts', text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const page = source.statements.find((node) => ts.isClassDeclaration(node) && node.name.text === 'Index');
  const methods = names.map((name) => page.members.find((node) => node.name?.getText(source) === name).getText(source));
  const output = ts.transpileModule(`class Page { ${methods.join('\n')} }\nmodule.exports = Page;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  new Function('module', ...Object.keys(globals), output)(module, ...Object.values(globals));
  return module.exports;
}

module.exports = { createEtsLoader, createTerminalHarness, ByteCodec, loadPageMethods };
