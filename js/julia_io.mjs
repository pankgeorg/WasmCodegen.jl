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
// arguments `(path_off, path_len)` are raw bytes without a length: an absolute path, UTF-8,
// no NUL. Output buffers with `cap < 4` are `-EINVAL`. Hosts copy every input out of linear
// memory before returning and recreate views per call.
//
// | Import | Signature | Semantics |
// |---|---|---|
// | `timer_start` | `(ns i64) -> i32 handle` | A timer that becomes ready after `ns` nanoseconds. |
// | `poll` | `(interest_off, n_interest, timeout_ns i64, out_off, cap) -> i32` | `interest`: `n_interest` (1 to 1024) `i32` handles. Writes up to `cap` handles of the interest set that are ready, and returns their count. Ready handles outside the interest set are not reported and stay ready. `timeout_ns`: `-1` waits indefinitely, `0` does not wait; a timeout returns `0`. An unknown or closed handle of the interest set is reported ready (its next call is `-EBADF`). Waiting indefinitely with no handle of the interest set that can become ready is `-EINVAL`. **The only suspending import.** |
// | `errmsg` | `(h, out_off, cap) -> i32` | The last error message of the handle (UTF-8, truncated to `cap`), and its length. `h = -1`: the last failure without a handle. |
// | `cancel` | `(h) -> i32` | Cancels the handle: a timer that has not fired becomes ready, cancelled. Idempotent. `0`, or `-EBADF` for an unknown handle. |
// | `close` | `(h) -> i32` | Releases the handle, cancelling it: `0`. A closed or unknown handle is `-EBADF` (closing twice too). |
// | `path_mode` | `(path_off, path_len, follow i32) -> i32` | The POSIX `st_mode` (type and permission bits) of the absolute path (of the link itself unless `follow`), or `-errno`. (WASI preview 1 has no permission bits.) |
// | `path_chmod` | `(path_off, path_len, mode i32) -> i32 status` | `chmod(2)` of the absolute path (following links). |
// | `path_symlink` | `(target_off, target_len, link_off, link_len) -> i32 status` | `symlink(2)`: a symbolic link at the absolute path `link` to `target`, which is any string (absolute, or out of the preopens), never resolved nor validated, as natively. (WASI's `path_symlink` refuses such targets.) |
//
// **Paths.** The path imports (`path_mode`, `path_chmod`, `path_symlink`'s `link`) check
// every path (`checkPath(path, {follow})`) against the preopens: absolute, without NUL;
// normalized lexically (`.` and `..`); within a preopen (on component boundaries); and the
// deepest existing ancestor (the path itself if `follow`), resolved (`realpath`), still
// within one. Otherwise `-ENOTCAPABLE` (76). This checks paths: it cannot exclude another
// process replacing a checked directory with a link before its use.
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
const utf8dec = new TextDecoder('utf-8', { fatal: true });

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
// Fails closed: a component that cannot be examined or resolved (other than "does not
// exist") is a denial.
const within = (p, d) => p === d || p.startsWith(d === path.sep ? d : d + path.sep);
const ABSENT = new Set(['ENOENT', 'ENOTDIR']);

export function makeCheckPath(preopens) {
  const lexical = preopens.map((p) => {
    if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error('julia_io: preopen must be an absolute path: ' + p);
    return path.resolve(p);
  });
  const real = lexical.map((p) => {
    try { return fs.realpathSync.native(p); }
    catch (e) { throw new Error(`julia_io: preopen ${p} cannot be resolved: ${e.message}`); }
  });
  // checkPath(p, {follow}) -> the normalized absolute path, or throws GuestError(ENOTCAPABLE)
  return function checkPath(p, { follow = true } = {}) {
    const deny = (why) => { throw new GuestError(E.NOTCAPABLE, `path not permitted (${why}): ${p}`); };
    if (typeof p !== 'string' || p.includes('\0')) deny('NUL byte');
    if (!path.isAbsolute(p)) deny('not absolute');
    const r = path.resolve(p); // (`.` and `..`, lexically)
    if (!lexical.some((d) => within(r, d))) deny('outside every preopen');
    // the deepest existing ancestor (the path itself when following)
    let probe = follow ? r : path.dirname(r);
    for (;;) {
      try { fs.lstatSync(probe); break; }
      catch (e) { if (!ABSENT.has(e.code)) deny(`cannot examine ${probe}: ${e.code || e.message}`); }
      const up = path.dirname(probe);
      if (up === probe) deny('no existing ancestor');
      probe = up;
    }
    let rp;
    try { rp = fs.realpathSync.native(probe); }
    catch (e) { deny(`cannot resolve ${probe}: ${e.code || e.message}`); } // (a dangling link, ELOOP)
    if (!real.some((d) => within(rp, d))) deny('resolves outside every preopen');
    return r;
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
  function readPath(off, len) {
    const b = readBytes(off, len);
    try { return utf8dec.decode(b); } catch { throw new GuestError(E.ILSEQ, 'path is not valid UTF-8'); }
  }
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
  const checkPath = makeCheckPath(opts.preopens || []);
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

  // the preopened directories themselves: inspecting one is allowed whether or not the last
  // component is followed (`checkPath`, not following, looks at its parent, out of reach)
  const preopenRoots = new Set((opts.preopens || []).map((d) => path.resolve(d)));
  // the POSIX st_mode (type and permission bits) of the path, of the link itself unless
  // `follow`; a path ending with a separator must be a directory (as stat(2))
  function path_mode(path_off, path_len, follow) {
    const raw = readPath(path_off, path_len);
    const isRoot = path.isAbsolute(raw) && !raw.includes('\0') && preopenRoots.has(path.resolve(raw));
    const p = isRoot ? path.resolve(raw) : checkPath(raw, { follow: follow !== 0 });
    let mode;
    try { mode = (follow !== 0 ? fs.statSync(p) : fs.lstatSync(p)).mode; }
    catch (e) { throw new GuestError(errnoOf(e), `path_mode ${p}: ${describe(e)}`); }
    if (raw.length > 1 && raw.endsWith('/') && (mode & 0o170000) !== 0o040000) {
      // (a link to a directory, with a trailing separator, is followed by stat(2); a path it
      // may not follow keeps its error: ENOTDIR only for what is not a directory)
      const q = checkPath(raw, { follow: true });
      let st;
      try { st = fs.statSync(q); }
      catch (e) { throw new GuestError(errnoOf(e), `path_mode ${q}: ${describe(e)}`); }
      if (!st.isDirectory()) throw new GuestError(E.NOTDIR, `path_mode ${raw}: not a directory`);
      return st.mode;
    }
    return mode;
  }
  // chmod(2) of the path (following links, as chmod does)
  function path_chmod(path_off, path_len, mode) {
    const p = checkPath(readPath(path_off, path_len), { follow: true });
    try { fs.chmodSync(p, mode & 0o7777); return 0; }
    catch (e) { throw new GuestError(errnoOf(e), `path_chmod ${p}: ${describe(e)}`); }
  }
  // symlink(2): the link `link` (checked, its last component not followed) to `target`, raw
  // bytes neither checked nor resolved (any string, as natively)
  function path_symlink(target_off, target_len, link_off, link_len) {
    const target = Buffer.from(readBytes(target_off, target_len));
    if (target.includes(0)) throw new GuestError(E.INVAL, 'path_symlink: target contains a NUL byte');
    const link = checkPath(readPath(link_off, link_len), { follow: false });
    try { fs.symlinkSync(target, link); return 0; }
    catch (e) { throw new GuestError(errnoOf(e), `path_symlink ${link}: ${describe(e)}`); }
  }

  return {
    imports: { path_mode: wrap(path_mode, true), path_chmod: wrap(path_chmod, false),
               path_symlink: wrap(path_symlink, false) },
    checkPath,
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
    const x = { kind: 'timer', fired: false, cancelled: false, t: null, errmsg: '', closed: false };
    const deadline = performance.now() + Number(ns) / 1e6;
    const arm = () => {
      const ms = deadline - performance.now();
      if (ms <= 0) { x.t = null; x.fired = true; notify(); return; }
      x.t = setTimeout(arm, Math.min(Math.ceil(ms), 0x7fffffff));
    };
    const h = newHandle(x);
    arm();
    return h;
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
      if (timeout_ns > 0n)
        timer = setTimeout(() => { timedOut = true; notify(); }, Math.min(Math.ceil(Number(timeout_ns) / 1e6), 0x7fffffff));
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
    if (!x.fired) { clearTimeout(x.t); x.t = null; x.fired = true; x.cancelled = true; x.errmsg = 'timer cancelled'; notify(); }
    return 0;
  }

  function close(h) {
    h |= 0;
    const x = handles.get(h);
    if (!x) return -E.BADF;
    if (x.t) clearTimeout(x.t);
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
