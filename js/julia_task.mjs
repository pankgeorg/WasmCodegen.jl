// Julia Tasks for WasmCodegen modules: the `julia_task` imports (version 1), for
// `Config(tasks = :jspi)`, on hosts with JavaScript Promise Integration (JSPI).
//
// Each Julia task runs on its own Wasm stack. The module's scheduler (Julia's own, compiled:
// `schedule`, `yield`, `wait`, `Channel`, `Condition`, `Timer`, ...) decides which task runs;
// this host only moves stacks:
//
//   import `switch(from i32, to i32)`  Suspending. Parks task `from` (its stack waits on a
//       promise) and resumes `to` (resolves its promise) or, on its first run, starts it:
//       `jl_task_entry(to)` on a new stack (`WebAssembly.promising`). `switch(id, id)` parks
//       and resumes the same task: the module lets the host's event loop run while it waits
//       for the host and no other task can run. Never rejects.
//   import `exit(from i32, to i32)`  Synchronous. Task `from` ends (its `jl_task_entry`
//       returns right after): resumes or starts `to` without parking `from`.
//   export `jl_task_entry(id i32) -> i32`  The first run of task `id`, on a new stack; it
//       calls `exit(id, _)` before it returns 0.
//
//   const events = makeJuliaIOEvents({ preopens: ['/abs/dir'] });          // js/julia_io.mjs
//   const jt = makeJuliaTask({ busy: () => events.stats().open > 0 });
//   const instance = await WebAssembly.instantiate(mod, {
//     wasi_snapshot_preview1: wasi.wasiImport, julia_io: events.imports, ...jt.imports });
//   events.bindMemory(instance.exports.memory); wasi.initialize(instance);
//   jt.bind(instance);
//   const r = await jt.call(instance.exports.main);   // a root call: task 0
//   jt.shutdown();                                     // the instance is done
//
// Task ids are i32 in 0..65535: 0 is the task of the root call; the module reuses an id only
// after that task's exit. A transfer is valid iff `from` is the running task, `to` is in range
// and either parked or (`to >= 1`) without a stack; for `exit`, `from >= 1` and `from != to`.
//
// The resumption or start of `to` is deferred until the calling stack has suspended
// (`switch`) or returned (`exit`): exactly one Wasm stack runs at a time, and there is never a
// JS frame between a `promising` call and a suspension. It is a macrotask (`setImmediate`)
// while the host has outstanding work (`busy()`: open `julia_io` handles, i.e. timers and
// HTTP requests), so that Node's timers and I/O run between task switches as native Julia's
// `wait()` runs libuv's events; otherwise a microtask, which costs no event-loop turn. (So a
// task that keeps yielding without waiting for the host starves JavaScript's own timers, as
// it would starve the other tasks' natively without preemption.)
//
// Root calls: one at a time; a task's stack only runs while one is in flight. When a root call
// returns, tasks still parked stay parked, and a later root call may resume them. A trap or a
// rejection of a task's stack or of the root call, an invalid transfer, or a task's stack
// ending without its exit fails the root call in flight, and the instance becomes terminal;
// `shutdown()` makes it terminal when it is no longer needed. Terminal: parked stacks are
// dropped (never resumed), a resumption or start already queued does not run, later failures
// go nowhere and later root calls are refused. The `finally` blocks of abandoned tasks do not
// run: host handles they held stay open until the embedder releases the `julia_io` adapter.

export const JULIA_TASK_VERSION = 1;
export const MAX_TASK_ID = 65535;

export class JuliaTaskError extends Error {}

// Whether a module was built with tasks (it imports julia_task).
export const importsJuliaTask = (mod) => WebAssembly.Module.imports(mod).some((i) => i.module === 'julia_task');

export function makeJuliaTask(opts = {}) {
  const busy = opts.busy || (() => false);
  let entry = null;          // promising(jl_task_entry)
  const parked = new Map();  // task id -> resolve of its parked stack's promise
  const live = new Map();    // id >= 1 with a stack (started, not exited) -> its activation
  let current = -1;          // the id whose stack runs or is about to (-1: none)
  let root = null;           // the root call in flight: { reject }
  let terminal = null;       // why the instance is terminal (an Error), or null
  const st = { roots: 0, switches: 0, starts: 0, exits: 0, handoffs: 0, maxParked: 0, maxLive: 0 };

  // A failure: the root call in flight fails with it; the instance becomes terminal.
  function fail(e) {
    if (terminal) return;
    end(e);
    const r = root;
    root = null;
    if (r) r.reject(e);
  }
  function end(why) {
    terminal = why;
    pending = null;   // (a resumption or start already queued does not run)
    parked.clear();
    live.clear();
    current = -1;
  }
  // The deferred resumption or start: at most one at a time (exactly one stack runs, or is
  // about to), in one slot, run by one function (no allocation per switch)
  let pending = null;
  const runPending = () => { const f = pending; pending = null; if (f) f(); };
  function defer(fn) {
    if (pending) { fail(new JuliaTaskError('julia_task: two transfers pending (internal error)')); return; }
    pending = fn;
    if (busy()) { st.handoffs++; setImmediate(runPending); } else queueMicrotask(runPending);
  }
  const invalid = (msg) => new JuliaTaskError(`julia_task: invalid transfer: ${msg}`);
  // Pass the thread from `from` (which suspends or ends) to `to`; false after a failure.
  function transfer(from, to, what) {
    if (terminal) return false;
    if (from !== current) { fail(invalid(`${what}(${from}, ${to}) from a task that is not running (${current} is)`)); return false; }
    if (!Number.isInteger(to) || to < 0 || to > MAX_TASK_ID) { fail(invalid(`${what}(${from}, ${to}): task id out of range`)); return false; }
    // (switch(id, id): the task yields to the host and resumes itself, below; exit(id, id) is invalid)
    if (to === from && what !== 'switch') { fail(invalid(`${what}(${from}, ${to}): to itself`)); return false; }
    const r = parked.get(to);
    current = to;
    if (r) {
      parked.delete(to);
      defer(r);
      return true;
    }
    if (to === 0) { fail(invalid(`${what}(${from}, 0): the root task is not parked`)); return false; }
    if (live.has(to)) { fail(invalid(`${what}(${from}, ${to}): task ${to} has a stack that is not parked`)); return false; }
    // (an activation of the id: the id may be reused by a new task before this stack's
    // promise settles)
    const act = { exited: false };
    live.set(to, act);
    st.starts++;
    if (live.size > st.maxLive) st.maxLive = live.size;
    defer(() => entry(to).then(() => {
      // (a stack ends only after its exit)
      if (!act.exited) fail(new JuliaTaskError(`julia_task: jl_task_entry(${to}) returned without exit`));
    }, fail));
    return true;
  }

  const imports = {
    switch: new WebAssembly.Suspending((from, to) => {
      st.switches++;
      // (never rejects: after a failure the stack stays parked and is dropped)
      const p = new Promise((r) => parked.set(from, r));
      if (parked.size > st.maxParked) st.maxParked = parked.size;
      if (!transfer(from, to, 'switch')) parked.delete(from);
      return p;
    }),
    exit(from, to) {
      st.exits++;
      if (terminal) return;
      const act = from === 0 ? undefined : live.get(from);
      if (!act) { fail(invalid(`exit(${from}, ${to}) of a task that was not started`)); return; }
      act.exited = true;
      live.delete(from);
      transfer(from, to, 'exit');
    },
  };

  return {
    imports: { julia_task: imports },
    bind(instance) {
      const f = instance.exports.jl_task_entry;
      if (typeof f !== 'function') throw new JuliaTaskError('julia_task: the module imports julia_task but exports no jl_task_entry');
      entry = WebAssembly.promising(f);
    },
    // A root call: the exported function `f` (not yet promising) called with `args` as task 0.
    // Rejects if a task's stack fails while it is in flight.
    call(f, ...args) {
      if (!entry) return Promise.reject(new JuliaTaskError('julia_task: not bound to an instance (bind)'));
      if (terminal) return Promise.reject(new JuliaTaskError(`julia_task: the instance is terminal (${terminal.message ?? terminal})`));
      if (root) return Promise.reject(new JuliaTaskError('julia_task: a root call is in flight (one at a time)'));
      st.roots++;
      return new Promise((resolve, reject) => {
        const me = { reject };
        root = me;
        current = 0;
        let p;
        try { p = WebAssembly.promising(f)(...args); } catch (e) { p = Promise.reject(e); }
        p.then((v) => {
          if (root !== me) return; // (failed meanwhile)
          root = null;
          current = -1;
          resolve(v);
        }, (e) => {
          if (root !== me) return;
          fail(e);
        });
      });
    },
    // The end of the command: the instance becomes terminal. Returns the tasks abandoned.
    // (a root call in flight fails)
    shutdown() {
      const abandoned = { parked: parked.size, live: live.size };
      fail(new JuliaTaskError('julia_task: shut down'));
      return abandoned;
    },
    terminal: () => terminal,
    stats: () => ({ ...st, parked: parked.size, live: live.size }),
  };
}
