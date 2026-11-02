// Runs the zero-argument exports of a linked module: `name bits`, with a host of either kind.
import { readFileSync } from 'node:fs';
import { WASI } from 'node:wasi';
const [jshost, host, file, ...names] = process.argv.slice(2);
const mod = new WebAssembly.Module(readFileSync(file));
console.log('imports', [...new Set(WebAssembly.Module.imports(mod).map(i => i.module))].join(' ') || '-');
console.log('exports', WebAssembly.Module.exports(mod).map(e => e.name).sort().join(' '));
let inst;
if (host === 'wasi') {
  const wasi = new WASI({ version: 'preview1', returnOnExit: true });
  inst = new WebAssembly.Instance(mod, wasi.getImportObject());
  wasi.initialize(inst);
} else {
  const { createHost } = await import(jshost);
  const h = createHost();
  const julia = {};
  for (const i of WebAssembly.Module.imports(mod)) {
    if (i.module !== 'julia') throw new Error('unresolved import ' + i.module + '.' + i.name);
    julia[i.name] = h.imports.julia[i.name];
  }
  inst = new WebAssembly.Instance(mod, { julia });
}
for (const n of names) console.log(n, String(BigInt.asUintN(64, BigInt(inst.exports[n]()))));
