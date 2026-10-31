// js/julia.mjs's WASI functions called directly, on a memory with sentinel bytes around each
// output: their records, errnos and strings. Prints the failed checks, one per line.
import { createHost, WasiExit } from '../js/julia.mjs';

const failures = [];
const check = (what, got, want) => {
  const g = JSON.stringify(got, (k, v) => (typeof v === 'bigint' ? `${v}n` : v)), w = JSON.stringify(want, (k, v) => (typeof v === 'bigint' ? `${v}n` : v));
  if (g !== w) failures.push(`${what}: ${g}, expected ${w}`);
};
const SENTINEL = 0xa5;
const memory = new WebAssembly.Memory({ initial: 1 });
const out = [];
const host = createHost({ args: ['prog', '', 'ünï'], env: { A: '1', EMPTY: '', U: 'λ=x' }, write: (fd, b) => out.push([fd, ...b]) });
host.attach({ exports: { memory } });
const w = host.imports.wasi_snapshot_preview1;
const bytes = () => new Uint8Array(memory.buffer);
const view = () => new DataView(memory.buffer);
const fresh = () => bytes().fill(SENTINEL);
const untouched = (what, from, to) => check(`${what}: bytes outside the output`, bytes().slice(from, to).every((x) => x === SENTINEL), true);

// args and the environment: counts, sizes, pointers, NUL-terminated UTF-8
for (const [what, sizes, get, want] of [['args', w.args_sizes_get, w.args_get, ['prog', '', 'ünï']],
                                        ['environ', w.environ_sizes_get, w.environ_get, ['A=1', 'EMPTY=', 'U=λ=x']]]) {
  fresh();
  check(`${what}_sizes_get`, sizes(0, 4), 0);
  const n = view().getUint32(0, true), size = view().getUint32(4, true);
  const enc = want.map((x) => new TextEncoder().encode(x + '\0'));
  check(`${what} count and size`, [n, size], [want.length, enc.reduce((a, x) => a + x.length, 0)]);
  check(`${what}_get`, get(100, 200), 0);
  const ptrs = [...Array(n)].map((_, i) => view().getUint32(100 + 4 * i, true));
  const strs = ptrs.map((p) => { let e = p; while (bytes()[e] !== 0) e++; return new TextDecoder().decode(bytes().slice(p, e)); });
  check(`${what} strings`, strs, want);
  untouched(what, 200 + size, 300 + size);
}

// the standard streams: a character device; stdin empty
fresh();
check('fd_fdstat_get(1)', w.fd_fdstat_get(1, 8), 0);
check('fdstat', [view().getUint8(8), view().getUint16(10, true), view().getBigUint64(16, true) & (1n << 6n), view().getBigUint64(24, true)], [2, 0, 1n << 6n, 0n]);
untouched('fdstat', 32, 64); untouched('fdstat', 0, 8);
fresh();
check('fd_filestat_get(2)', w.fd_filestat_get(2, 8), 0);
check('filestat', [view().getUint8(8 + 16), view().getBigUint64(8 + 24, true), view().getBigUint64(8 + 32, true)], [2, 1n, 0n]);
untouched('filestat', 72, 128); untouched('filestat', 0, 8);
fresh();
view().setUint32(0, 64, true); view().setUint32(4, 16, true);
check('fd_read(0)', [w.fd_read(0, 0, 1, 32), view().getUint32(32, true)], [0, 0]);
check('fd_read(1)', w.fd_read(1, 0, 1, 32), 8);
bytes().set([104, 105], 64);
view().setUint32(0, 64, true); view().setUint32(4, 2, true);
check('fd_write(2)', [w.fd_write(2, 0, 1, 32), view().getUint32(32, true), out.at(-1)], [0, 2, [2, 104, 105]]);
check('fd_write(0)', w.fd_write(0, 0, 1, 32), 8);
check('fd_seek(1)', w.fd_seek(1, 0n, 0, 32), 70);
check('fd_tell(0)', w.fd_tell(0, 32), 70);

// no other descriptor is open; no directory is preopened
check('fd_prestat_get(3)', w.fd_prestat_get(3, 0), 8);
check('fd_write(3)', w.fd_write(3, 0, 1, 32), 8);
check('fd_close(5)', w.fd_close(5), 8);
check('fd_close(1)', w.fd_close(1), 58);
check('path_open(3)', w.path_open(3, 0, 64, 2, 0, 0n, 0n, 0, 32), 8);
check('path_open(1)', w.path_open(1, 0, 64, 2, 0, 0n, 0n, 0, 32), 54);
check('path_symlink(.., fd 1, ..)', w.path_symlink(64, 2, 1, 64, 2), 54);
check('path_symlink(.., fd 9, ..)', w.path_symlink(1, 2, 9, 64, 2), 8);
check('poll_oneoff', w.poll_oneoff(0, 32, 1, 48), 52);
check('sock_recv(3)', w.sock_recv(3, 0, 1, 0, 32, 48), 8);

// the clocks; after the memory grows
memory.grow(1);
fresh();
check('clock_time_get(0)', w.clock_time_get(0, 1n, 65536 + 8), 0);
const t = Number(view().getBigUint64(65536 + 8, true)) / 1e9;
check('realtime', Math.abs(t - Date.now() / 1000) < 60, true);
check('clock_res_get(1)', [w.clock_res_get(1, 65536 + 8), view().getBigUint64(65536 + 8, true)], [0, 1000000n]);
check('clock_time_get(2)', w.clock_time_get(2, 1n, 8), 28);
check('clock_res_get(3)', w.clock_res_get(3, 8), 28);
check('sched_yield', w.sched_yield(), 0);

// proc_exit: thrown, its code unsigned
for (const [code, want] of [[3, 3], [-1, 4294967295]]) {
  try { w.proc_exit(code); failures.push(`proc_exit(${code}) returned`); }
  catch (e) { check(`proc_exit(${code})`, [e instanceof WasiExit, e.code], [true, want]); }
}
process.stdout.write(failures.map((f) => f + '\n').join(''));
