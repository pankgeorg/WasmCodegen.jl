// The JavaScript host of modules compiled by WasmCodegen (src/host.jl). A module compiled
// with `Config(host = :js)` (the default) imports the functions of the module "julia"; one
// compiled with `host = :wasi` imports WASI preview 1 ("wasi_snapshot_preview1"), which
// WASI runtimes (wasmtime, wasmer, Node's node:wasi) provide, and which this file provides
// too, for hosts without it (browsers, Cloudflare Workers): the arguments, the environment,
// the clocks, randomness and the standard streams. It has no filesystem: no directory is
// preopened, stdin is empty, and the other descriptors are errnos (`EBADF`).
//
//   import { instantiate } from './julia.mjs';
//   const { instance } = await instantiate(bytes);   // the module's output to the console
//   instance.exports.f(1.0);
//
// `instantiate` takes the module's bytes, a `Response`, or a compiled `WebAssembly.Module`
// (hosts that compile only ahead of time, as Workers do, import the module compiled).
//
// Options: `write(fd, bytes)` receives the module's output (fd 1: stdout, 2: stderr), a
// Uint8Array of UTF-8; by default it is written to the console line by line. `args` (an
// array of strings) and `env` (an object of strings) are WASI's arguments and environment.

const WASI_EBADF = 8, WASI_EINVAL = 28, WASI_ENOSYS = 52, WASI_ENOTDIR = 54, WASI_ENOTSUP = 58,
  WASI_ESPIPE = 70;
const FILETYPE_CHARACTER_DEVICE = 2;
const RIGHT_FD_READ = 1n << 1n, RIGHT_FD_WRITE = 1n << 6n, RIGHT_POLL_FD_READWRITE = 1n << 27n;

// The WASI preview 1 functions, all provided: those of no use without a filesystem or
// sockets are errnos
const WASI_FUNCTIONS = [
  'args_get', 'args_sizes_get', 'environ_get', 'environ_sizes_get', 'clock_res_get', 'clock_time_get',
  'fd_advise', 'fd_allocate', 'fd_close', 'fd_datasync', 'fd_fdstat_get', 'fd_fdstat_set_flags',
  'fd_fdstat_set_rights', 'fd_filestat_get', 'fd_filestat_set_size', 'fd_filestat_set_times', 'fd_pread',
  'fd_prestat_get', 'fd_prestat_dir_name', 'fd_pwrite', 'fd_read', 'fd_readdir', 'fd_renumber', 'fd_seek',
  'fd_sync', 'fd_tell', 'fd_write', 'path_create_directory', 'path_filestat_get', 'path_filestat_set_times',
  'path_link', 'path_open', 'path_readlink', 'path_remove_directory', 'path_rename', 'path_symlink',
  'path_unlink_file', 'poll_oneoff', 'proc_exit', 'proc_raise', 'sched_yield', 'random_get', 'sock_accept',
  'sock_recv', 'sock_send', 'sock_shutdown',
];

/** `proc_exit(code)` of a WASI module: thrown out of the call that exits. */
export class WasiExit extends Error {
  constructor(code) {
    super(`exit with code ${code >>> 0}`);
    this.code = code >>> 0;
  }
}

// writes to the console, a line at a time, in the order written: an unfinished line is
// written when the other stream is written to, and by `flush()`
function consoleWriter() {
  const decoder = new TextDecoder();
  let fd = 1, buf = [];
  const emit = () => {
    (fd === 2 ? console.error : console.log)(decoder.decode(new Uint8Array(buf)));
    buf = [];
  };
  const write = (to, bytes) => {
    if (to !== fd) { if (buf.length) emit(); fd = to; }
    for (const b of bytes) {
      if (b === 10) emit();
      else buf.push(b);
    }
  };
  write.flush = () => { if (buf.length) emit(); };
  return write;
}

// the host clocks, in nanoseconds: monotonic, and since the Unix epoch
const monotonicNs = () => BigInt(Math.round(performance.now() * 1e6));
const realtimeNs = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

function fillRandom(bytes) {
  // getRandomValues fills at most 65536 bytes at a time
  for (let i = 0; i < bytes.length; i += 65536) crypto.getRandomValues(bytes.subarray(i, i + 65536));
}

// NUL-terminated UTF-8 strings, for args_get and environ_get
const cStrings = (strs) => strs.map((x) => new TextEncoder().encode(x + '\0'));

/**
 * The imports of a module (both interfaces), to instantiate it with:
 * `{ imports, attach(instance), flush() }`. For a WASI module (one exporting its memory),
 * `attach` gives the WASI functions the instance's memory and runs its initialization
 * (`_initialize`), as WASI hosts do; a JavaScript module initializes as it is instantiated.
 */
export function createHost({ write, args = [], env = {} } = {}) {
  const out = write ?? consoleWriter();
  const argv = cStrings(args.map(String));
  const environ = cStrings(Object.entries(env).map(([k, v]) => `${k}=${v}`));
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const julia = {
    write_byte: (fd, b) => out(fd, Uint8Array.of(b)),
    entropy: () => {
      const w = new BigUint64Array(1);
      crypto.getRandomValues(w);
      return BigInt.asIntN(64, w[0]);
    },
    hrtime: monotonicNs,
    // seconds since the Unix epoch, to the microsecond (as gettimeofday's)
    clock_now: () => {
      const t = realtimeNs();
      return Number(t / 1000000000n) + Number((t % 1000000000n) / 1000n) * 1e-6;
    },
  };
  const sizes = (strs, countPtr, sizePtr) => {
    const v = view();
    v.setUint32(countPtr, strs.length, true);
    v.setUint32(sizePtr, strs.reduce((n, x) => n + x.length, 0), true);
    return 0;
  };
  const strings = (strs, ptrs, buf) => {
    const v = view(), bytes = new Uint8Array(memory.buffer);
    strs.forEach((x, i) => {
      v.setUint32(ptrs + 4 * i, buf, true);
      bytes.set(x, buf);
      buf += x.length;
    });
    return 0;
  };
  const isStdio = (fd) => fd === 0 || fd === 1 || fd === 2;
  // a function of a descriptor: no other descriptor than the standard streams is open
  const onFd = (f = () => WASI_ENOTSUP) => (fd, ...a) => (isStdio(fd) ? f(fd, ...a) : WASI_EBADF);
  const clockNs = (id) => (id === 0 ? realtimeNs() : id === 1 ? monotonicNs() : null);
  const wasi = {
    args_sizes_get: (countPtr, sizePtr) => sizes(argv, countPtr, sizePtr),
    args_get: (ptrs, buf) => strings(argv, ptrs, buf),
    environ_sizes_get: (countPtr, sizePtr) => sizes(environ, countPtr, sizePtr),
    environ_get: (ptrs, buf) => strings(environ, ptrs, buf),
    fd_write: onFd((fd, iovs, iovsLen, nwrittenPtr) => {
      if (fd === 0) return WASI_EBADF;
      const v = view();
      let n = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
        out(fd, new Uint8Array(memory.buffer, ptr, len).slice());
        n += len;
      }
      v.setUint32(nwrittenPtr, n, true);
      return 0;
    }),
    // (stdin is empty: the end of the file)
    fd_read: onFd((fd, iovs, iovsLen, nreadPtr) => {
      if (fd !== 0) return WASI_EBADF;
      view().setUint32(nreadPtr, 0, true);
      return 0;
    }),
    fd_fdstat_get: onFd((fd, ptr) => {
      const v = view();
      new Uint8Array(memory.buffer, ptr, 24).fill(0);
      v.setUint8(ptr, FILETYPE_CHARACTER_DEVICE);
      v.setBigUint64(ptr + 8, (fd === 0 ? RIGHT_FD_READ : RIGHT_FD_WRITE) | RIGHT_POLL_FD_READWRITE, true);
      return 0;
    }),
    fd_filestat_get: onFd((fd, ptr) => {
      new Uint8Array(memory.buffer, ptr, 64).fill(0);
      view().setUint8(ptr + 16, FILETYPE_CHARACTER_DEVICE);
      view().setBigUint64(ptr + 24, 1n, true);
      return 0;
    }),
    fd_seek: onFd(() => WASI_ESPIPE),
    fd_tell: onFd(() => WASI_ESPIPE),
    fd_sync: onFd(() => 0),
    fd_datasync: onFd(() => 0),
    // (no directory is preopened: the descriptors after the standard streams are not open)
    fd_prestat_get: () => WASI_EBADF,
    fd_prestat_dir_name: () => WASI_EBADF,
    random_get(ptr, len) {
      fillRandom(new Uint8Array(memory.buffer, ptr, len));
      return 0;
    },
    clock_time_get(id, precision, ptr) {
      const t = clockNs(id);
      if (t === null) return WASI_EINVAL;
      view().setBigUint64(ptr, t, true);
      return 0;
    },
    // (a millisecond: hosts may coarsen `performance.now()` to it)
    clock_res_get(id, ptr) {
      if (clockNs(id) === null) return WASI_EINVAL;
      view().setBigUint64(ptr, 1000000n, true);
      return 0;
    },
    sched_yield: () => 0,
    proc_exit(code) { throw new WasiExit(code); },
    proc_raise: () => WASI_ENOSYS,
    poll_oneoff: () => WASI_ENOSYS,
    // (its directory's descriptor is its third argument)
    path_symlink: (oldPath, oldLen, fd) => (isStdio(fd) ? WASI_ENOTDIR : WASI_EBADF),
  };
  for (const name of WASI_FUNCTIONS) {
    if (name in wasi) continue;
    // a path is relative to a directory's descriptor: none is open
    wasi[name] = name.startsWith('path_') ? onFd(() => WASI_ENOTDIR) : onFd();
  }
  return {
    imports: { julia, wasi_snapshot_preview1: wasi },
    attach(instance) {
      if (!(instance.exports.memory instanceof WebAssembly.Memory)) return;
      memory = instance.exports.memory;
      instance.exports._initialize?.();
    },
    flush() { out.flush?.(); },
  };
}

/**
 * Instantiate a module with this host, compiling it first if it is bytes or a Response:
 * `{ module, instance, host }`. `options` are `createHost`'s.
 */
export async function instantiate(source, options = {}) {
  const module = source instanceof WebAssembly.Module ? source :
    typeof Response !== 'undefined' && source instanceof Response ? await WebAssembly.compileStreaming(source) :
    await WebAssembly.compile(source);
  const host = createHost(options);
  const instance = await WebAssembly.instantiate(module, host.imports);
  host.attach(instance);
  return { module, instance, host };
}
