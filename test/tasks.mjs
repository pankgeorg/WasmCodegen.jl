// Driver of test/tasks.jl (`Config(tasks = :jspi)`): runs exports of a module (argv[2]) on
// js/julia_io.mjs's events and js/julia_task.mjs, with Node's WASI, each Julia task on its own
// JSPI stack. argv[3]: JSON list of calls [{fn, args, i64, fresh, jsTimer, expectTrap}]. A call
// runs on a new instance unless `fresh` is false (then on the previous call's: tasks it left
// parked may run). `jsTimer`: a setTimeout(0) is armed before the call; the result says
// whether it fired before the call returned. `shutdownAfter`: the host is shut down that many
// ms into the call (which then fails). A call that deadlocks (it never returns, as the native
// program hangs) is reported, and its instance dropped. Prints the module's stdout as it goes
// and one JSON line per call (prefixed with "@@ ") on stderr: {fn, result, ms, host, open,
// jsTimerFired}, {fn, trap, terminal} or {fn, deadlock, host}, and {shutdown: abandoned} when an
// instance is dropped.
import { WASI } from 'node:wasi';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeJuliaIOEvents, makeJuliaIOPaths } from '../js/julia_io.mjs';
import { makeJuliaTask } from '../js/julia_task.mjs';

const [, , wasmPath, callsJson] = process.argv;
const calls = JSON.parse(callsJson);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcg-tasks-'));
const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));

async function instantiate() {
  const wasi = new WASI({ version: 'preview1', args: ['tasks'], env: { HOME: dir, PWD: dir, TMPDIR: dir },
                          preopens: { [dir]: dir }, returnOnExit: true });
  const events = makeJuliaIOEvents();
  const paths = makeJuliaIOPaths({ preopens: [dir] });
  const deadlock = {};
  deadlock.promise = new Promise((r) => { deadlock.resolve = r; });
  const jt = makeJuliaTask({ onDeadlock: () => deadlock.resolve({ deadlock: true }) });
  const instance = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport,
                                                        julia_io: { ...paths.imports, ...events.imports }, ...jt.imports });
  events.bindMemory(instance.exports.memory);
  paths.bindMemory(instance.exports.memory);
  wasi.initialize(instance);
  jt.bind(instance);
  return { instance, events, jt, deadlock };
}

const out = (o) => process.stderr.write('@@ ' + JSON.stringify(o) + '\n');
let code = 0;
let cur = null;
for (const c of calls) {
  if (!cur || c.fresh !== false) {
    if (cur) out({ shutdown: cur.jt.shutdown() });
    cur = await instantiate();
  }
  const { instance, events, jt, deadlock } = cur;
  const args = (c.args || []).map((a) => (c.i64 ? BigInt(a) : a));
  let jsTimerFired = null;
  if (c.jsTimer) { jsTimerFired = false; setTimeout(() => { jsTimerFired = true; }, 0); }
  const t0 = performance.now();
  if (c.shutdownAfter !== undefined) setTimeout(() => jt.shutdown(), c.shutdownAfter);
  try {
    const call = jt.call(instance.exports[c.fn], ...args).then((r) => ({ r }));
    const r = await Promise.race([call, deadlock.promise]);
    if (r.deadlock) {
      call.catch(() => {}); // (fails when the instance is dropped)
      out({ fn: c.fn, deadlock: jt.deadlocked(), host: jt.stats() });
      out({ shutdown: jt.shutdown() });
      cur = null;
      continue;
    }
    out({ fn: c.fn, result: typeof r.r === 'bigint' ? r.r.toString() : r.r, ms: performance.now() - t0,
          host: jt.stats(), open: events.stats().open, jsTimerFired });
  } catch (e) {
    if (!c.expectTrap) code = 1;
    out({ fn: c.fn, trap: String((e && e.message) || e), terminal: !!jt.terminal(), host: jt.stats() });
  }
}
if (cur) out({ shutdown: cur.jt.shutdown() });
fs.rmSync(dir, { recursive: true, force: true });
process.exitCode = code;
