// Persistent runner: NDJSON requests on stdin, one response per line.
// {id, wasm (base64) | wasmId, fn, args: [{t, bits}], results: [t...], wasi?: {env, args, preopens}}
// (a request with `wasi` options runs a new instance of a WASI module, with those options)
import { createInterface } from 'node:readline';
import { WASI } from 'node:wasi';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHost } from '../js/julia.mjs';
const modules = new Map();
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
let output = '';
let bytes = [];
const decoder = new TextDecoder();
// the output of WASI modules: Node's WASI writes it to a file, read after each call
const wasiOut = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wasmcodegen-')), 'out');
const wasiOutFd = fs.openSync(wasiOut, 'a+');
// a module compiled with `Config(host = :js)` runs with js/julia.mjs; one compiled with
// `host = :wasi` (it exports its memory) with Node's WASI, as a WASI runtime runs it
async function instantiate(mod, opts = {}) {
  const imports = WebAssembly.Module.imports(mod);
  if (WebAssembly.Module.exports(mod).some((e) => e.name === 'memory' && e.kind === 'memory')) {
    for (const imp of imports) {
      if (imp.module !== 'wasi_snapshot_preview1') throw new Error('not a WASI import: ' + imp.module + '.' + imp.name);
    }
    const wasi = new WASI({ version: 'preview1', stdout: wasiOutFd, stderr: wasiOutFd, returnOnExit: true,
                            env: opts.env ?? {}, args: opts.args ?? [], preopens: opts.preopens ?? {} });
    const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
    wasi.initialize(inst);
    return inst;
  }
  const host = createHost({ write: (fd, b) => { for (const x of b) bytes.push(x); } });
  for (const imp of imports) {
    if (imp.module !== 'julia' || !(imp.name in host.imports.julia)) throw new Error('unknown host function ' + imp.module + '.' + imp.name);
  }
  const inst = await WebAssembly.instantiate(mod, { julia: host.imports.julia });
  host.attach(inst);
  return inst;
}
function takeOutput() {
  output += decoder.decode(new Uint8Array(bytes));
  bytes = [];
  const w = fs.readFileSync(wasiOut);
  if (w.length) { output += decoder.decode(w); fs.ftruncateSync(wasiOutFd, 0); }
  const o = output; output = ''; return o;
}
function decode(a) {
  const big = BigInt('0x' + a.bits);
  switch (a.t) {
    case 'i32': return Number(BigInt.asIntN(32, big));
    case 'i64': return BigInt.asIntN(64, big);
    case 'f32': { const b = new ArrayBuffer(4); new Uint32Array(b)[0] = Number(big); return new Float32Array(b)[0]; }
    case 'f64': { const b = new ArrayBuffer(8); new BigUint64Array(b)[0] = big; return new Float64Array(b)[0]; }
  }
  throw new Error('bad arg type ' + a.t);
}
function encode(t, v) {
  switch (t) {
    case 'i32': return (BigInt(v) & 0xffffffffn).toString(16);
    case 'i64': return BigInt.asUintN(64, v).toString(16);
    case 'f32': { const b = new ArrayBuffer(4); new Float32Array(b)[0] = v; return new Uint32Array(b)[0].toString(16); }
    case 'f64': { const b = new ArrayBuffer(8); new Float64Array(b)[0] = v; return new BigUint64Array(b)[0].toString(16); }
  }
  return 'ref';
}
rl.on('line', async (line) => {
  if (!line.trim()) return;
  const req = JSON.parse(line);
  try {
    const key = req.wasi ? req.wasmId + JSON.stringify(req.wasi) : req.wasmId;
    let inst = req.wasi ? undefined : modules.get(key);
    if (!inst) {
      const bytes = Buffer.from(req.wasm, 'base64');
      const mod = await WebAssembly.compile(bytes, { builtins: ['js-string'] });
      inst = await instantiate(mod, req.wasi);
      req.wasi || modules.set(key, inst);
    }
    takeOutput();
    const f = inst.exports[req.fn];
    if (!f) throw new Error('no export ' + req.fn);
    let r;
    try {
      r = f(...req.args.map(decode));
    } catch (e) {
      process.stdout.write(JSON.stringify({ id: req.id, trap: String(e && e.message || e), output: takeOutput() }) + '\n');
      return;
    }
    const rs = req.results.length === 1 ? [r] : (req.results.length === 0 ? [] : r);
    const results = req.results.map((t, i) => encode(t, rs[i]));
    process.stdout.write(JSON.stringify({ id: req.id, results, output: takeOutput() }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ id: req.id, error: String(e && e.stack || e) }) + '\n');
  }
});
process.stdout.write(JSON.stringify({ ready: true }) + '\n');
