// node check.mjs: serve the Worker with workerd (node_modules/.bin/workerd), request each
// route, and compare with the same module on Node (Lorenz) or with native Julia's output
// (build.jl's expected/). Exits 1 on any difference.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { instantiate } from '../../js/julia.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT ?? 8790);
const base = `http://127.0.0.1:${port}`;

async function lorenzOnNode() {
  const module = await WebAssembly.compile(fs.readFileSync(path.join(here, '..', 'lorenz', 'lorenz.wasm')));
  const e = (await instantiate(module)).instance.exports;
  const n = e.lorenz_solve(10, 28, 8 / 3, 1);
  return `points ${n} steps ${e.lorenz_steps()} last x ${e.lorenz_point(n, 1)}\n`;
}
const expected = (f) => fs.readFileSync(path.join(here, 'expected', f), 'utf8');
const checks = [
  ['/lorenz', 'Node', lorenzOnNode],
  ['/tasks', 'native Julia', () => expected('tasks.txt')],
  ['/env', 'native Julia', () => expected('env.txt')],
];

// (the responses must be this workerd's: the port must be free)
if (await fetch(`${base}/`).then(() => true, () => false)) {
  console.log(`FAIL ${base} already answers: stop that server, or set PORT`);
  process.exit(1);
}
const workerd = spawn(path.join(here, 'node_modules', '.bin', 'workerd'),
                      ['serve', path.join(here, 'config.capnp'), '--socket-addr', `http=127.0.0.1:${port}`],
                      { stdio: ['ignore', 'inherit', 'inherit'] });
const exited = new Promise((r) => workerd.on('exit', (code, signal) => r(signal ?? code)));
let failed = false;
try {
  for (let i = 0; ; i++) {
    try { await fetch(`${base}/`); break; } catch (e) {
      if (i === 200 || workerd.exitCode !== null) throw new Error(`workerd did not start: ${e.message}`);
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  for (const [route, against, want] of checks) {
    const res = await fetch(base + route);
    if (workerd.exitCode !== null || workerd.signalCode !== null) throw new Error('workerd exited');
    const got = await res.text(), w = await want();
    const ok = res.ok && got === w;
    failed ||= !ok;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${route}: ${ok ? `matches ${against}` : `differs from ${against}`} (${got.split('\n').length - 1} lines)`);
    if (!ok) console.log(`--- workerd (HTTP ${res.status})\n${got}--- ${against}\n${w}`);
  }
} catch (e) {
  failed = true;
  console.log(`FAIL ${e.message}`);
} finally {
  workerd.kill();
  await exited;
}
process.exitCode = failed ? 1 : 0;
