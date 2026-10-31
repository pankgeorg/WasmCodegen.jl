// A Worker running WasmCodegen modules. workerd compiles each `.wasm` module of the
// configuration ahead of time and imports it as a `WebAssembly.Module` (a Worker cannot
// compile Wasm bytes while it handles a request). Each request instantiates its module.
//
//   GET /lorenz  the Lorenz system (a `host = :js` module), solved and summarized
//   GET /tasks   Julia Tasks on JSPI stacks: the stdout of `main_safe`
//   GET /env     a WASI program: its environment and clock
import lorenz from 'lorenz.wasm';
import tasks from 'tasks.wasm';
import env from 'env.wasm';
import { createHost } from 'julia.mjs';
import { makeJuliaIOEvents } from 'julia_io.mjs';
import { makeJuliaTask } from 'julia_task.mjs';

// the module's stdout, as text (its stderr to the console, line by line)
function stdout() {
  const out = [], err = [];
  const write = (fd, b) => {
    if (fd === 1) { out.push(...b); return; }
    for (const x of b) {
      if (x !== 10) { err.push(x); continue; }
      console.error(new TextDecoder().decode(new Uint8Array(err)));
      err.length = 0;
    }
  };
  write.text = () => new TextDecoder().decode(new Uint8Array(out));
  return write;
}

async function runLorenz() {
  const host = createHost();
  const instance = await WebAssembly.instantiate(lorenz, host.imports);
  const e = instance.exports;
  const n = e.lorenz_solve(10, 28, 8 / 3, 1);
  return `points ${n} steps ${e.lorenz_steps()} last x ${e.lorenz_point(n, 1)}\n`;
}

async function runTasks() {
  const out = stdout();
  const host = createHost({ write: out });
  // (timers only: no network, and no preopened directory)
  const events = makeJuliaIOEvents({ network: false });
  const jt = makeJuliaTask({ busy: () => events.stats().open > 0 });
  const instance = await WebAssembly.instantiate(tasks, { ...host.imports, julia_io: events.imports, ...jt.imports });
  events.bindMemory(instance.exports.memory);
  host.attach(instance);
  jt.bind(instance);
  try {
    await jt.call(instance.exports.main_safe);
  } finally {
    jt.shutdown();
  }
  return out.text();
}

async function runEnv() {
  const out = stdout();
  const host = createHost({ write: out, env: { WCG_GREETING: 'hello', WCG_TARGET: 'workerd' } });
  const instance = await WebAssembly.instantiate(env, host.imports);
  host.attach(instance);
  instance.exports.env_clock(Date.now() / 1000);
  return out.text();
}

const ROUTES = { '/lorenz': runLorenz, '/tasks': runTasks, '/env': runEnv };

export default {
  async fetch(request) {
    const run = ROUTES[new URL(request.url).pathname];
    if (!run) return new Response('not found\n', { status: 404 });
    try {
      return new Response(await run());
    } catch (e) {
      return new Response(`${e?.stack ?? e}\n`, { status: 500 });
    }
  },
};
