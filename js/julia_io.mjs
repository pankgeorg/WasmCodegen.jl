// The host's events, file modes and symbolic links for WasmCodegen modules: the `julia_io`
// imports (version 1), for `Config(host = :wasi, host_extensions = [:julia_io])`.
//
// In Wasm, the runtime's `sleep`, its HTTP requests, decompression and host platform
// (`src/runtime/event.jl`) and the file modes and symbolic links of its filesystem
// (`src/runtime/fs.jl`) are calls of these imports. They come in two parts, each from its
// own factory, so that a host that only wants the filesystem's needs no JavaScript Promise
// Integration (JSPI):
//
//   - `makeJuliaIOPaths(opts)`: `path_mode`, `path_chmod`, `path_symlink`; synchronous.
//   - `makeJuliaIOEvents(opts)`: the others. `poll` suspends the module (it is a
//     `WebAssembly.Suspending`): the exports that may wait must be called through
//     `WebAssembly.promising`, and Node needs JSPI (`--experimental-wasm-jspi` where it is
//     not on by default).
//
//   const paths = makeJuliaIOPaths({ preopens: ['/abs/dir'] });          // WASI's preopens
//   const events = makeJuliaIOEvents({ preopens: ['/abs/dir'], network: true,
//                                      platformTags: { libgfortran_version: '5.0.0' } });
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
// Handle and count returns are `i32` (`read`: `i64`): `≥ 0` a value, `< 0` a negated WASI
// errno. "Not ready" is `-EAGAIN` (6). No import throws or rejects for expected failures
// (network errors, HTTP failures, bad data, filesystem errors): they come back as errnos,
// with a message for `errmsg`. Every import body is wrapped: an unexpected exception becomes
// `EIO`, its message kept for `errmsg`. `poll` resolves; it never rejects. Violations of the
// interface by the caller (a call while `poll` is suspended: two promising calls in flight
// on one instance) are exceptions (`JuliaIOAssertion`), which trap.
//
// **Records.** A record starts at a 4-byte-aligned offset; its fields are packed, without
// padding: `u32` is 4 bytes little-endian (unaligned inside records), `str` a `u32` byte
// length then the bytes (UTF-8, no NUL). Path arguments `(path_off, path_len)` are raw bytes
// without a length: an absolute path, UTF-8, no NUL. Output buffers with `cap < 4` are
// `-EINVAL`. Hosts copy every input out of linear memory before returning and recreate
// views per call.
//
// | Import | Signature | Semantics |
// |---|---|---|
// | `http_start` | `(spec_off, spec_len) -> i32 handle` | spec = `str method, str url, u32 n, (str name, str value)*n, u32 flags` (bit 0: follow redirects, at most 10). Methods `GET`, `HEAD`; no request body; schemes `http`, `https`. Starts the request; never blocks. |
// | `http_head` | `(h, out_off, out_cap) -> i32` | Not ready: `-EAGAIN`. Ready: writes `u32 status, str final_url, u32 n, (str name, str value)*n` (header names as the server sent them) and returns its length. `out_cap` too small: the length needed as a `u32` at `out_off`, and `-ENOBUFS` (42). Transport failure: `-errno` (`-ECONNREFUSED`, `-EIO`, ...). |
// | `read` | `(h, off, len) -> i64` | The next body bytes: `> 0` bytes copied; `0` the end of the body; `-EAGAIN` not ready; `-errno`. The bytes as sent (no `Content-Encoding` decoding). The host buffers at most 4 MiB per handle and pauses the transfer above that. |
// | `timer_start` | `(ns i64) -> i32 handle` | A timer that becomes ready after `ns` nanoseconds. |
// | `poll` | `(interest_off, n_interest, timeout_ns i64, out_off, cap) -> i32` | `interest`: `n_interest` (1 to 1024) `i32` handles. Writes up to `cap` handles of the interest set that are ready, and returns their count. Ready handles outside the interest set are not reported and stay ready. `timeout_ns`: `-1` waits indefinitely, `0` does not wait; a timeout returns `0`. An unknown or closed handle of the interest set is reported ready (its next call is `-EBADF`). Waiting indefinitely with no handle of the interest set that can become ready is `-EINVAL`. **The only suspending import.** |
// | `errmsg` | `(h, out_off, cap) -> i32` | The last error message of the handle (UTF-8, truncated to `cap`), and its length. `h = -1`: the last failure without a handle. |
// | `cancel` | `(h) -> i32` | Aborts the operation of the handle (it becomes cancelled: `-ECANCELED`, 11). Idempotent. `0`, or `-EBADF` for an unknown handle. |
// | `close` | `(h) -> i32` | Releases the handle, aborting what it does: `0`. A closed or unknown handle is `-EBADF` (closing twice too). |
// | `decompress` | `(src_off, src_len, dst_off, dst_len) -> i32 status` | Synchronous. Decompresses the file `src` into `dst` (absolute paths): gzip (`1f 8b`) or zstd (`28 b5 2f fd`) by the magic bytes, anything else is `EILSEQ` (25); truncated input `EIO` (the destination left as it was). Writes `dst + ".partial"` and renames it to `dst`; on failure, removes it. The message: `errmsg(-1)`. |
// | `host_platform` | `(out_off, cap) -> i32` | Synchronous. Writes the record `u32 n, (str key, str value)*n` of the host machine's tags, with the names of `Base.BinaryPlatforms`: `arch` (`x86_64`, `aarch64`, `i686`, `armv7l`, `powerpc64le`, `riscv64`), `os` (`linux`, `macos`, `windows`, `freebsd`), `libc` (`glibc` or `musl`, on Linux), and any other the host is configured with (`libgfortran_version`, `cxxstring_abi`, ...: Node cannot detect them). The detected tags first; the configuration overrides them key by key. Never `julia_version` (the module adds its own). `cap` too small: `-ENOBUFS` with the length needed at `out_off`. An `arch` or `os` the host cannot tell: `-ENOTSUP`. |
// | `path_mode` | `(path_off, path_len, follow i32) -> i32` | The POSIX `st_mode` (type and permission bits) of the absolute path (of the link itself unless `follow`), or `-errno`. (WASI preview 1 has no permission bits.) |
// | `path_chmod` | `(path_off, path_len, mode i32) -> i32 status` | `chmod(2)` of the absolute path (following links). |
// | `path_symlink` | `(target_off, target_len, link_off, link_len) -> i32 status` | `symlink(2)`: a symbolic link at the absolute path `link` to `target`, which is any string (absolute, or out of the preopens), never resolved nor validated, as natively. (WASI's `path_symlink` refuses such targets.) |
//
// **Paths.** The path imports (`decompress`, `path_mode`, `path_chmod`, `path_symlink`'s
// `link`) check every path (`checkPath(path, {follow})`) against the preopens: absolute,
// without NUL; normalized lexically (`.` and `..`); within a preopen (on component
// boundaries); and the deepest existing ancestor (the path itself if `follow`), resolved
// (`realpath`), still within one. Otherwise `-ENOTCAPABLE` (76). This checks paths: it
// cannot exclude another process replacing a checked directory with a link before its use.
//
// **Readiness** is level-triggered, with retirement:
//
// | State | `http_head` | `read` | ready (`poll`) |
// |---|---|---|---|
// | pending | `-EAGAIN` | `-EAGAIN` | no |
// | head | the record | `-EAGAIN`, or bytes | until the head is taken and no bytes are buffered |
// | streaming | the record (again) | bytes, or `-EAGAIN` | while bytes are buffered |
// | end | the record | `0` (again) | until the first `0` is returned |
// | failed, cancelled | `-errno` | `-errno` | until the error is returned once |
// | closed | `-EBADF` | `-EBADF` | reported ready if in the interest set |
//
// A timer is ready from when it fires until it is closed. An error that arrives after body
// bytes takes effect once they are read. Callers close every handle (in `finally` blocks).

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import os from 'node:os';
import http from 'node:http';
import https from 'node:https';

export const JULIA_IO_VERSION = 1;
export const HIGH_WATER = 4 * 1024 * 1024;
export const MAX_REDIRECTS = 10;
// The largest body chunk the transport hands over (node:http delivers socket reads, <= 64 KiB).
// The reader pauses above HIGH_WATER - MAX_CHUNK, so at most HIGH_WATER bytes are queued.
export const MAX_CHUNK = 256 * 1024;

// WASI preview 1 errnos (wasi-libc's api.h)
export const E = Object.freeze({
  ACCES: 2, AGAIN: 6, BADF: 8, BUSY: 10, CANCELED: 11, CONNABORTED: 13, CONNREFUSED: 14,
  CONNRESET: 15, EXIST: 20, FBIG: 22, HOSTUNREACH: 23, ILSEQ: 25, INVAL: 28, IO: 29,
  ISDIR: 31, LOOP: 32, MFILE: 33, NAMETOOLONG: 37, NETDOWN: 38, NETUNREACH: 40, NOBUFS: 42,
  NOENT: 44, NOMEM: 48, NOSPC: 51, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58,
  PERM: 63, PROTO: 65, ROFS: 69, TIMEDOUT: 73, XDEV: 75, NOTCAPABLE: 76,
});

// Node's error codes -> WASI errnos
const CODE_TO_ERRNO = {
  ENOENT: E.NOENT, EEXIST: E.EXIST, EACCES: E.ACCES, EPERM: E.PERM, EROFS: E.ROFS,
  ENOTDIR: E.NOTDIR, EISDIR: E.ISDIR, ENOTEMPTY: E.NOTEMPTY, EXDEV: E.XDEV, EBUSY: E.BUSY,
  ENOSPC: E.NOSPC, EMFILE: E.MFILE, ENAMETOOLONG: E.NAMETOOLONG, EINVAL: E.INVAL, EIO: E.IO,
  EFBIG: E.FBIG, ELOOP: E.LOOP,
  ECONNREFUSED: E.CONNREFUSED, ECONNRESET: E.CONNRESET, ECONNABORTED: E.CONNABORTED,
  ENOTFOUND: E.HOSTUNREACH, EAI_AGAIN: E.HOSTUNREACH, EAI_NONAME: E.HOSTUNREACH,
  EHOSTUNREACH: E.HOSTUNREACH, ENETUNREACH: E.NETUNREACH, ENETDOWN: E.NETDOWN,
  ETIMEDOUT: E.TIMEDOUT, UND_ERR_CONNECT_TIMEOUT: E.TIMEDOUT, UND_ERR_HEADERS_TIMEOUT: E.TIMEDOUT,
  UND_ERR_BODY_TIMEOUT: E.TIMEDOUT, UND_ERR_SOCKET: E.CONNRESET, EPIPE: E.CONNRESET,
  ERR_BUFFER_TOO_LARGE: E.FBIG, ERR_OUT_OF_RANGE: E.FBIG,
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

// whether `b` is a sequence of complete zstd frames (RFC 8878 §3.1): each frame's header and
// blocks (up to the last one, and its checksum) or skippable frame fit exactly in `b`
function zstdComplete(b) {
  let p = 0;
  const u32 = (q) => (b[q] | (b[q + 1] << 8) | (b[q + 2] << 16) | (b[q + 3] << 24)) >>> 0;
  if (b.length === 0) return false;
  while (p < b.length) {
    if (p + 4 > b.length) return false;
    const magic = u32(p);
    if ((magic & 0xfffffff0) === 0x184d2a50) {   // a skippable frame
      if (p + 8 > b.length) return false;
      p += 8 + u32(p + 4);
      if (p > b.length) return false;
      continue;
    }
    if (magic !== 0xfd2fb528) return false;
    p += 4;
    if (p >= b.length) return false;
    const fhd = b[p++];
    const fcsFlag = fhd >> 6, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, didFlag = fhd & 3;
    if ((fhd >> 3) & 1) return false;            // the reserved bit
    p += (single ? 0 : 1) + [0, 1, 2, 4][didFlag] + [single ? 1 : 0, 2, 4, 8][fcsFlag];
    for (;;) {
      if (p + 3 > b.length) return false;
      const h = b[p] | (b[p + 1] << 8) | (b[p + 2] << 16);
      p += 3;
      const last = h & 1, type = (h >> 1) & 3, size = h >>> 3;
      if (type === 3) return false;
      p += type === 1 ? 1 : size;
      if (p > b.length) return false;
      if (last) break;
    }
    p += checksum ? 4 : 0;
    if (p > b.length) return false;
  }
  return true;
}

export function errnoOf(e) {
  if (e instanceof GuestError) return e.errno;
  if (e && e.name === 'AbortError') return E.CANCELED;
  const c = e && e.cause;
  for (const x of [c && c.code, e && e.code, c && c.cause && c.cause.code]) {
    if (x && CODE_TO_ERRNO[x] !== undefined) return CODE_TO_ERRNO[x];
  }
  return E.IO;
}

// ---- records ----
export function encodeRecord(fields) {
  // fields: [['u32', n] | ['str', s]]
  const parts = [];
  let n = 0;
  for (const [t, v] of fields) {
    if (t === 'u32') { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v >>> 0, true); parts.push(b); n += 4; }
    else { const s = utf8enc.encode(v); const b = new Uint8Array(4 + s.length); new DataView(b.buffer).setUint32(0, s.length, true); b.set(s, 4); parts.push(b); n += b.length; }
  }
  const out = new Uint8Array(n);
  let p = 0;
  for (const b of parts) { out.set(b, p); p += b.length; }
  return out;
}
export const encodeSpec = ({ method, url, headers = [], flags = 0 }) => encodeRecord([
  ['str', method], ['str', url], ['u32', headers.length],
  ...headers.flatMap(([k, v]) => [['str', k], ['str', v]]), ['u32', flags]]);
export const encodeHead = ({ status, url, headers = [] }) => encodeRecord([
  ['u32', status], ['str', url], ['u32', headers.length],
  ...headers.flatMap(([k, v]) => [['str', k], ['str', v]])]);

class Reader {
  constructor(b, what) { this.b = b; this.dv = new DataView(b.buffer, b.byteOffset, b.byteLength); this.p = 0; this.what = what; }
  u32() { if (this.p + 4 > this.b.length) throw new GuestError(E.INVAL, `${this.what}: truncated`); const v = this.dv.getUint32(this.p, true); this.p += 4; return v; }
  str() {
    const n = this.u32();
    if (this.p + n > this.b.length) throw new GuestError(E.INVAL, `${this.what}: truncated`);
    let s;
    try { s = utf8dec.decode(this.b.subarray(this.p, this.p + n)); } catch { throw new GuestError(E.ILSEQ, `${this.what}: invalid UTF-8`); }
    this.p += n; return s;
  }
  end() { if (this.p !== this.b.length) throw new GuestError(E.INVAL, `${this.what}: ${this.b.length - this.p} trailing bytes`); }
}
export function decodeSpec(b) {
  const r = new Reader(b, 'http spec');
  const method = r.str(), url = r.str(), n = r.u32();
  if (n > 1024) throw new GuestError(E.INVAL, 'http spec: too many headers');
  const headers = [];
  for (let i = 0; i < n; i++) headers.push([r.str(), r.str()]);
  const flags = r.u32();
  r.end();
  return { method, url, headers, flags };
}
export function decodeHead(b) {
  const r = new Reader(b, 'http head');
  const status = r.u32(), url = r.str(), n = r.u32(), headers = [];
  for (let i = 0; i < n; i++) headers.push([r.str(), r.str()]);
  r.end();
  return { status, url, headers };
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

// ---- the host's platform ----
// process.arch / process.platform -> the names of Base.BinaryPlatforms
const ARCH = { x64: 'x86_64', arm64: 'aarch64', ia32: 'i686', arm: 'armv7l', riscv64: 'riscv64' };
const OS = { linux: 'linux', darwin: 'macos', win32: 'windows', freebsd: 'freebsd' };

// The detected tags of the host: arch, os and (Linux) libc; a value Node cannot map is absent.
// (`opts` stand in for the process, in tests; an explicit `glibc: undefined` is a musl host)
export function detectPlatform(opts = {}) {
  const arch = opts.arch ?? process.arch, platform = opts.platform ?? process.platform;
  const endianness = opts.endianness ?? os.endianness();
  const glibc = 'glibc' in opts ? opts.glibc : process.report.getReport().header.glibcVersionRuntime;
  const tags = [];
  const a = arch === 'ppc64' ? (endianness === 'LE' ? 'powerpc64le' : undefined) : ARCH[arch];
  if (a) tags.push(['arch', a]);
  const o = OS[platform];
  if (o) tags.push(['os', o]);
  if (o === 'linux') tags.push(['libc', glibc ? 'glibc' : 'musl']);
  return tags;
}

// The detected tags, then the configured ones key by key (a detected key keeps its position,
// a new key is appended). Keys are lower-cased, as Base.BinaryPlatforms stores them.
// `julia_version` is never given (the module adds its own), and is dropped before any check.
// Tags are checked as BinaryPlatforms checks them (`add_tag!`: none of `+- /<>:"'\|?*` in a
// lower-cased name or value; empty values allowed), and the keyword arguments of the
// `Platform` constructor, which are not tags, are refused.
const TAG_NONOS = `+- /<>:"'\\|?*`;
const NOT_TAGS = new Set(['validate_strict', 'compare_strategies']);
export function mergePlatform(detected, overrides = {}) {
  if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides))
    throw new Error('julia_io: platformTags must be an object of string tags');
  const tags = detected.filter(([k]) => k !== 'julia_version').map(([k, v]) => [k, v]);
  for (const [k0, v] of Object.entries(overrides)) {
    const k = k0.toLowerCase();
    if (k === 'julia_version') continue;
    if (typeof v !== 'string') throw new Error(`julia_io: platform tag ${JSON.stringify(k0)} must be a string, not ${typeof v}`);
    if (k === '' || NOT_TAGS.has(k)) throw new Error(`julia_io: ${JSON.stringify(k0)} is not a platform tag name`);
    for (const [what, x] of [['name', k], ['value', v.toLowerCase()]])
      if ([...TAG_NONOS].some((c) => x.includes(c)))
        throw new Error(`julia_io: invalid character in platform tag ${what} ${JSON.stringify(what === 'name' ? k0 : v)} (BinaryPlatforms refuses any of ${TAG_NONOS})`);
    const i = tags.findIndex(([q]) => q === k);
    if (i >= 0) tags[i][1] = v; else tags.push([k, v]);
  }
  return tags;
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
// The events: timers, HTTP, `poll` (suspending), `errmsg`, `cancel`, `close`, `decompress`,
// `host_platform`. Options: `preopens` (WASI's, for `decompress`), `network` (false: every
// request is ENOTCAPABLE), `platformTags` (`host_platform`'s configuration), `memory`;
// for tests, `request` (in place of node:http(s)'s `request`), `highWater` (lower),
// `maxDecompressed`, `detectedPlatform`.
export function makeJuliaIOEvents(opts = {}) {
  if (typeof WebAssembly.Suspending !== 'function')
    throw new Error('julia_io: the events need JavaScript Promise Integration (WebAssembly.Suspending; Node: --experimental-wasm-jspi)');
  const network = opts.network !== false;
  const requestImpl = opts.request || ((u, o) => (u.protocol === 'https:' ? https : http).request(u, o));
  const highWater = opts.highWater === undefined ? HIGH_WATER : opts.highWater;
  if (!Number.isInteger(highWater) || highWater < 2 * MAX_CHUNK || highWater > HIGH_WATER)
    throw new Error(`julia_io: highWater must be an integer in [${2 * MAX_CHUNK}, ${HIGH_WATER}], not ${opts.highWater}`);
  const maxDecompressed = opts.maxDecompressed || 1024 * 1024 * 1024;
  const checkPath = makeCheckPath(opts.preopens || []);
  const platform = mergePlatform(opts.detectedPlatform || detectPlatform(), opts.platformTags || {});
  const { mem, view, checkRange, readBytes, readPath, bindMemory } = makeMemory(opts.memory);

  const handles = new Map(); // id -> entry (open handles only)
  let nextHandle = 1; // (ids are never reused)
  let lastError = ''; // errmsg(-1)
  let inPoll = false;
  let waker = null; // resolves the suspended poll
  const stats = { maxQueued: 0, maxOpen: 0, started: 0 };

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
  const negH64 = (e, h) => BigInt(-fault(e, h));

  // ---- HTTP ----
  // (an error that arrives after body bytes takes effect once they are read)
  const failed = (x) => x.error && x.queued === 0;
  function isReady(x) {
    if (x.kind === 'timer') return x.fired;
    if (failed(x)) return !x.errorDelivered;
    if (x.head && !x.headTaken) return true;
    if (x.queued > 0) return true;
    return x.eof && !x.eofDelivered;
  }
  // may become ready without the module doing anything (a paused body has bytes queued: it
  // is ready)
  function isPending(x) {
    if (x.kind === 'timer') return !x.fired;
    return !x.error && !x.eof && (!x.head || !x.paused);
  }

  function httpFail(x, e) {
    if (x.error || x.closed) return;
    x.error = { errno: errnoOf(e), msg: describe(e) };
    x.errmsg = x.error.msg;
    stop(x);
    notify();
  }
  // release the transport (request, response, socket) of a handle
  function stop(x) {
    try { x.abort.abort(); } catch {}
    try { if (x.res) x.res.destroy(); } catch {}
    try { if (x.req) x.req.destroy(); } catch {}
  }
  // `f` as an event handler of the handle `x`: an exception fails the handle (EIO) instead of
  // escaping to the event loop
  const guarded = (x, f) => (...a) => { try { f(...a); } catch (e) { httpFail(x, e); } };

  // The transport is node:http(s), not fetch: like libcurl (Julia's Downloads), it returns the
  // body bytes as sent (no Content-Encoding decoding) and the header names as sent.
  // Redirects are followed here, hop by hop.
  function hop(x, url, method, headers) {
    return new Promise((resolve, reject) => {
      const u = new URL(url);
      // (a raw header list is sent as it is: Node adds no Host header to it)
      const all = headers.some(([k]) => k.toLowerCase() === 'host') ? headers : [['Host', u.host], ...headers];
      const flat = all.flatMap(([k, v]) => [k, v]);
      const req = requestImpl(u, { method, headers: flat, signal: x.abort.signal, agent: false });
      x.req = req;
      req.on('response', resolve);
      req.on('error', reject);
      // a protocol upgrade (HTTP 101) is not supported: fail, release the socket
      req.on('upgrade', (res, socket) => {
        try { socket.destroy(); } catch {}
        reject(new GuestError(E.PROTO, `unsupported protocol upgrade (HTTP ${res.statusCode}${res.headers.upgrade ? ' to ' + res.headers.upgrade : ''}): ${url}`));
      });
      // closed without a response (after a response, the promise is settled: no effect)
      req.on('close', () => reject(new GuestError(E.CONNRESET, `connection closed before a response: ${url}`)));
      req.end();
    });
  }
  // URL userinfo to bytes as libcurl's curl_easy_unescape: %XX is the byte, anything else
  // (a malformed escape too) its UTF-8 bytes; the bytes need not be UTF-8
  function unescapeBytes(str) {
    const out = [];
    for (let i = 0; i < str.length; i++) {
      if (str[i] === '%' && /^[0-9a-fA-F]{2}$/.test(str.slice(i + 1, i + 3))) { out.push(parseInt(str.slice(i + 1, i + 3), 16)); i += 2; }
      else for (const b of Buffer.from(str[i], 'utf8')) out.push(b);
    }
    return Buffer.from(out);
  }
  const SENSITIVE = new Set(['authorization', 'cookie', 'proxy-authorization']);
  const origin = (u) => { const v = new URL(u); return `${v.protocol}//${v.host}`; };

  async function runRequest(x, spec) {
    let url = spec.url;
    let method = spec.method;
    let headers = spec.headers;
    // credentials in the URL: Basic authorization, as libcurl, unless one is given; the URL
    // requested carries none. It is an Authorization header: dropped across origins, below.
    const u0 = new URL(url);
    if (u0.username || u0.password) {
      if (!headers.some(([k]) => k.toLowerCase() === 'authorization')) {
        const cred = Buffer.concat([unescapeBytes(u0.username), Buffer.from(':'), unescapeBytes(u0.password)]);
        headers = [...headers, ['Authorization', 'Basic ' + cred.toString('base64')]];
      }
      u0.username = ''; u0.password = '';
      url = u0.href;
    }
    const follow = (spec.flags & 1) !== 0;
    for (let n = 0; ; n++) {
      const res = await hop(x, url, method, headers);
      x.res = res;
      if (x.closed || x.error) { res.destroy(); return; }
      const loc = res.headers.location;
      if (follow && [301, 302, 303, 307, 308].includes(res.statusCode) && loc !== undefined) {
        res.destroy();
        if (n >= MAX_REDIRECTS) throw new GuestError(E.LOOP, `too many redirects (> ${MAX_REDIRECTS}) starting at ${spec.url}`);
        const next = new URL(loc, url);
        if (next.protocol !== 'http:' && next.protocol !== 'https:') throw new GuestError(E.NOTSUP, `redirect to unsupported URL scheme ${next.protocol}: ${next.href}`);
        // credentials do not follow a redirect to another origin (scheme, host or port), as libcurl
        if (origin(next.href) !== origin(url)) headers = headers.filter(([k]) => !SENSITIVE.has(k.toLowerCase()));
        url = next.href;
        if (res.statusCode === 303 && method !== 'HEAD') method = 'GET';
        continue;
      }
      const raw = res.rawHeaders, hs = [];
      for (let i = 0; i + 1 < raw.length; i += 2) hs.push([raw[i], raw[i + 1]]);
      x.head = { status: res.statusCode, url, headers: hs };
      res.on('error', guarded(x, (e) => httpFail(x, e)));
      res.on('aborted', guarded(x, () => httpFail(x, new GuestError(E.CONNRESET, `connection closed before the end of the body: ${url}`))));
      res.on('data', guarded(x, (chunk) => {
        if (x.closed || x.error) return;
        if (chunk.length > MAX_CHUNK) throw new GuestError(E.IO, `transport delivered a ${chunk.length}-byte chunk (> ${MAX_CHUNK})`);
        x.chunks.push(chunk);
        x.queued += chunk.length;
        if (x.queued > stats.maxQueued) stats.maxQueued = x.queued;
        if (x.queued > highWater - MAX_CHUNK) { res.pause(); x.paused = true; }
        notify();
      }));
      res.on('end', guarded(x, () => { if (!x.error) { x.eof = true; notify(); } }));
      notify();
      return;
    }
  }

  function http_start(spec_off, spec_len) {
    const spec = decodeSpec(readBytes(spec_off, spec_len, 4));
    if (spec.flags & ~1) throw new GuestError(E.INVAL, `http_start: unknown flags 0x${(spec.flags >>> 0).toString(16)}`);
    if (spec.method !== 'GET' && spec.method !== 'HEAD') throw new GuestError(E.NOTSUP, `http_start: method ${spec.method} not supported (GET, HEAD)`);
    let u;
    try { u = new URL(spec.url); } catch { throw new GuestError(E.INVAL, `http_start: invalid URL ${JSON.stringify(spec.url)}`); }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new GuestError(E.NOTSUP, `http_start: unsupported URL scheme ${u.protocol}`);
    if (!network) throw new GuestError(E.NOTCAPABLE, `http_start: network access is disabled (${spec.url})`);
    const x = {
      kind: 'http', url: spec.url, abort: new AbortController(), head: null, headTaken: false,
      chunks: [], queued: 0, eof: false, eofDelivered: false, error: null, errorDelivered: false,
      errmsg: '', req: null, res: null, paused: false, closed: false,
    };
    const h = newHandle(x);
    runRequest(x, spec).catch((e) => httpFail(x, e));
    return h;
  }

  function http_head(h, out_off, out_cap) {
    const x = get(h);
    if (!x || x.kind !== 'http') return -E.BADF;
    out_off >>>= 0; out_cap >>>= 0;
    if (out_cap < 4) throw new GuestError(E.INVAL, `http_head: cap ${out_cap} < 4`);
    checkRange(out_off, 4, 4);
    if (failed(x)) { x.errorDelivered = true; return -x.error.errno; }
    if (!x.head) return -E.AGAIN;
    const rec = encodeHead(x.head);
    if (rec.length > out_cap) {
      view().setUint32(out_off, rec.length, true);
      x.errmsg = `http_head: record needs ${rec.length} bytes, capacity ${out_cap}`;
      return -E.NOBUFS;
    }
    checkRange(out_off, rec.length);
    mem().set(rec, out_off);
    x.headTaken = true;
    return rec.length;
  }

  function read(h, off, len) {
    const x = get(h);
    if (!x || x.kind !== 'http') return BigInt(-E.BADF);
    [off, len] = checkRange(off, len);
    if (len === 0) throw new GuestError(E.INVAL, 'read: len must be positive (0 is reserved for the end of the body)');
    if (x.queued > 0) {
      const m = mem();
      let n = 0;
      while (n < len && x.chunks.length) {
        const c = x.chunks[0];
        const k = Math.min(c.length, len - n);
        m.set(c.subarray(0, k), off + n);
        n += k;
        // (a copy of the rest: no view keeps a larger buffer alive)
        if (k === c.length) x.chunks.shift(); else x.chunks[0] = Buffer.from(c.subarray(k));
      }
      x.queued -= n;
      if (x.paused && x.queued <= highWater - MAX_CHUNK && x.res && !x.error) { x.paused = false; x.res.resume(); }
      return BigInt(n);
    }
    if (x.error) { x.errorDelivered = true; return BigInt(-x.error.errno); }
    if (x.eof) { x.eofDelivered = true; return 0n; }
    return BigInt(-E.AGAIN);
  }

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
    if (x.kind === 'timer') {
      if (!x.fired) { clearTimeout(x.t); x.t = null; x.fired = true; x.cancelled = true; x.errmsg = 'timer cancelled'; notify(); }
      return 0;
    }
    if (!x.error && !x.eof) { // (a state that is not terminal)
      x.chunks = []; x.queued = 0;
      x.error = { errno: E.CANCELED, msg: `request cancelled: ${x.url}` };
      x.errmsg = x.error.msg;
      stop(x);
      notify();
    }
    return 0;
  }

  function close(h) {
    h |= 0;
    const x = handles.get(h);
    if (!x) return -E.BADF;
    if (x.kind === 'timer') { if (x.t) clearTimeout(x.t); }
    else {
      stop(x);
      x.chunks = []; x.queued = 0;
    }
    x.closed = true;
    handles.delete(h);
    notify();
    return 0;
  }

  // ---- decompress (synchronous) ----
  // zlib and zstd error codes -> WASI errnos; anything else is an unexpected failure (EIO)
  function codecErrno(e) {
    if (e.code === 'ERR_BUFFER_TOO_LARGE') return E.FBIG;
    if (e.code === 'Z_BUF_ERROR') return E.IO; // (truncated input)
    if (e.code === 'Z_MEM_ERROR' || e.code === 'ZSTD_error_memory_allocation') return E.NOMEM;
    if (e.code === 'Z_DATA_ERROR' || e.code === 'Z_NEED_DICT' || (typeof e.code === 'string' && e.code.startsWith('ZSTD_error_'))) return E.ILSEQ;
    return E.IO;
  }
  // a new regular file, never through an existing name (no symbolic or hard link is followed)
  function writeNew(file, data) {
    const C = fs.constants;
    const fd = fs.openSync(file, C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_NOFOLLOW, 0o666);
    try {
      for (let off = 0; off < data.length;) off += fs.writeSync(fd, data, off, data.length - off);
    } finally { fs.closeSync(fd); }
  }

  function decompress(src_off, src_len, dst_off, dst_len) {
    // the destination first: its stale partial file is removed whatever fails afterwards
    const dst = checkPath(readPath(dst_off, dst_len), { follow: false });
    const partial = checkPath(dst + '.partial', { follow: false });
    const srcPath = readPath(src_off, src_len);
    const what = `decompress ${srcPath}`;
    // a stale partial file (of an earlier failure; possibly a link): removed by name
    try { fs.rmSync(partial, { force: true }); }
    catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot remove stale ${partial}: ${describe(e)}`); }
    let created = false;
    try {
      const src = checkPath(srcPath, { follow: true });
      let data;
      try { data = fs.readFileSync(src); }
      catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot read: ${describe(e)}`); }
      let out;
      const zopts = { maxOutputLength: maxDecompressed };
      try {
        if (data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b) out = zlib.gunzipSync(data, zopts);
        else if (data.length >= 4 && data[0] === 0x28 && data[1] === 0xb5 && data[2] === 0x2f && data[3] === 0xfd) {
          if (typeof zlib.zstdDecompressSync !== 'function') throw new GuestError(E.NOTSUP, `${what}: zstd is not supported by this Node`);
          // (Node's zstd may return what it decoded of a truncated frame, without an error)
          if (!zstdComplete(data)) throw new GuestError(E.IO, `${what}: truncated or malformed zstd data`);
          out = zlib.zstdDecompressSync(data, zopts);
        } else throw new GuestError(E.ILSEQ, `${what}: unknown format (neither gzip nor zstd magic)`);
      } catch (e) {
        if (e instanceof GuestError) throw e;
        throw new GuestError(codecErrno(e), `${what}: ${describe(e)}`);
      }
      data = null;
      try {
        created = true;
        writeNew(partial, out);
        fs.renameSync(partial, dst);
        created = false;
      } catch (e) { throw new GuestError(errnoOf(e), `${what}: cannot write ${dst}: ${describe(e)}`); }
    } catch (e) {
      if (created) {
        try { fs.rmSync(partial, { force: true }); }
        catch (r) { throw new GuestError(errnoOf(e), `${describe(e)}; additionally failed to remove ${partial}: ${describe(r)}`); }
      }
      throw e;
    }
    return 0;
  }

  // ---- host_platform (synchronous) ----
  function host_platform(out_off, cap) {
    out_off >>>= 0; cap >>>= 0;
    if (cap < 4) throw new GuestError(E.INVAL, `host_platform: cap ${cap} < 4`);
    checkRange(out_off, 4, 4);
    for (const k of ['arch', 'os'])
      if (!platform.some(([q]) => q === k)) throw new GuestError(E.NOTSUP, `host_platform: this host's ${k} is not one Julia knows (${k === 'arch' ? process.arch : process.platform}); configure it`);
    const rec = encodeRecord([['u32', platform.length], ...platform.flatMap(([k, v]) => [['str', k], ['str', v]])]);
    if (rec.length > cap) { view().setUint32(out_off, rec.length, true); lastError = `host_platform: record needs ${rec.length} bytes, capacity ${cap}`; return -E.NOBUFS; }
    checkRange(out_off, rec.length);
    mem().set(rec, out_off);
    return rec.length;
  }

  const imports = {
    http_start: wrap('http_start', http_start, neg),
    http_head: wrap('http_head', http_head, negH),
    read: wrap('read', read, negH64),
    timer_start: wrap('timer_start', timer_start, neg),
    poll: new WebAssembly.Suspending(poll),
    errmsg: wrap('errmsg', errmsg, neg),
    cancel: wrap('cancel', cancel, negH),
    close: wrap('close', close, negH),
    decompress: wrap('decompress', decompress, (e) => fault(e)),
    host_platform: wrap('host_platform', host_platform, neg),
  };

  return {
    imports,
    checkPath,
    platform: () => platform.map(([k, v]) => [k, v]),
    bindMemory,
    // introspection, for tests and diagnostics
    stats() {
      let queued = 0;
      for (const x of handles.values()) if (x.kind === 'http') queued += x.queued;
      return { open: handles.size, queued, ...stats };
    },
    handleState(h) {
      const x = get(h);
      if (!x) return null;
      return x.kind === 'timer' ? { kind: 'timer', fired: x.fired, cancelled: x.cancelled, ready: isReady(x) }
        : { kind: 'http', head: !!x.head, queued: x.queued, eof: x.eof, error: x.error, paused: x.paused, ready: isReady(x) };
    },
  };
}

// The names of the imports of each factory.
export const PATH_IMPORTS = Object.freeze(['path_mode', 'path_chmod', 'path_symlink']);
export const EVENT_IMPORTS = Object.freeze(['http_start', 'http_head', 'read', 'timer_start', 'poll', 'errmsg',
                                            'cancel', 'close', 'decompress', 'host_platform']);

// Check the version of the interface a module was built for: the export `name` (a function
// of no arguments, `Config(abi_version = name => version)`) must return `version`; throws
// with a message otherwise.
export function checkAbiVersion(instance, name, version) {
  const v = instance.exports[name];
  if (typeof v !== 'function') throw new Error(`julia_io: the module exports no ${name}`);
  const got = v();
  if (got !== version) throw new Error(`julia_io: the module's ${name} is ${got}, not ${version}`);
}
