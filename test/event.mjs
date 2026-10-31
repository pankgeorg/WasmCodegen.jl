// The driver of test/event.jl: runs exports of a module (argv[2]) on the host's events
// (`makeJuliaIOEvents` of js/julia_io.mjs) and Node's WASI, against a local HTTP server it
// starts, with a directory (argv[3]) preopened at its own path, which is the module's
// EVENT_DIR. argv[4] is a JSON list of calls [{fn, args: [int...], seed, files}]: each
// export takes the server's port first and is called through `WebAssembly.promising`; `seed`
// {name: content | null} is written (or removed) in the directory before it, `files` [name]
// reported after it (sha256 and size, or null). Prints one JSON line per call, {fn, result,
// ms, ticks, files} or {fn, trap}, then the adapter's {fn: '<stats>', result}.
import { WASI } from 'node:wasi';
import fs from 'node:fs';
import http from 'node:http';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { makeJuliaIOEvents, makeJuliaIOPaths, checkAbiVersion } from '../js/julia_io.mjs';

const [, , wasmPath, dir, callsJson] = process.argv;
const calls = JSON.parse(callsJson);

// the bodies (test/event.jl makes the same natively)
const BIG = Buffer.alloc(6 * 1024 * 1024 + 123);
for (let i = 0; i < BIG.length; i++) BIG[i] = (i * 31 + (i >> 8)) & 0xff;
const open = new Set();
const server = http.createServer((req, res) => {
  const p = new URL(req.url, 'http://x').pathname;
  if (p === '/small') res.end('hello');
  else if (p === '/big') { res.setHeader('content-length', BIG.length); res.end(BIG); }
  else if (p === '/delayed') { res.setHeader('content-length', 3); res.flushHeaders(); setTimeout(() => res.end('abc'), 60); }
  else if (p === '/slow') { res.setHeader('content-length', 1 << 20); res.write(Buffer.alloc(1000, 7)); open.add(res); }
  else if (p === '/redirect') { res.statusCode = 302; res.setHeader('location', '/small'); res.end(); }
  else if (p === '/headers') { res.setHeader('X-Echo', req.headers['x-test'] ?? '-'); res.end(); }
  else if (p === '/404') { res.statusCode = 404; res.end('not found'); }
  else if (p === '/trunc') { res.setHeader('content-length', 100000); res.write(Buffer.alloc(5000, 1)); setTimeout(() => res.socket.destroy(), 20); }
  else { res.statusCode = 500; res.end(); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
fs.writeFileSync(`${dir}/a.gz`, zlib.gzipSync(BIG));
if (typeof zlib.zstdCompressSync === 'function') fs.writeFileSync(`${dir}/a.zst`, zlib.zstdCompressSync(Buffer.from('zstd!')));
fs.writeFileSync(`${dir}/trunc.gz`, zlib.gzipSync(BIG).subarray(0, 1000));
if (typeof zlib.zstdCompressSync === 'function') {
  const z = zlib.zstdCompressSync(Buffer.from('hello world'.repeat(100)));
  fs.writeFileSync(`${dir}/trunc.zst`, z.subarray(0, z.length - 1));
}
fs.writeFileSync(`${dir}/plain`, 'not compressed');

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
try {
  const wasi = new WASI({ version: 'preview1', args: ['event'], env: { EVENT_DIR: dir, PWD: dir, HOME: dir, TMPDIR: dir },
                          preopens: { [dir]: dir }, returnOnExit: true });
  // (every tag configured: a result independent of the host; a record over 1 KiB, retried)
  const events = makeJuliaIOEvents({ preopens: [dir], platformTags: { arch: 'x86_64', os: 'linux', libc: 'musl',
    libgfortran_version: '5.0.0', julia_version: '0.1.0', long: 'x'.repeat(1100) } });
  const paths = makeJuliaIOPaths({ preopens: [dir] });
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const instance = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport,
                                                        julia_io: { ...paths.imports, ...events.imports } });
  events.bindMemory(instance.exports.memory);
  paths.bindMemory(instance.exports.memory);
  wasi.initialize(instance);
  checkAbiVersion(instance, 'event_abi_version', 1);
  for (const c of calls) {
    for (const [n, v] of Object.entries(c.seed || {})) { if (v === null) fs.rmSync(`${dir}/${n}`, { force: true }); else fs.writeFileSync(`${dir}/${n}`, v); }
    const f = WebAssembly.promising(instance.exports[c.fn]);
    let ticks = 0;
    const iv = setInterval(() => ticks++, 5);
    const t0 = performance.now();
    try {
      const r = await f(port, ...(c.args || []));
      const out = { fn: c.fn, result: typeof r === 'bigint' ? r.toString() : r, ms: performance.now() - t0, ticks };
      if (c.files) out.files = Object.fromEntries(c.files.map((n) => {
        const p = `${dir}/${n}`;
        return [n, fs.existsSync(p) ? { sha256: sha(fs.readFileSync(p)), size: fs.statSync(p).size } : null];
      }));
      console.log(JSON.stringify(out));
    } catch (e) {
      console.log(JSON.stringify({ fn: c.fn, trap: String(e && e.message || e) }));
    } finally { clearInterval(iv); }
  }
  console.log(JSON.stringify({ fn: '<stats>', result: events.stats() }));
} finally {
  for (const r of open) r.destroy();
  server.closeAllConnections();
  server.close();
}
