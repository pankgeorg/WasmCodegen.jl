// The host's events, file modes and symbolic links for WasmCodegen modules: the `julia_io`
// imports (version 1), for `Config(host = :wasi, host_extensions = [:julia_io])`.
//
// In Wasm, the runtime's `sleep` (`src/runtime/event.jl`) and the file modes and symbolic
// links of its filesystem (`src/runtime/fs.jl`) are calls of these imports. They come in two
// parts, each from its own factory, so that a host that only wants the filesystem's needs no
// JavaScript Promise Integration (JSPI):
//
//   - `makeJuliaIOPaths(opts)`: `path_mode`, `path_chmod`, `path_symlink`; synchronous.
//   - `makeJuliaIOEvents(opts)`: the others. `poll` suspends the module (it is a
//     `WebAssembly.Suspending`): the exports that may wait must be called through
//     `WebAssembly.promising`, and Node needs JSPI (`--experimental-wasm-jspi` where it is
//     not on by default).
//
//   const paths = makeJuliaIOPaths({ preopens: ['/abs/dir'] });          // WASI's preopens
//   const events = makeJuliaIOEvents();
//   const instance = await WebAssembly.instantiate(mod, {
//     wasi_snapshot_preview1: wasi.wasiImport, julia_io: { ...paths.imports, ...events.imports } });
//   paths.bindMemory(instance.exports.memory); events.bindMemory(instance.exports.memory);
//   wasi.initialize(instance);
//   const r = await WebAssembly.promising(instance.exports.main)();
//
// `preopens` are the directories WASI preopens, which the module sees at the same paths.
// The module passes offsets of its memory only as arguments.
//
// The interface:
//
// **Conventions.** Status returns are `i32`: `0` is success, a positive value a WASI errno.
// Handle and count returns are `i32`: `≥ 0` a value, `< 0` a negated WASI errno. No import
// throws or rejects for expected failures (filesystem errors, bad arguments): they come back
// as errnos, with a message for `errmsg`. Every import body is wrapped: an unexpected
// exception becomes `EIO`, its message kept for `errmsg`. `poll` resolves; it never rejects.
// Violations of the interface by the caller (a call while `poll` is suspended: two promising
// calls in flight on one instance) are exceptions (`JuliaIOAssertion`), which trap.
//
// **Memory.** Arrays of handles are `i32`s, little-endian, at a 4-byte-aligned offset. Path
// arguments `(path_off, path_len)` are raw bytes without a length: an absolute path, no NUL,
// in any encoding (a file name need not be UTF-8, natively). Output buffers with `cap < 4`
// are `-EINVAL`. Hosts copy every input out of linear memory before returning and recreate
// views per call.
//
// | Import | Signature | Semantics |
// |---|---|---|
// | `timer_start` | `(ns i64) -> i32 handle` | A timer that becomes ready after `ns` nanoseconds, from the host's event loop: never before it has turned, even for `0` (as libuv's timers), so that a wait on it lets the host's other events progress. |
// | `poll` | `(interest_off, n_interest, timeout_ns i64, out_off, cap) -> i32` | `interest`: `n_interest` (1 to 1024) `i32` handles. Writes up to `cap` handles of the interest set that are ready, and returns their count. Ready handles outside the interest set are not reported and stay ready. `timeout_ns`: `-1` waits indefinitely, `0` does not wait; a timeout returns `0`. An unknown or closed handle of the interest set is reported ready (its next call is `-EBADF`). Waiting indefinitely with no handle of the interest set that can become ready is `-EINVAL`. **The only suspending import.** |
// | `errmsg` | `(h, out_off, cap) -> i32` | The last error message of the handle (UTF-8, truncated to `cap`), and its length. `h = -1`: the last failure without a handle. |
// | `cancel` | `(h) -> i32` | Cancels the handle: a timer that has not fired becomes ready, cancelled. Idempotent. `0`, or `-EBADF` for an unknown handle. |
// | `close` | `(h) -> i32` | Releases the handle, cancelling it: `0`. A closed or unknown handle is `-EBADF` (closing twice too). |
// | `path_mode` | `(path_off, path_len, follow i32) -> i32` | The POSIX `st_mode` (type and permission bits) of the absolute path (of the link itself unless `follow`), or `-errno`. (WASI preview 1 has no permission bits.) |
// | `path_chmod` | `(path_off, path_len, mode i32) -> i32 status` | `chmod(2)` of the absolute path (following links). |
// | `path_symlink` | `(target_off, target_len, link_off, link_len) -> i32 status` | `symlink(2)`: a symbolic link at the absolute path `link` to `target`, which is any bytes (absolute, or out of the preopens), never resolved nor validated, as natively. (WASI's `path_symlink` refuses such targets.) |
//
// **Paths.** The path imports (`path_mode`, `path_chmod`, `path_symlink`'s `link`) resolve
// a path within the preopens, one component at a time as the kernel does: a symbolic link is
// followed (the last component only if the import follows it, or the path ends with a
// separator), its target from the link's directory. The lookup's errors are the kernel's
// (`ENOENT`, `ENOTDIR`, `ELOOP` after 40 links, `EACCES`, ...); a path, a link or a `..` that
// leaves the preopens is `-ENOTCAPABLE` (76), before anything outside them is examined; a
// path that is not absolute, or has a NUL byte, `-EINVAL`. The operation then acts on the
// resolved path, by its name (Node has no `openat`): what remains racy is another process
// replacing a checked directory of it with a link before the operation, which follows it.
// The final component is not followed: `path_mode` is an `lstat` of it, `path_symlink` makes
// it (an existing name is `EEXIST`), and `path_chmod` changes the mode of a descriptor opened
// without following a link (`O_NOFOLLOW`), checked to be the file resolved; but for a file it
// cannot open for reading (not readable, or not a file nor a directory), which it changes by
// its name after an `lstat` that it is no link (racy: a link put in its place in between is
// followed).
//
// **Readiness** is level-triggered: a timer is ready from when it fires (or is cancelled)
// until it is closed. Callers close every handle (in `finally` blocks).

import fs from 'node:fs';
import path from 'node:path';

export const JULIA_IO_VERSION = 1;

// WASI preview 1 errnos (wasi-libc's api.h)
export const E = Object.freeze({
  ACCES: 2, AGAIN: 6, BADF: 8, BUSY: 10, CANCELED: 11, EXIST: 20, FBIG: 22, ILSEQ: 25,
  INVAL: 28, IO: 29, ISDIR: 31, LOOP: 32, MFILE: 33, NAMETOOLONG: 37, NOBUFS: 42, NOENT: 44,
  NOMEM: 48, NOSPC: 51, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58, PERM: 63, ROFS: 69,
  XDEV: 75, NOTCAPABLE: 76,
});

// Node's error codes -> WASI errnos
const CODE_TO_ERRNO = {
  ENOENT: E.NOENT, EEXIST: E.EXIST, EACCES: E.ACCES, EPERM: E.PERM, EROFS: E.ROFS,
  ENOTDIR: E.NOTDIR, EISDIR: E.ISDIR, ENOTEMPTY: E.NOTEMPTY, EXDEV: E.XDEV, EBUSY: E.BUSY,
  ENOSPC: E.NOSPC, EMFILE: E.MFILE, ENAMETOOLONG: E.NAMETOOLONG, EINVAL: E.INVAL, EIO: E.IO,
  EFBIG: E.FBIG, ELOOP: E.LOOP,
};

const utf8enc = new TextEncoder();

// A violation of the interface by the caller (a bug of the module or of the embedder, not an
// expected failure): not an errno, it escapes as a trap.
export class JuliaIOAssertion extends Error {
  constructor(msg) { super('julia_io: ' + msg); this.name = 'JuliaIOAssertion'; }
}

// An expected failure: its errno and message.
export class GuestError extends Error {
  constructor(errno, msg) { super(msg); this.errno = errno; }
}

function describe(e) {
  if (!(e instanceof Error)) return String(e);
  let m = e.message;
  const c = e.cause;
  if (c) m += ': ' + (c.code ? c.code + ' ' : '') + (c.message || String(c));
  else if (e.code && !m.includes(e.code)) m = e.code + ' ' + m;
  return m;
}

export function errnoOf(e) {
  if (e instanceof GuestError) return e.errno;
  const c = e && e.cause;
  for (const x of [c && c.code, e && e.code, c && c.cause && c.cause.code]) {
    if (x && CODE_TO_ERRNO[x] !== undefined) return CODE_TO_ERRNO[x];
  }
  return E.IO;
}

// ---- paths (see "Paths" above), for every path import ----
// A path is bytes: a 'latin1' string of them (a character per byte) for the lookup, a Buffer
// of them for `fs`.
const latin1 = (b) => Buffer.from(b).toString('latin1');
const bytesOf = (s) => Buffer.from(s, 'latin1');
const shown = (s) => bytesOf(s).toString(); // (for messages)
const components = (s) => s.split('/').filter((c) => c !== '');
// the links a lookup follows at most (Linux's MAXSYMLINKS), beyond which it is ELOOP
const MAX_LINKS = 40;

export function makeResolve(preopens) {
  // each preopen by its path and by its real path, as components
  const roots = preopens.map((p) => {
    if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error('julia_io: preopen must be an absolute path: ' + p);
    let real;
    try { real = components(latin1(fs.realpathSync.native(p, { encoding: 'buffer' }))); }
    catch (e) { throw new Error(`julia_io: preopen ${p} cannot be resolved: ${e.message}`); }
    return { names: [components(latin1(Buffer.from(path.resolve(p)))), real], real };
  });
  const prefix = (names, comps) => names.length <= comps.length && names.every((c, i) => c === comps[i]);
  // the components of the real path of what the absolute path `comps` names in the deepest
  // preopen it is in, its preopen's and the rest; or null
  function rootOf(comps) {
    let best = null;
    for (const r of roots) for (const names of r.names) {
      if (prefix(names, comps) && (!best || names.length > best.n)) best = { real: r.real, n: names.length };
    }
    return best && { done: [...best.real], todo: comps.slice(best.n) };
  }
  const inside = (comps) => roots.some((r) => prefix(r.real, comps));

  // resolve(p, follow) -> the real path (latin1) of what the absolute path `p` (latin1) names,
  // its last component followed if `follow` (see "Paths" above); a missing last component is
  // left for the operation to report
  return function resolve(p, follow) {
    const lookup = `lookup of ${shown(p)}`;
    const deny = (why) => { throw new GuestError(E.NOTCAPABLE, `path not permitted (${why}): ${shown(p)}`); };
    if (p.includes('\0')) throw new GuestError(E.INVAL, `${lookup}: a NUL byte`);
    if (!p.startsWith('/')) throw new GuestError(E.INVAL, `${lookup}: not absolute`);
    let dir = p.length > 1 && p.endsWith('/');
    const start = rootOf(components(p));
    if (!start) deny('outside every preopen');
    let { done, todo } = start;
    let links = 0;
    while (todo.length) {
      const c = todo.shift();
      if (c === '.' || c === '..') {
        // (looked up in a resolved directory, which needs search permission, as the kernel's
        // lookup does; `..`: its parent, lexically)
        try { fs.lstatSync(bytesOf('/' + [...done, c].join('/'))); }
        catch (e) { throw new GuestError(errnoOf(e), `${lookup}: ${describe(e)}`); }
        if (c === '..') {
          done.pop();
          if (!inside(done)) deny('`..` leaves the preopens');
        }
        continue;
      }
      const next = [...done, c];
      const last = todo.length === 0;
      if (last && !follow && !dir) { done = next; break; }
      const file = bytesOf('/' + next.join('/'));
      let st;
      try { st = fs.lstatSync(file); }
      catch (e) {
        if (last && e.code === 'ENOENT') { done = next; break; }
        throw new GuestError(errnoOf(e), `${lookup}: ${describe(e)}`);
      }
      if (st.isSymbolicLink()) {
        if (++links > MAX_LINKS) throw new GuestError(E.LOOP, `${lookup}: too many levels of symbolic links`);
        let target;
        try { target = latin1(fs.readlinkSync(file, { encoding: 'buffer' })); }
        catch (e) { throw new GuestError(errnoOf(e), `${lookup}: ${describe(e)}`); }
        if (target === '') throw new GuestError(E.NOENT, `${lookup}: a link to nothing`);
        // (a target ending with a separator names a directory, followed, as a path does)
        if (todo.length === 0 && target.endsWith('/')) dir = true;
        if (target.startsWith('/')) {
          const t = rootOf(components(target));
          if (!t) deny(`a link to ${shown(target)} leaves the preopens`);
          done = t.done;
          todo = [...t.todo, ...todo];
        } else {
          todo = [...components(target), ...todo];
        }
        continue;
      }
      if ((!last || dir) && !st.isDirectory()) throw new GuestError(E.NOTDIR, `${lookup}: not a directory`);
      done = next;
    }
    return '/' + done.join('/');
  };
}

// ---- the module's memory, shared by both factories ----
function makeMemory(initial) {
  let memory = initial || null;
  function mem() {
    if (!memory) throw new JuliaIOAssertion('memory not bound (call bindMemory)');
    return new Uint8Array(memory.buffer); // (views are made again at every access)
  }
  function view() { mem(); return new DataView(memory.buffer); }
  function checkRange(off, len, align = 1) {
    off >>>= 0; len >>>= 0;
    if (off % align) throw new GuestError(E.INVAL, `offset ${off} is not ${align}-byte aligned`);
    if (off + len > mem().byteLength) throw new GuestError(E.INVAL, `range [${off}, ${off + len}) outside linear memory`);
    return [off, len];
  }
  function readBytes(off, len, align = 1) {
    [off, len] = checkRange(off, len, align);
    return mem().slice(off, off + len); // (a copy: inputs never alias linear memory)
  }
  // a path: its bytes as they are, as a 'latin1' string (see "paths" above)
  const readPath = (off, len) => latin1(readBytes(off, len));
  function bindMemory(m) {
    if (!(m instanceof WebAssembly.Memory)) throw new Error('julia_io: bindMemory needs the exported WebAssembly.Memory');
    memory = m;
  }
  return { mem, view, checkRange, readBytes, readPath, bindMemory };
}

// ---------------------------------------------------------------------------------------
// The file modes and symbolic links: `path_mode`, `path_chmod`, `path_symlink`. Synchronous
// (no JSPI). Options: `preopens` (WASI's), `memory` (or `bindMemory` later).
export function makeJuliaIOPaths(opts = {}) {
  const { readBytes, readPath, bindMemory } = makeMemory(opts.memory);
  const resolve = makeResolve(opts.preopens || []);
  let lastError = '';
  // an import: an expected failure is its errno (negated for `path_mode`), anything else EIO
  const wrap = (f, negate) => (...args) => {
    try { return f(...args); }
    catch (e) {
      if (e instanceof JuliaIOAssertion) throw e;
      lastError = describe(e);
      return negate ? -errnoOf(e) : errnoOf(e);
    }
  };
  // `f` of the resolved path `p`; its error is the operation's
  function act(what, p, f) {
    try { return f(bytesOf(p)); }
    catch (e) { throw new GuestError(errnoOf(e), `${what} ${shown(p)}: ${describe(e)}`); }
  }

  // the POSIX st_mode (type and permission bits) of the path, of the link itself unless
  // `follow` (resolved, the path names no link but that one)
  function path_mode(path_off, path_len, follow) {
    const p = resolve(readPath(path_off, path_len), follow !== 0);
    return act('path_mode', p, (b) => fs.lstatSync(b).mode);
  }
  // chmod(2) of the path (following links, as chmod does): of the resolved file, opened without
  // following a link put in its place since (`O_NOFOLLOW`), and the same file (its device and
  // inode) as resolved: its descriptor's (`fchmod`); a file that cannot be opened so (not
  // readable, not a file or a directory), by its path after an `lstat` that it is no link
  function path_chmod(path_off, path_len, mode) {
    const p = resolve(readPath(path_off, path_len), true);
    return act('path_chmod', p, (b) => {
      const st = fs.lstatSync(b);
      if (st.isSymbolicLink()) throw new GuestError(E.LOOP, `path_chmod ${shown(p)}: replaced by a symbolic link`);
      if (st.isFile() || st.isDirectory()) {
        const C = fs.constants;
        let fd = -1;
        try { fd = fs.openSync(b, C.O_RDONLY | C.O_NOFOLLOW | C.O_NONBLOCK | (st.isDirectory() ? C.O_DIRECTORY : 0)); }
        catch (e) { if (e.code !== 'EACCES') throw e; }
        if (fd >= 0) {
          try {
            const fst = fs.fstatSync(fd);
            if (fst.dev !== st.dev || fst.ino !== st.ino) throw new GuestError(E.AGAIN, `path_chmod ${shown(p)}: replaced meanwhile`);
            fs.fchmodSync(fd, mode & 0o7777);
          } finally { fs.closeSync(fd); }
          return 0;
        }
      }
      fs.chmodSync(b, mode & 0o7777);
      return 0;
    });
  }
  // symlink(2): the link `link` (its last component not followed) to `target`, raw bytes
  // neither checked nor resolved (any bytes, as natively)
  function path_symlink(target_off, target_len, link_off, link_len) {
    const target = Buffer.from(readBytes(target_off, target_len));
    if (target.includes(0)) throw new GuestError(E.INVAL, 'path_symlink: target contains a NUL byte');
    const link = resolve(readPath(link_off, link_len), false);
    return act('path_symlink', link, (b) => (fs.symlinkSync(target, b), 0));
  }

  return {
    imports: { path_mode: wrap(path_mode, true), path_chmod: wrap(path_chmod, false),
               path_symlink: wrap(path_symlink, false) },
    bindMemory,
    // the message of the last failure (the module reads only the errno)
    lastError: () => lastError,
  };
}

// ---------------------------------------------------------------------------------------
// The events: timers, `poll` (suspending), `errmsg`, `cancel`, `close`. Options: `memory`.
export function makeJuliaIOEvents(opts = {}) {
  if (typeof WebAssembly.Suspending !== 'function')
    throw new Error('julia_io: the events need JavaScript Promise Integration (WebAssembly.Suspending; Node: --experimental-wasm-jspi)');
  const { mem, view, checkRange, readBytes, bindMemory } = makeMemory(opts.memory);

  const handles = new Map(); // id -> entry (open handles only)
  let nextHandle = 1; // (ids are never reused)
  let lastError = ''; // errmsg(-1)
  let inPoll = false;
  let waker = null; // resolves the suspended poll
  const stats = { maxOpen: 0, started: 0 };

  // ---- bookkeeping ----
  function notify() { if (waker) { const w = waker; waker = null; w(); } }
  function newHandle(entry) {
    const h = nextHandle++;
    entry.id = h;
    handles.set(h, entry);
    stats.started++;
    if (handles.size > stats.maxOpen) stats.maxOpen = handles.size;
    return h;
  }
  function get(h) { return handles.get(h | 0); }
  function guard(name) {
    if (inPoll) throw new JuliaIOAssertion(`${name} called while poll is suspended (two promising calls in flight on one instance)`);
  }
  // an import: an assertion is rethrown; any other exception is an errno, by `fail`
  function wrap(name, f, fail) {
    return (...args) => {
      guard(name);
      try { return f(...args); }
      catch (e) {
        if (e instanceof JuliaIOAssertion) throw e;
        return fail(e, args[0]);
      }
    };
  }
  // the message (the handle's when the import has one, else for errmsg(-1)), and the errno
  function fault(e, h) {
    const m = describe(e);
    const x = h !== undefined && get(h);
    if (x) x.errmsg = m; else lastError = m;
    return errnoOf(e);
  }
  const neg = (e) => -fault(e);
  const negH = (e, h) => -fault(e, h);

  // ready: fired (or cancelled); pending: may become ready without the module doing anything
  const isReady = (x) => x.fired;
  const isPending = (x) => !x.fired;

  // ---- timers ----
  function timer_start(ns) {
    ns = BigInt.asIntN(64, BigInt(ns));
    if (ns < 0n) throw new GuestError(E.INVAL, `timer_start: negative duration ${ns}`);
    const x = { kind: 'timer', fired: false, cancelled: false, t: null, immediate: false, errmsg: '', closed: false };
    const deadline = performance.now() + Number(ns) / 1e6;
    const arm = () => {
      x.immediate = false;
      const ms = deadline - performance.now();
      if (ms <= 0) { x.t = null; x.fired = true; notify(); return; }
      x.t = setTimeout(arm, Math.min(Math.ceil(ms), 0x7fffffff));
    };
    const h = newHandle(x);
    // (first in the event loop's next turn, even when due: libuv runs a timer of 0 there, so
    // that `sleep(0)` lets the host's other events progress)
    x.t = setImmediate(arm);
    x.immediate = true;
    return h;
  }
  function disarm(x) {
    if (x.t !== null) (x.immediate ? clearImmediate : clearTimeout)(x.t);
    x.t = null;
  }

  // ---- poll (the only suspending import) ----
  function readyOf(interest, cap) {
    const out = [];
    for (const h of interest) {
      if (out.length >= cap) break;
      const x = handles.get(h);
      if (!x || isReady(x)) out.push(h); // (unknown or closed: ready; the next call is EBADF)
    }
    return out;
  }
  const anyPending = (interest) => interest.some((h) => { const x = handles.get(h); return x && isPending(x); });
  function writeReady(list, off) {
    const dv = view();
    for (let i = 0; i < list.length; i++) dv.setInt32(off + 4 * i, list[i], true);
    return list.length;
  }

  function poll(interest_off, n_interest, timeout_ns, out_off, cap) {
    guard('poll');
    try {
      n_interest |= 0; cap |= 0; out_off >>>= 0;
      timeout_ns = BigInt.asIntN(64, BigInt(timeout_ns));
      if (n_interest < 1 || n_interest > 1024) throw new GuestError(E.INVAL, `poll: n_interest ${n_interest} not in 1..1024`);
      if (cap < 1) throw new GuestError(E.INVAL, `poll: cap ${cap} < 1`);
      if (timeout_ns < -1n) throw new GuestError(E.INVAL, `poll: bad timeout ${timeout_ns}`);
      const ib = readBytes(interest_off, 4 * n_interest, 4);
      const idv = new DataView(ib.buffer);
      const interest = Array.from({ length: n_interest }, (_, i) => idv.getInt32(4 * i, true));
      checkRange(out_off, 4 * cap, 4);
      const ready = readyOf(interest, cap);
      if (ready.length || timeout_ns === 0n) return writeReady(ready, out_off);
      if (timeout_ns === -1n && !anyPending(interest))
        throw new GuestError(E.INVAL, 'poll: waiting indefinitely, but no handle of the interest set can become ready');
      return suspend(interest, timeout_ns, out_off, cap);
    } catch (e) {
      if (e instanceof JuliaIOAssertion) throw e;
      return neg(e);
    }
  }

  async function suspend(interest, timeout_ns, out_off, cap) {
    inPoll = true;
    let timer = null, timedOut = false;
    try {
      if (timeout_ns > 0n) {
        // (armed again until the deadline: a timeout is at most 2^31 - 1 ms, 24.8 days)
        const deadline = performance.now() + Number(timeout_ns) / 1e6;
        const arm = () => {
          const ms = deadline - performance.now();
          if (ms <= 0) { timer = null; timedOut = true; notify(); return; }
          timer = setTimeout(arm, Math.min(Math.ceil(ms), 0x7fffffff));
        };
        arm();
      }
      for (;;) {
        await new Promise((r) => { waker = r; });
        waker = null;
        const ready = readyOf(interest, cap);
        if (ready.length || timedOut) return writeReady(ready, out_off);
        if (timeout_ns === -1n && !anyPending(interest)) {
          lastError = 'poll: no handle of the interest set can become ready any more';
          return -E.INVAL;
        }
      }
    } catch (e) {
      if (e instanceof JuliaIOAssertion) throw e;
      return neg(e);
    } finally {
      if (timer) clearTimeout(timer);
      inPoll = false;
      waker = null;
    }
  }

  // ---- errmsg, cancel, close ----
  function errmsg(h, out_off, cap) {
    let m;
    if ((h | 0) === -1) m = lastError;
    else { const x = get(h); if (!x) return -E.BADF; m = x.errmsg || ''; }
    cap >>>= 0;
    if (cap < 4) throw new GuestError(E.INVAL, `errmsg: cap ${cap} < 4`);
    let b = utf8enc.encode(m);
    if (b.length > cap) b = b.subarray(0, cap);
    checkRange(out_off, b.length);
    mem().set(b, out_off >>> 0);
    return b.length;
  }

  function cancel(h) {
    const x = get(h);
    if (!x) return -E.BADF;
    if (!x.fired) { disarm(x); x.fired = true; x.cancelled = true; x.errmsg = 'timer cancelled'; notify(); }
    return 0;
  }

  function close(h) {
    h |= 0;
    const x = handles.get(h);
    if (!x) return -E.BADF;
    disarm(x);
    x.closed = true;
    handles.delete(h);
    notify();
    return 0;
  }

  const imports = {
    timer_start: wrap('timer_start', timer_start, neg),
    poll: new WebAssembly.Suspending(poll),
    errmsg: wrap('errmsg', errmsg, neg),
    cancel: wrap('cancel', cancel, negH),
    close: wrap('close', close, negH),
  };

  return {
    imports,
    bindMemory,
    // introspection, for tests and diagnostics
    stats() { return { open: handles.size, ...stats }; },
    handleState(h) {
      const x = get(h);
      if (!x) return null;
      return { kind: 'timer', fired: x.fired, cancelled: x.cancelled, ready: isReady(x) };
    },
  };
}

// The names of the imports of each factory.
export const PATH_IMPORTS = Object.freeze(['path_mode', 'path_chmod', 'path_symlink']);
export const EVENT_IMPORTS = Object.freeze(['timer_start', 'poll', 'errmsg', 'cancel', 'close']);

// Check the version of the interface a module was built for: the export `name` (a function
// of no arguments, `Config(abi_version = name => version)`) must return `version`; throws
// with a message otherwise.
export function checkAbiVersion(instance, name, version) {
  const v = instance.exports[name];
  if (typeof v !== 'function') throw new Error(`julia_io: the module exports no ${name}`);
  const got = v();
  if (got !== version) throw new Error(`julia_io: the module's ${name} is ${got}, not ${version}`);
}
