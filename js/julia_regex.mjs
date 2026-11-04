// The host's regex engine for WasmCodegen modules: the `julia_regex` imports (version 1).
//
// Julia's `Regex` is PCRE2 (10.47 in Julia 1.13). In Wasm, Base's `pcre2_*_8` foreign calls are
// implemented by WasmCodegen's runtime (`src/runtime/regex.jl`) on top of these imports, which
// run the pattern on V8's `RegExp` after translating it from PCRE2 syntax and semantics to an
// ECMAScript `v`-mode pattern. The translator is exact for what it accepts and rejects what it
// cannot translate with a compile error, never silently.
//
//   const rx = makeJuliaRegex();
//   const instance = await WebAssembly.instantiate(mod, { ...wasiImports, julia_regex: rx.imports });
//   rx.bindMemory(instance.exports.memory);
//
// Offsets in and out are UTF-8 byte offsets into the subject (Julia's), converted exactly from
// and to V8's UTF-16 indices. Invalid UTF-8 in a subject (Julia strings may hold it; Base sets
// PCRE2_MATCH_INVALID_UTF) decodes byte by byte to the lone surrogates U+DC80..U+DCFF, which no
// translated construct matches, as PCRE2 matches nothing at an invalid sequence. The module
// passes offsets of its memory only as arguments.
//
// The interface:
//
// **Conventions.** Handle/count returns are `i32`, `≥ 0` a value, `< 0` a negated WASI errno;
// status returns `0` or a positive errno. No import throws or rejects for expected failures
// (a bad pattern, an unsupported construct, no match, a bad offset). Unexpected exceptions become
// `-EIO` with the message kept for `errmsg`. Hosts copy every input out of linear memory before
// returning and recreate views per call. Records are packed: `u32` little-endian, `str` = a `u32` length then the bytes. Offsets into the subject are **UTF-8 byte offsets** (as PCRE2's code units).
//
// | Import | Signature | Semantics |
// |---|---|---|
// | `compile` | `(pat_off, pat_len, options u32, out_off, out_cap) -> i32 handle` | `pat` is the pattern's raw bytes (PCRE2 syntax, UTF-8 when `options` has `PCRE2_UTF`, else bytes). `options` are PCRE2 compile option bits as Base passes them. **Success:** a handle ≥ 0, and at `out` the record `u32 capture_count, u32 name_count, (u32 group, str name)*name_count`. **Pattern error** (a PCRE2 syntax error, or a construct the host cannot match with PCRE2's semantics): `-EINVAL`, and at `out` the record `u32 code, u32 offset, str message` (`code`: PCRE2's compile error number, or **900** for "valid PCRE2 the host does not support"; `offset`: byte offset in the pattern; `message`: PCRE2's text for PCRE2's errors). **Too small `out_cap`:** `-ENOBUFS` and the needed size as `u32` at `out` (if `out_cap ≥ 4`). `out_cap < 4`: `-EINVAL`. The same `(pattern, options)` may return the same handle again (handles are reference counted). |
// | `subject` | `(off, len, append i32) -> i32 status` | Stages the subject bytes for the next `match`: `append = 0` starts a new subject, `1` appends (for subjects larger than one staging chunk). The staged subject becomes current at the next `match` and stays current for later `match` calls until another `subject`. Never fails except `EIO`. |
// | `match` | `(h, start u32, options u32, out_off, out_cap) -> i32 rc` | Matches the current subject from byte offset `start` with PCRE2 match options `options` (as Base passes them: `NO_UTF_CHECK`, `ANCHORED`, `ENDANCHORED`, `NOTEMPTY_ATSTART`; also `NOTBOL`, `NOTEOL`, `NOTEMPTY`). **Match:** `rc ≥ 1` = 1 + the highest group set (PCRE2's rc), and at `out` `2·(capture_count+1)` `u32` byte offsets (start, end per group; `0xFFFFFFFF` = unset), always all of them. **No match:** `0`. `-EBADF`: unknown handle. `-EINVAL`: `start` beyond the subject. `-ENOBUFS`: `out_cap < 8·(capture_count+1)`. `-ENOTSUP` (58): match options the host does not support (`PARTIAL_*`, ...), message in `errmsg`. |
// | `free` | `(h) -> i32 status` | Drops one reference to the handle; `EBADF` if unknown. (Base frees patterns in finalizers, which do not run in the module.) |
// | `errmsg` | `(out_off, cap) -> i32 len` | The last error message (UTF-8, truncated to `cap`), and its length. |
//
// **Semantics contract.** The host matches **as PCRE2 10.47 with Unicode 16** would for every
// pattern it accepts: the same match, the same captures, the same offsets, for Base's default options
// (`UTF | UCP | MATCH_INVALID_UTF | ALT_BSUX`, match `NO_UTF_CHECK`) and the `a/i/m/s/x` flags. A
// pattern it cannot match that way it rejects (code 900, a message naming the construct); it never
// matches approximately. Known exceptions: (a) a
// start offset inside a UTF-8 character (undefined in PCRE2 with `NO_UTF_CHECK`; the host starts at
// the next character); (b) empty matches at positions inside a malformed UTF-8 sequence when matching
// starts inside or before it with a non-zero offset (PCRE2's `MATCH_INVALID_UTF` segment rules).
//
// **Lifetimes.** Handles live until `free` (in practice, the instance's life). The current subject is
// replaced by the next `subject`; the host may keep the decoded form of the last subject and reuse it
// when the same bytes are staged again.

import { UCD } from './julia_regex_ucd.mjs';

export const JULIA_REGEX_VERSION = 1;

// WASI errnos used here
export const E = Object.freeze({ BADF: 8, INVAL: 28, IO: 29, NOBUFS: 42, NOTSUP: 58 });

// PCRE2 option bits (pcre2.h, 10.47), as Base passes them
export const PCRE = Object.freeze({
  // compile options
  ALLOW_EMPTY_CLASS: 0x1, ALT_BSUX: 0x2, AUTO_CALLOUT: 0x4, CASELESS: 0x8, DOLLAR_ENDONLY: 0x10,
  DOTALL: 0x20, DUPNAMES: 0x40, EXTENDED: 0x80, FIRSTLINE: 0x100, MATCH_UNSET_BACKREF: 0x200,
  MULTILINE: 0x400, NEVER_UCP: 0x800, NEVER_UTF: 0x1000, NO_AUTO_CAPTURE: 0x2000,
  NO_AUTO_POSSESS: 0x4000, NO_DOTSTAR_ANCHOR: 0x8000, NO_START_OPTIMIZE: 0x10000, UCP: 0x20000,
  UNGREEDY: 0x40000, UTF: 0x80000, NEVER_BACKSLASH_C: 0x100000, ALT_CIRCUMFLEX: 0x200000,
  ALT_VERBNAMES: 0x400000, USE_OFFSET_LIMIT: 0x800000, EXTENDED_MORE: 0x1000000,
  LITERAL: 0x2000000, MATCH_INVALID_UTF: 0x4000000, ALT_EXTENDED_CLASS: 0x8000000,
  ENDANCHORED: 0x20000000, NO_UTF_CHECK: 0x40000000, ANCHORED: 0x80000000,
  // match options
  NOTBOL: 0x1, NOTEOL: 0x2, NOTEMPTY: 0x4, NOTEMPTY_ATSTART: 0x8, PARTIAL_SOFT: 0x10,
  PARTIAL_HARD: 0x20, COPY_MATCHED_SUBJECT: 0x4000, NO_JIT: 0x2000,
});

// Compile error codes: PCRE2's numbers where the error is PCRE2's, else ours.
export const ERR = Object.freeze({
  END_BACKSLASH: 101, END_BACKSLASH_C: 102, UNKNOWN_ESCAPE: 103, QUANTIFIER_OUT_OF_ORDER: 104, QUANTIFIER_TOO_BIG: 105,
  MISSING_SQUARE_BRACKET: 106, ESCAPE_INVALID_IN_CLASS: 107, CLASS_RANGE_ORDER: 108,
  QUANTIFIER_INVALID: 109, INVALID_AFTER_PARENS_QUERY: 111, POSIX_CLASS_NOT_IN_CLASS: 112,
  MISSING_CLOSING_PARENTHESIS: 114, BAD_SUBPATTERN_REFERENCE: 115, MISSING_COMMENT_CLOSING: 118,
  UNMATCHED_CLOSING_PARENTHESIS: 122, LOOKBEHIND_NOT_FIXED_LENGTH: 125,
  ZERO_RELATIVE_REFERENCE: 126, UNKNOWN_POSIX_CLASS: 130, CODE_POINT_TOO_BIG: 134,
  UNSUPPORTED_ESCAPE_SEQUENCE: 137, MISSING_NAME_TERMINATOR: 142,
  DUPLICATE_SUBPATTERN_NAME: 143, INVALID_SUBPATTERN_NAME: 144, MALFORMED_UNICODE_PROPERTY: 146,
  UNKNOWN_UNICODE_PROPERTY: 147, CLASS_INVALID_RANGE: 150, BACKSLASH_O_MISSING_BRACE: 155,
  BACKSLASH_G_SYNTAX: 157, SUBPATTERN_NAME_EXPECTED: 162, INVALID_HEXADECIMAL: 167,
  BACKSLASH_C_SYNTAX: 168, BACKSLASH_K_SYNTAX: 169, BACKSLASH_N_IN_CLASS: 171, UTF8_ERROR: 173,
  INVALID_HYPHEN_IN_OPTIONS: 194, LOOKBEHIND_BRANCH_TOO_LONG: 200, LOOKBEHIND_TOO_LONG: 187,
  POSIX_NO_SUPPORT_COLLATING: 113, PATTERN_TOO_LARGE: 120,
  // ours: valid PCRE2 that the translator does not handle (fails loudly)
  UNTRANSLATABLE: 900,
});

const MESSAGES = {
  [ERR.END_BACKSLASH]: '\\ at end of pattern',
  [ERR.END_BACKSLASH_C]: '\\c at end of pattern',
  [ERR.UNKNOWN_ESCAPE]: 'unrecognized character follows \\',
  [ERR.QUANTIFIER_OUT_OF_ORDER]: 'numbers out of order in {} quantifier',
  [ERR.QUANTIFIER_TOO_BIG]: 'number too big in {} quantifier',
  [ERR.MISSING_SQUARE_BRACKET]: 'missing terminating ] for character class',
  [ERR.ESCAPE_INVALID_IN_CLASS]: 'escape sequence is invalid in character class',
  [ERR.CLASS_RANGE_ORDER]: 'range out of order in character class',
  [ERR.QUANTIFIER_INVALID]: 'quantifier does not follow a repeatable item',
  [ERR.INVALID_AFTER_PARENS_QUERY]: 'unrecognized character after (? or (?-',
  [ERR.POSIX_CLASS_NOT_IN_CLASS]: 'POSIX named classes are supported only within a class',
  [ERR.MISSING_CLOSING_PARENTHESIS]: 'missing closing parenthesis',
  [ERR.BAD_SUBPATTERN_REFERENCE]: 'reference to non-existent subpattern',
  [ERR.MISSING_COMMENT_CLOSING]: 'missing ) after (?# comment',
  [ERR.UNMATCHED_CLOSING_PARENTHESIS]: 'unmatched closing parenthesis',
  [ERR.LOOKBEHIND_NOT_FIXED_LENGTH]: 'length of lookbehind assertion is not limited',
  [ERR.ZERO_RELATIVE_REFERENCE]: 'a relative value of zero is not allowed',
  [ERR.UNKNOWN_POSIX_CLASS]: 'unknown POSIX class name',
  [ERR.CODE_POINT_TOO_BIG]: 'character code point value in \\x{} or \\o{} is too large',
  [ERR.UNSUPPORTED_ESCAPE_SEQUENCE]: 'PCRE2 does not support \\F, \\L, \\l, \\N{name}, \\U, or \\u',
  [ERR.MISSING_NAME_TERMINATOR]: 'syntax error in subpattern name (missing terminator?)',
  [ERR.DUPLICATE_SUBPATTERN_NAME]: 'two named subpatterns have the same name (PCRE2_DUPNAMES not set)',
  [ERR.INVALID_SUBPATTERN_NAME]: 'subpattern name must start with a non-digit',
  [ERR.MALFORMED_UNICODE_PROPERTY]: 'malformed \\P or \\p sequence',
  [ERR.UNKNOWN_UNICODE_PROPERTY]: 'unknown property after \\P or \\p',
  [ERR.CLASS_INVALID_RANGE]: 'invalid range in character class',
  [ERR.BACKSLASH_O_MISSING_BRACE]: 'missing opening brace after \\o',
  [ERR.BACKSLASH_G_SYNTAX]: '\\g is not followed by a braced, angle-bracketed, or quoted name/number or by a plain number',
  [ERR.SUBPATTERN_NAME_EXPECTED]: 'subpattern name expected',
  [ERR.INVALID_HEXADECIMAL]: 'non-hex character in \\x{} (closing brace missing?)',
  [ERR.BACKSLASH_C_SYNTAX]: '\\c must be followed by a printable ASCII character',
  [ERR.BACKSLASH_K_SYNTAX]: '\\k is not followed by a braced, angle-bracketed, or quoted name',
  [ERR.BACKSLASH_N_IN_CLASS]: '\\N is not supported in a class',
  [ERR.UTF8_ERROR]: 'UTF-8 error in the pattern',
  [ERR.INVALID_HYPHEN_IN_OPTIONS]: 'invalid hyphen in option setting',
  [ERR.LOOKBEHIND_BRANCH_TOO_LONG]: 'branch too long in variable-length lookbehind assertion',
  [ERR.LOOKBEHIND_TOO_LONG]: 'lookbehind assertion is too long',
  [ERR.POSIX_NO_SUPPORT_COLLATING]: 'POSIX collating elements are not supported',
};

export class RegexCompileError extends Error {
  constructor(code, offset, message) {
    super(message ?? MESSAGES[code] ?? `error ${code}`);
    this.code = code;
    this.offset = offset;   // in code points of the pattern; converted to bytes by the caller
  }
}

const untranslatable = (what, at) =>
  new RegexCompileError(ERR.UNTRANSLATABLE, at,
    `${what} is not supported by the Wasm regex translator (PCRE2 -> ECMAScript)`);

const SUPPORTED_COMPILE = PCRE.ALT_BSUX | PCRE.CASELESS | PCRE.DOLLAR_ENDONLY | PCRE.DOTALL |
  PCRE.EXTENDED | PCRE.MATCH_UNSET_BACKREF | PCRE.MULTILINE | PCRE.NEVER_UCP | PCRE.NEVER_UTF |
  PCRE.NO_AUTO_CAPTURE | PCRE.NO_AUTO_POSSESS | PCRE.NO_DOTSTAR_ANCHOR | PCRE.NO_START_OPTIMIZE |
  PCRE.UCP | PCRE.UNGREEDY | PCRE.UTF | PCRE.NEVER_BACKSLASH_C | PCRE.ALT_CIRCUMFLEX |
  PCRE.ALT_VERBNAMES | PCRE.EXTENDED_MORE | PCRE.LITERAL | PCRE.MATCH_INVALID_UTF |
  PCRE.ENDANCHORED | PCRE.NO_UTF_CHECK | PCRE.ANCHORED;
// what PCRE2_LITERAL can be combined with
const LITERAL_OPTIONS = PCRE.ANCHORED | PCRE.AUTO_CALLOUT | PCRE.CASELESS | PCRE.ENDANCHORED | PCRE.FIRSTLINE |
  PCRE.LITERAL | PCRE.MATCH_INVALID_UTF | PCRE.NO_START_OPTIMIZE | PCRE.NO_UTF_CHECK | PCRE.UTF | PCRE.USE_OFFSET_LIMIT;
// (not PCRE2_NO_JIT: which engine runs decides details on invalid UTF-8, see `exec`)
const SUPPORTED_MATCH = PCRE.NOTBOL | PCRE.NOTEOL | PCRE.NOTEMPTY | PCRE.NOTEMPTY_ATSTART |
  PCRE.NO_UTF_CHECK | PCRE.ANCHORED | PCRE.ENDANCHORED;
// internal variant flags (bits no PCRE2 match option uses): a sticky match at the start; a
// match only just after a newline
const V_STICKY = 0x01000000, V_AFTER_NL = 0x02000000;

// ---------------------------------------------------------------------------------------------
// Character classes, as sets of code points (sorted, disjoint [lo, hi] ranges). Properties, the
// generic types (\d \w \s \h \v) and POSIX classes are PCRE2's own Unicode 16 sets
// (julia_regex_ucd.mjs, generated from native PCRE2), never V8's `\p{...}`, whose Unicode
// version differs (V8 13.6 has 17). Classes are emitted as explicit ranges.

const MAXCP = 0x10ffff;
const SURR = [[0xd800, 0xdfff]];

const parseSet = (enc) => (enc === '' ? [] : enc.split(' ').map((r) => {
  const [a, b] = r.split('-');
  return [parseInt(a, 16), parseInt(b ?? a, 16)];
}));
const setCache = new Map();
const ucd = (name) => {
  let r = setCache.get(name);
  if (r === undefined) {
    const enc = UCD[name];
    if (enc === undefined) throw new Error(`internal: no UCD set ${name}`);
    r = parseSet(enc);
    setCache.set(name, r);
  }
  return r;
};

function normalize(rs) {
  const a = rs.filter(([x, y]) => x <= y).sort((p, q) => p[0] - q[0]);
  const out = [];
  for (const [x, y] of a) {
    const l = out[out.length - 1];
    if (l && x <= l[1] + 1) l[1] = Math.max(l[1], y);
    else out.push([x, y]);
  }
  return out;
}
const union = (...sets) => normalize(sets.flat().map(([x, y]) => [x, y]));
// the complement among Unicode scalar values (no surrogates: nothing matches an invalid byte)
function complement(rs, top = MAXCP) {
  const out = [];
  let next = 0;
  for (const [x, y] of normalize(union(rs, SURR))) {
    if (x > next) out.push([next, x - 1]);
    next = y + 1;
  }
  if (next <= top) out.push([next, top]);
  return out;
}
const minus = (a, b) => complement(union(complement(a), b));
const inSet = (rs, c) => rs.some(([x, y]) => c >= x && c <= y);
const overlaps = (rs, lo, hi) => rs.some(([a, b]) => lo <= b && a <= hi);

const hex = (cp) => cp.toString(16);
// a code point as a `v`-mode class or pattern character
const vchar = (cp) => (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a)
  ? String.fromCodePoint(cp) : `\\u{${hex(cp)}}`;
const rangesBody = (rs) => rs.map(([a, b]) => (a === b ? vchar(a) : `${vchar(a)}-${vchar(b)}`)).join('');
const classSrc = (rs) => (rs.length ? `[${rangesBody(rs)}]` : '(?!)');

const R = (...pairs) => pairs.map((p) => (Array.isArray(p) ? p : [p, p]));
// PCRE2's default "C" tables (no UCP)
const ASCII = {
  d: R([0x30, 0x39]), w: R([0x30, 0x39], [0x41, 0x5a], 0x5f, [0x61, 0x7a]), s: R([0x09, 0x0d], 0x20),
  alnum: R([0x30, 0x39], [0x41, 0x5a], [0x61, 0x7a]), alpha: R([0x41, 0x5a], [0x61, 0x7a]), blank: R(0x09, 0x20),
  cntrl: R([0, 0x1f], 0x7f), digit: R([0x30, 0x39]), graph: R([0x21, 0x7e]), lower: R([0x61, 0x7a]),
  print: R([0x20, 0x7e]), punct: R([0x21, 0x2f], [0x3a, 0x40], [0x5b, 0x60], [0x7b, 0x7e]),
  space: R([0x09, 0x0d], 0x20), upper: R([0x41, 0x5a]), word: R([0x30, 0x39], [0x41, 0x5a], 0x5f, [0x61, 0x7a]),
  xdigit: R([0x30, 0x39], [0x41, 0x46], [0x61, 0x66]),
};
// \h and \v in byte mode (in UTF mode they are Unicode with or without UCP)
const BYTE_HV = { h: R(0x09, 0x20, 0xa0), v: R([0x0a, 0x0d], 0x85) };

// general category groups
const GC_GROUPS = {
  c: ['Cc', 'Cf', 'Cn', 'Co'], l: ['Ll', 'Lm', 'Lo', 'Lt', 'Lu'], m: ['Mc', 'Me', 'Mn'], n: ['Nd', 'Nl', 'No'],
  p: ['Pc', 'Pd', 'Pe', 'Pf', 'Pi', 'Po', 'Ps'], s: ['Sc', 'Sk', 'Sm', 'So'], z: ['Zl', 'Zp', 'Zs'],
};
const GC_NAMES = new Map(Object.keys(UCD).filter((k) => k.startsWith('gc:')).map((k) => [k.slice(3).toLowerCase(), k.slice(3)]));
const SCRIPT_KEYS = new Map(Object.keys(UCD).filter((k) => k.startsWith('sc:')).map((k) => [k.slice(3).toLowerCase().replace(/_/g, ''), k.slice(3)]));

// Unicode 17 (V8) vs 16 (PCRE2) in case folding: code points new in 17, and old letters whose
// case partner is new. A caseless literal that reaches them is restricted to what PCRE2 folds.
// The new code points are exactly PCRE2's unassigned ones that V8 assigns: computed at load.
let U17_NEW = null;
const u17New = () => (U17_NEW ??= ucd('gc:Cn').flatMap(([a, b]) => {
  // the code points of PCRE2's Cn range [a, b] that V8 has assigned: a scan per chunk
  const hits = [];
  for (let lo = a; lo <= b; lo += 0x4000) {
    const hi = Math.min(b, lo + 0x3fff);
    const cps = [];
    for (let c = lo; c <= hi; c++) cps.push(c);
    for (const m of String.fromCodePoint(...cps).matchAll(/\P{Cn}/gv)) hits.push(m[0].codePointAt(0));
  }
  return normalize(hits.map((c) => [c, c]));
}));
const U17_PARTNERS = R(0xa7d3, 0xa7d5);
// (the code points new in Unicode 17 are all above U+088E; computing them takes ~0.1 s, so only
// ranges that reach that far do)
const U17_LOWEST = 0x88f;
const touchesU17 = (lo, hi) => overlaps(U17_PARTNERS, lo, hi) || (hi >= U17_LOWEST && overlaps(u17New(), lo, hi));

// ---------------------------------------------------------------------------------------------
// Parser: PCRE2 pattern (code points) -> AST

// atoms PCRE2 doesn't let a quantifier follow
const NOT_REPEATABLE = new Set(['bol', 'eol', 'A', 'z', 'Z', 'wordb']);

class Parser {
  constructor(cps, options) {
    this.cps = cps;
    this.pos = 0;
    this.utf = (options & PCRE.UTF) !== 0;
    this.ucp = (options & PCRE.UCP) !== 0;
    this.bsux = (options & PCRE.ALT_BSUX) !== 0;
    this.ncap = 0;
    this.names = new Map();          // name -> group number
    this.backrefs = [];              // nodes to check after parsing
    this.opts = {
      i: (options & PCRE.CASELESS) !== 0, m: (options & PCRE.MULTILINE) !== 0,
      s: (options & PCRE.DOTALL) !== 0, x: (options & (PCRE.EXTENDED | PCRE.EXTENDED_MORE)) !== 0,
      xx: (options & PCRE.EXTENDED_MORE) !== 0, n: (options & PCRE.NO_AUTO_CAPTURE) !== 0,
      U: (options & PCRE.UNGREEDY) !== 0,
    };
    this.dollarEndOnly = (options & PCRE.DOLLAR_ENDONLY) !== 0;
    this.altCircumflex = (options & PCRE.ALT_CIRCUMFLEX) !== 0;
  }
  peek(k = 0) { return this.cps[this.pos + k]; }
  eof() { return this.pos >= this.cps.length; }
  isChar(c, k = 0) { return this.cps[this.pos + k] === c.codePointAt(0); }
  err(code, at = this.pos) { return new RegexCompileError(code, at); }

  // whitespace and comments in extended mode
  skipExtended() {
    if (!this.opts.x) return;
    for (;;) {
      const c = this.peek();
      if (c === undefined) return;
      if (isPatternSpace(c, this.utf)) { this.pos++; continue; }
      if (c === 0x23) {             // '#': to the end of the line
        while (!this.eof() && this.peek() !== 0x0a) this.pos++;
        continue;
      }
      return;
    }
  }

  parse() {
    this.parseVerbs();
    const ast = this.parseAlt();
    if (!this.eof()) throw this.err(ERR.UNMATCHED_CLOSING_PARENTHESIS, this.pos + 1);
    for (const b of this.backrefs) {
      if (b.name !== undefined) {
        const n = this.names.get(b.name);
        if (n === undefined) throw this.err(ERR.BAD_SUBPATTERN_REFERENCE, b.refAt ?? b.at);
        b.group = n;
      }
      if (b.group > this.ncap || b.group < 1) throw this.err(ERR.BAD_SUBPATTERN_REFERENCE, b.refAt ?? b.at);
    }
    return ast;
  }

  // leading (*VERB)s: only the ones that change nothing here
  parseVerbs() {
    while (this.isChar('(') && this.isChar('*', 1)) {
      const at = this.pos;
      let j = this.pos + 2, name = '';
      while (j < this.cps.length && this.cps[j] !== 0x29) name += String.fromCodePoint(this.cps[j++]);
      if (j >= this.cps.length) throw new RegexCompileError(160, j, '(*VERB) not recognized or malformed');
      if ((name === 'UTF' && this.utf) || (name === 'UCP' && this.ucp)) { this.pos = j + 1; continue; }
      throw untranslatable(`the start-of-pattern option (*${name})`, at);
    }
  }

  // options set by (?i) etc. carry into later alternatives and end with the group
  parseAlt() {
    const saved = { ...this.opts };
    const alts = [this.parseSeq()];
    while (this.isChar('|')) { this.pos++; alts.push(this.parseSeq()); }
    this.opts = saved;
    return alts.length === 1 ? alts[0] : { t: 'alt', alts };
  }

  // what PCRE2 ignores between items, also between an item and its quantifier: extended-mode
  // white space and comments, (?#...) comments, an empty \Q\E, a lone \E
  skipIgnorable() {
    for (;;) {
      this.skipExtended();
      if (this.isChar('(') && this.isChar('?', 1) && this.isChar('#', 2)) {
        const at = this.pos;
        this.pos += 3;
        while (!this.eof() && !this.isChar(')')) this.pos++;
        if (this.eof()) throw this.err(ERR.MISSING_COMMENT_CLOSING, at);
        this.pos++;
      } else if (this.isChar('\\') && this.isChar('Q', 1) && this.isChar('\\', 2) && this.isChar('E', 3)) {
        this.pos += 4;
      } else if (this.isChar('\\') && this.isChar('E', 1)) {
        this.pos += 2;
      } else {
        return;
      }
    }
  }

  parseSeq() {
    const items = [];
    for (;;) {
      this.skipIgnorable();
      if (this.eof() || this.isChar('|') || this.isChar(')')) break;
      const at = this.pos;
      let atom = this.parseAtom(items);
      if (atom === null) continue;      // an option setting
      atom.at = at;
      atom = this.parseQuantifiers(atom);
      items.push(atom);
    }
    return { t: 'seq', items };
  }

  // at most one quantifier, and its lazy/possessive suffix (ignorable items may come between)
  parseQuantifiers(atom) {
    this.skipIgnorable();
    const at = this.pos;
    const q = this.parseQuantifier();
    if (q === null) return atom;
    if (NOT_REPEATABLE.has(atom.t)) throw this.err(ERR.QUANTIFIER_INVALID, this.pos);
    let greedy = true, possessive = false;
    this.skipIgnorable();
    if (this.isChar('+')) { possessive = true; this.pos++; }
    else if (this.isChar('?')) { greedy = false; this.pos++; }
    if (this.opts.U && !possessive) greedy = !greedy;
    atom = { t: 'quant', body: atom, min: q.min, max: q.max, greedy, possessive, at };
    this.skipIgnorable();
    if (this.parseQuantifier() !== null) throw this.err(ERR.QUANTIFIER_INVALID, this.pos);
    return atom;
  }

  parseQuantifier() {
    const c = this.peek();
    if (c === 0x2a) { this.pos++; return { min: 0, max: Infinity }; }
    if (c === 0x2b) { this.pos++; return { min: 1, max: Infinity }; }
    if (c === 0x3f) { this.pos++; return { min: 0, max: 1 }; }
    if (c !== 0x7b) return null;
    // {n} {n,} {n,m} {,m}, spaces and tabs allowed around the numbers (PCRE2 10.43+);
    // anything else is a literal '{'
    let j = this.pos + 1;
    const sp = () => { while (this.cps[j] === 0x20 || this.cps[j] === 0x09) j++; };
    const num = () => {
      let s = '';
      while (this.cps[j] >= 0x30 && this.cps[j] <= 0x39) s += String.fromCodePoint(this.cps[j++]);
      return s;
    };
    sp(); const a = num(); sp();
    let b, comma = false;
    if (this.cps[j] === 0x2c) { comma = true; j++; sp(); b = num(); sp(); }
    if (this.cps[j] !== 0x7d || (a === '' && (!comma || b === ''))) return null;
    const at = this.pos;
    this.pos = j + 1;
    const min = a === '' ? 0 : Number(a);
    const max = comma ? (b === '' ? Infinity : Number(b)) : min;
    if (min > 65535 || (max !== Infinity && max > 65535)) throw this.err(ERR.QUANTIFIER_TOO_BIG, j);
    if (max < min) throw this.err(ERR.QUANTIFIER_OUT_OF_ORDER, j);
    return { min, max };
  }

  lit(cp) { return { t: 'char', cp, i: this.opts.i }; }

  parseAtom(items) {
    const at = this.pos;
    const c = this.cps[this.pos++];
    switch (c) {
      case 0x28: return this.parseGroup(at);                       // (
      case 0x5b: return this.parseClass(at);                       // [
      case 0x2e: return { t: 'dot', s: this.opts.s };              // .
      case 0x5e: return { t: 'bol', m: this.opts.m };              // ^
      case 0x24: return { t: 'eol', m: this.opts.m };              // $
      case 0x5c: return this.parseEscape(at, items);               // \
      case 0x2a: case 0x2b: case 0x3f:
        throw this.err(ERR.QUANTIFIER_INVALID, this.pos);
      case 0x7b:
        this.pos = at;
        if (this.parseQuantifier() !== null) throw this.err(ERR.QUANTIFIER_INVALID, this.pos);
        this.pos = at + 1;
        return this.lit(c);
      default: return this.lit(c);
    }
  }

  parseName(term) {
    const at = this.pos;
    let name = '';
    while (!this.eof() && this.peek() !== term.codePointAt(0)) {
      const c = this.cps[this.pos++];
      const ok = c === 0x5f || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) ||
        (this.utf && c > 0x7f && /[\p{L}\p{N}]/u.test(String.fromCodePoint(c)));
      if (!ok) throw this.err(ERR.MISSING_NAME_TERMINATOR, this.pos - 1);
      name += String.fromCodePoint(c);
    }
    if (this.eof()) throw this.err(ERR.MISSING_NAME_TERMINATOR, this.pos);
    if (name === '') throw this.err(ERR.SUBPATTERN_NAME_EXPECTED, at);
    if (/^[0-9]/.test(name)) throw this.err(ERR.INVALID_SUBPATTERN_NAME, at);
    this.pos++;   // the terminator
    return name;
  }

  capture(at, name) {
    const group = ++this.ncap;
    if (name !== undefined) {
      if (this.names.has(name)) throw this.err(ERR.DUPLICATE_SUBPATTERN_NAME, this.pos);
      this.names.set(name, group);
    }
    const body = this.parseAlt();
    this.close(at);
    return { t: 'group', kind: 'cap', group, name, body };
  }

  close(at) {
    if (!this.isChar(')')) throw this.err(ERR.MISSING_CLOSING_PARENTHESIS, this.cps.length);
    this.pos++;
  }

  parseGroup(at) {
    if (this.isChar('*')) {
      // (*VERB) or (*alpha_assertion:...)
      throw untranslatable('a (*...) verb or alphabetic assertion', at);
    }
    if (!this.isChar('?')) {
      if (this.opts.n) {
        const body = this.parseAlt(); this.close(at);
        return { t: 'group', kind: 'noncap', body };
      }
      return this.capture(at);
    }
    this.pos++;
    const c = this.peek();
    const simple = { ':': 'noncap', '>': 'atomic', '=': 'la', '!': 'nla' };
    const ch = c === undefined ? '' : String.fromCodePoint(c);
    if (ch in simple) {
      this.pos++;
      const body = this.parseAlt(); this.close(at);
      return { t: 'group', kind: simple[ch], body };
    }
    if (ch === '<' && (this.isChar('=', 1) || this.isChar('!', 1))) {
      const kind = this.isChar('=', 1) ? 'lb' : 'nlb';
      this.pos += 2;
      const body = this.parseAlt(); this.close(at);
      if (hasBackref(body)) throw untranslatable('a back reference in a lookbehind', at);
      // PCRE2's limits: no unbounded repetition; a variable-length branch at most 255 long.
      // Variable-length branches (PCRE2 10.43+) are not translated: the JIT's positioning of
      // them differs from ECMAScript's backward matching (branches of different fixed lengths
      // are classic lookbehinds, and are)
      if (unbounded(body)) throw this.err(ERR.LOOKBEHIND_NOT_FIXED_LENGTH, at);
      for (const b of body.t === 'alt' ? body.alts : [body]) {
        const w = width(b);
        if (w.min !== w.max) {
          if (w.max > 255) throw this.err(ERR.LOOKBEHIND_BRANCH_TOO_LONG, at);
          throw untranslatable('a variable-length lookbehind branch', at);
        }
        if (w.max > 65535) throw this.err(ERR.LOOKBEHIND_TOO_LONG, at);
      }
      return { t: 'group', kind, body };
    }
    if (ch === '<') { this.pos++; return this.capture(at, this.parseName('>')); }
    if (ch === "'") { this.pos++; return this.capture(at, this.parseName("'")); }
    if (ch === 'P') {
      this.pos++;
      if (this.isChar('<')) { this.pos++; return this.capture(at, this.parseName('>')); }
      if (this.isChar('=')) {
        this.pos++;
        const name = this.parseName(')');
        return this.backref({ name, at });
      }
      if (this.isChar('>')) throw untranslatable('a subroutine call (?P>name)', at);
      throw this.err(ERR.INVALID_AFTER_PARENS_QUERY, this.pos);
    }
    if (ch === '#') {
      while (!this.eof() && !this.isChar(')')) this.pos++;
      if (this.eof()) throw this.err(ERR.MISSING_COMMENT_CLOSING, at);
      this.pos++;
      return null;
    }
    if (ch === '|') throw untranslatable('a branch-reset group (?|...)', at);
    if (ch === '(') throw untranslatable('a conditional group (?(...)...)', at);
    if (ch === 'R' || ch === '&' || ch === '+' || (ch >= '0' && ch <= '9') || (ch === '-' && /[0-9]/.test(String.fromCodePoint(this.peek(1) ?? 0))))
      throw untranslatable('recursion or a subroutine call', at);
    if (ch === 'C') throw untranslatable('a callout', at);
    if (ch === '*') throw untranslatable('a non-atomic lookahead (?*...)', at);
    // option setting: (?imnsxxU-imnsx) or (?^...) or (?...:body)
    return this.parseOptions(at);
  }

  parseOptions(at) {
    const o = { ...this.opts };
    let neg = false, sawHyphen = false;
    if (this.isChar('^')) {
      sawHyphen = true;    // (no '-' after a reset)
      this.pos++;
      o.i = o.m = o.s = o.x = o.xx = o.n = false;   // (not U: PCRE2 keeps it)
    }
    for (;;) {
      const c = this.peek();
      if (c === undefined) throw this.err(ERR.MISSING_CLOSING_PARENTHESIS, this.pos);
      const ch = String.fromCodePoint(c);
      this.pos++;
      if (ch === ')' || ch === ':') {
        if (ch === ')') { this.opts = o; return null; }   // to the end of the enclosing group
        const outer = this.opts;
        this.opts = o;
        const body = this.parseAlt();
        this.opts = outer;
        this.close(at);
        return { t: 'group', kind: 'noncap', body };
      }
      if (ch === '-') {
        if (sawHyphen) throw this.err(ERR.INVALID_HYPHEN_IN_OPTIONS, this.pos - 1);
        neg = sawHyphen = true;
        continue;
      }
      const v = !neg;
      if (ch === 'i') o.i = v;
      else if (ch === 'm') o.m = v;
      else if (ch === 's') o.s = v;
      else if (ch === 'n') o.n = v;
      else if (ch === 'U') o.U = v;
      else if (ch === 'x') {
        if (!neg && this.isChar('x')) { this.pos++; o.x = o.xx = true; }
        else { o.x = v; if (!v) o.xx = false; }
      }
      else if (ch === 'J') throw untranslatable('(?J) duplicate names', at);
      else if (ch === 'a' || ch === 'r') throw untranslatable(`the option (?${ch})`, at);
      else throw this.err(ERR.INVALID_AFTER_PARENS_QUERY, this.pos - 1);
    }
  }

  backref(b) {
    // (`refAt`: the offset of a reference error, which `at`, the atom's start, is not)
    const node = { t: 'backref', i: this.opts.i, ...b };
    this.backrefs.push(node);
    return node;
  }

  // a number after \g or \k forms; `rel` for \g{-n}
  backrefNumber(n, rel, at) {
    if (rel) {
      if (n === 0) throw this.err(ERR.ZERO_RELATIVE_REFERENCE, at);
      n = this.ncap - n + 1;
      if (n < 1) throw this.err(ERR.BAD_SUBPATTERN_REFERENCE, at + 2);   // (PCRE2: at the brace)
    }
    return this.backref({ group: n, at, refAt: this.pos - 1 });
  }

  parseEscape(at, items) {
    if (this.eof()) throw this.err(ERR.END_BACKSLASH, this.pos);
    const c = this.cps[this.pos++];
    const ch = String.fromCodePoint(c);
    // \Q...\E
    if (ch === 'Q') {
      let k = this.pos;
      for (; k < this.cps.length; k++) {
        if (this.cps[k] === 0x5c && this.cps[k + 1] === 0x45) break;
      }
      const lits = this.cps.slice(this.pos, k).map((cp) => this.lit(cp));
      this.pos = Math.min(k + 2, this.cps.length);
      if (lits.length === 0) return null;
      // all but the last go in the sequence as they are; the last can take a quantifier
      for (let j = 0; j < lits.length - 1; j++) items.push(lits[j]);
      return lits[lits.length - 1];
    }
    if (ch === 'E') return null;
    const single = this.singleCharEscape(ch, at, false);
    if (single !== undefined) return this.lit(single);
    switch (ch) {
      case 'd': case 'D': case 'w': case 'W': case 's': case 'S': case 'h': case 'H': case 'v': case 'V':
        return { t: 'class', neg: false, items: [{ k: 'esc', e: ch }], i: this.opts.i };
      case 'p': case 'P':
        return { t: 'class', neg: false, items: [this.parseProperty(ch === 'P', at)], i: this.opts.i };
      case 'N':
        if (this.isChar('{')) {
          const m = this.matchBraced(/^U\+([0-9A-Fa-f]+)$/);
          if (m && this.utf) return this.lit(this.codePoint(parseInt(m[1], 16), this.pos - 1));
          throw this.err(ERR.UNSUPPORTED_ESCAPE_SEQUENCE, at);
        }
        return { t: 'dot', s: false };
      case 'R': return { t: 'R' };
      case 'b': return { t: 'wordb', neg: false };
      case 'B': return { t: 'wordb', neg: true };
      case 'A': return { t: 'A' };
      case 'z': return { t: 'z' };
      case 'Z': return { t: 'Z' };
      case 'G': throw untranslatable('\\G', at);
      case 'K': throw untranslatable('\\K', at);
      case 'C': throw untranslatable('\\C', at);
      case 'X': throw untranslatable('\\X (extended grapheme cluster)', at);
      case 'g': return this.parseG(at);
      case 'k': {
        const open = this.peek();
        const term = open === 0x3c ? '>' : open === 0x27 ? "'" : open === 0x7b ? '}' : null;
        if (term === null) throw this.err(ERR.BACKSLASH_K_SYNTAX, at);
        this.pos++;
        return this.backref({ name: this.parseName(term), at, refAt: at + 3 });
      }
    }
    if (c >= 0x31 && c <= 0x39) {
      // \1..\9 (and \8, \9...): a back reference; \10 and up: one if that many groups were
      // opened before it, else octal (PCRE2's rule)
      let s = ch;
      while (this.peek() >= 0x30 && this.peek() <= 0x39) s += String.fromCodePoint(this.cps[this.pos++]);
      const n = Number(s);
      if (n < 10 || c === 0x38 || c === 0x39 || n <= this.ncap) return this.backref({ group: n, at, refAt: this.pos - 1 });
      this.pos = at + 1;
      return this.lit(this.octal(at));
    }
    if (isAlnumAscii(c)) throw this.err(ERR.UNKNOWN_ESCAPE, this.pos);
    return this.lit(c);
  }

  parseG(at) {
    const open = this.peek();
    if (open === 0x3c || open === 0x27) throw untranslatable('a subroutine call \\g<...>', at);
    let body;
    if (open === 0x7b) {
      const m = this.matchBraced(/^(.*)$/s);
      if (!m) throw this.err(ERR.BACKSLASH_G_SYNTAX, at);
      body = m[1];
    } else {
      let s = '';
      if (this.isChar('-') || this.isChar('+')) s += String.fromCodePoint(this.cps[this.pos++]);
      while (this.peek() >= 0x30 && this.peek() <= 0x39) s += String.fromCodePoint(this.cps[this.pos++]);
      body = s;
      if (!/^[-+]?[0-9]+$/.test(body)) throw this.err(ERR.BACKSLASH_G_SYNTAX, at);
    }
    if (/^-[0-9]+$/.test(body)) return this.backrefNumber(Number(body.slice(1)), true, at);
    if (/^\+[0-9]+$/.test(body)) throw untranslatable('a forward relative reference \\g{+n}', at);
    if (/^[0-9]+$/.test(body)) return this.backrefNumber(Number(body), false, at);
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(body)) return this.backref({ name: body, at, refAt: this.pos - 1 });
    throw this.err(ERR.BACKSLASH_G_SYNTAX, at);
  }

  // `{...}` after the current position, matched against `re`; consumes it on success
  matchBraced(re) {
    if (!this.isChar('{')) return null;
    let j = this.pos + 1, s = '';
    while (j < this.cps.length && this.cps[j] !== 0x7d) s += String.fromCodePoint(this.cps[j++]);
    if (j >= this.cps.length) return null;
    const m = re.exec(s);
    if (m) this.pos = j + 1;
    return m;
  }

  codePoint(v, at) {
    if (this.utf ? (v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff)) : v > 0xff)
      throw this.err(this.utf && v <= 0x10ffff ? ERR.UTF8_ERROR : ERR.CODE_POINT_TOO_BIG, at);
    return v;
  }

  octal(at) {
    let s = '';
    while (s.length < 3 && this.peek() >= 0x30 && this.peek() <= 0x37) s += String.fromCodePoint(this.cps[this.pos++]);
    return this.codePoint(parseInt(s || '0', 8), at);
  }

  // escapes that denote one character, or undefined; `inClass` for \b (backspace)
  singleCharEscape(ch, at, inClass) {
    switch (ch) {
      case 'a': return 0x07;
      case 'e': return 0x1b;
      case 'f': return 0x0c;
      case 'n': return 0x0a;
      case 'r': return 0x0d;
      case 't': return 0x09;
      case 'b': return inClass ? 0x08 : undefined;
      case '0': this.pos--; return this.octal(at);
      case 'o': {
        if (!this.isChar('{')) throw this.err(ERR.BACKSLASH_O_MISSING_BRACE, at);
        const m = this.matchBraced(/^\s*([0-7]+)\s*$/);
        if (!m) throw this.err(ERR.INVALID_HEXADECIMAL, at);
        return this.codePoint(parseInt(m[1], 8), at);
      }
      case 'c': {
        const x = this.peek();
        if (x === undefined) throw this.err(ERR.END_BACKSLASH_C, this.pos);
        if (x < 0x20 || x > 0x7e) throw this.err(ERR.BACKSLASH_C_SYNTAX, this.pos + 1);
        this.pos++;
        const up = x >= 0x61 && x <= 0x7a ? x - 0x20 : x;
        return up ^ 0x40;
      }
      case 'x': {
        if (this.bsux) {
          // ECMAScript style: \xhh, else a literal 'x'
          if (isHex(this.peek()) && isHex(this.peek(1))) {
            const v = parseInt(String.fromCodePoint(this.peek(), this.peek(1)), 16);
            this.pos += 2;
            return v;
          }
          return 0x78;
        }
        if (this.isChar('{')) {
          const m = this.matchBraced(/^\s*([0-9A-Fa-f]+)\s*$/);
          if (!m) throw this.err(ERR.INVALID_HEXADECIMAL, at);
          return this.codePoint(parseInt(m[1], 16), at);
        }
        let s = '';
        while (s.length < 2 && isHex(this.peek())) s += String.fromCodePoint(this.cps[this.pos++]);
        return parseInt(s || '0', 16);
      }
      case 'u':
        if (!this.bsux) throw this.err(ERR.UNSUPPORTED_ESCAPE_SEQUENCE, this.pos);
        if ([0, 1, 2, 3].every((k) => isHex(this.peek(k)))) {
          const v = parseInt(String.fromCodePoint(...this.cps.slice(this.pos, this.pos + 4)), 16);
          this.pos += 4;
          return this.codePoint(v, at);
        }
        return 0x75;
      case 'U':
        if (!this.bsux) throw this.err(ERR.UNSUPPORTED_ESCAPE_SEQUENCE, this.pos);
        return 0x55;
      case 'L': case 'l': case 'F':
        throw this.err(ERR.UNSUPPORTED_ESCAPE_SEQUENCE, this.pos);
    }
    return undefined;
  }

  parseProperty(neg, at) {
    let name;
    if (this.isChar('{')) {
      const m = this.matchBraced(/^(.*)$/s);
      if (!m) throw this.err(ERR.MALFORMED_UNICODE_PROPERTY, at);
      name = m[1];
    } else {
      if (this.eof()) throw this.err(ERR.MALFORMED_UNICODE_PROPERTY, at);
      name = String.fromCodePoint(this.cps[this.pos++]);
    }
    if (name.startsWith('^')) { neg = !neg; name = name.slice(1); }
    // PCRE2 ignores case, spaces, hyphens and underscores in property names
    const loose = name.toLowerCase().replace(/[\s_-]/g, '');
    let set, caseless = null;
    if (GC_NAMES.has(loose)) {
      const gc = GC_NAMES.get(loose);
      set = ucd(`gc:${gc}`);
      // PCRE2 case-closes Lu, Ll and Lt under caseless matching
      if (gc === 'Lu' || gc === 'Ll' || gc === 'Lt') caseless = ucd(`gci:${gc}`);
    } else if (GC_GROUPS[loose]) set = union(...GC_GROUPS[loose].map((g) => ucd(`gc:${g}`)));
    else if (loose === 'cs') set = [];   // (no valid UTF-8 encodes a surrogate)
    else if (loose === 'any') set = complement([]);
    else if (loose === 'l&' || loose === 'lc') set = ucd('x:L&');
    else if (['xan', 'xps', 'xsp', 'xwd', 'xuc'].includes(loose)) set = ucd(`x:X${loose.slice(1)}`);
    else {
      const m = /^(?:sc|script|scx|scriptextensions)[:=](.*)$/.exec(loose);
      const scx = !m || /^(scx|scriptextensions)/.test(loose);
      const script = SCRIPT_KEYS.get(m ? m[1] : loose);
      if (!script) {
        // (PCRE2 also takes 4-letter script abbreviations, which the tables don't have)
        if (/^[a-z]{4}$/.test(m ? m[1] : loose)) throw untranslatable(`the script abbreviation ${name}`, at);
        throw this.err(ERR.UNKNOWN_UNICODE_PROPERTY, this.pos);
      }
      // PCRE2's bare \p{Greek} is Script_Extensions; sc: is Script
      set = ucd(`${scx ? 'scx' : 'sc'}:${script}`);
    }
    return { k: 'prop', set, caseless, neg };
  }

  // [...]
  parseClass(at) {
    // [:name:] (or [.x.], [=x=]) not inside a class: PCRE2's errors (its check_posix_syntax)
    if ((this.isChar(':') || this.isChar('.') || this.isChar('=')) && this.posixSyntax(this.pos))
      throw this.err(this.isChar(':') ? ERR.POSIX_CLASS_NOT_IN_CLASS : ERR.POSIX_NO_SUPPORT_COLLATING, at);
    const xx = this.opts.xx;
    // \E, an empty \Q\E and (xx) spaces and tabs are transparent anywhere in a class, also
    // around a range's hyphen (a quoted hyphen is a literal)
    const skipTransparent = () => {
      for (;;) {
        if (this.isChar('\\') && this.isChar('Q', 1) && this.isChar('\\', 2) && this.isChar('E', 3)) this.pos += 4;
        else if (this.isChar('\\') && this.isChar('E', 1)) this.pos += 2;
        else if (xx && (this.isChar(' ') || this.isChar('\t'))) this.pos++;
        else return;
      }
    };
    // a leading `^` (after transparent tokens) negates; a `]` first (after both) is a member
    let neg = false;
    skipTransparent();
    if (this.isChar('^')) { neg = true; this.pos++; }
    const items = [];
    let first = true;
    let carry = null;   // the last character of a quoted range end, which can start a range
    for (;;) {
      let lo = carry;
      carry = null;
      if (lo === null) {
        skipTransparent();
        if (this.eof()) throw this.err(ERR.MISSING_SQUARE_BRACKET, this.cps.length);
        if (this.isChar(']') && !first) { this.pos++; break; }
        lo = this.classAtom(at);
        if (lo === null) continue;
      }
      first = false;
      if (lo.k === 'chars') {
        // \Q...\E: all but the last as members; the last can start a range
        for (const cp of lo.cps.slice(0, -1)) items.push({ k: 'char', cp });
        lo = { k: 'char', cp: lo.cps[lo.cps.length - 1] };
      }
      // a range? (an unquoted hyphen, not followed by the class's end)
      const save = this.pos;
      skipTransparent();
      if (!this.isChar('-')) { this.pos = save; items.push(lo); continue; }
      const hyphen = this.pos;
      this.pos++;
      skipTransparent();
      if (this.eof() || this.isChar(']')) { this.pos = hyphen; items.push(lo); continue; }
      // [\d-z]: PCRE2 errors (10.43+: invalid range), at the hyphen's end
      if (lo.k !== 'char') throw this.err(ERR.CLASS_INVALID_RANGE, hyphen + 1);
      const quoted = this.isChar('\\') && this.isChar('Q', 1);
      const qAt = this.pos + 2;
      const hi = this.classAtom(at);
      if (hi === null) throw new Error('internal: a transparent class token after a range hyphen');
      if (hi.k === 'chars') {
        // PCRE2 10.47 reports the offset after the first quoted character.
        if (hi.cps[0] < lo.cp) throw this.err(ERR.CLASS_RANGE_ORDER, qAt + 1);
        items.push({ k: 'range', lo: lo.cp, hi: hi.cps[0] });
        // the rest as members, the last of them able to start a range (`[a-\Qbe\E-g]`)
        if (hi.cps.length > 1) carry = { k: 'chars', cps: hi.cps.slice(1) };
        continue;
      }
      // [a-\d]: PCRE2 errors (10.43+: invalid range)
      if (hi.k !== 'char') throw this.err(ERR.CLASS_INVALID_RANGE, this.pos);
      // The error offset follows the complete range endpoint, including escapes.
      if (hi.cp < lo.cp) throw this.err(ERR.CLASS_RANGE_ORDER, quoted ? qAt + 1 : this.pos);
      items.push({ k: 'range', lo: lo.cp, hi: hi.cp });
    }
    return { t: 'class', neg, items, i: this.opts.i };
  }

  // whether a POSIX-class spelling starts at `i` (its terminator, then `<terminator>]`)
  posixSyntax(i) {
    const cps = this.cps, term = cps[i];
    for (let k = i + 1; k < cps.length; k++) {
      if (cps[k] === 0x5c && (cps[k + 1] === 0x5d || cps[k + 1] === 0x5c)) k++;
      else if ((cps[k] === 0x5b && cps[k + 1] === term) || cps[k] === 0x5d) return false;
      else if (cps[k] === term && cps[k + 1] === 0x5d) return true;
    }
    return false;
  }

  // one class item, or null for \E / an empty \Q\E
  classAtom(at) {
    const start = this.pos;
    const c = this.cps[this.pos++];
    if (c === 0x5b && this.isChar(':')) {
      // [:name:] / [:^name:]
      const rest = String.fromCodePoint(...this.cps.slice(this.pos, this.pos + 12));
      const m = /^:(\^?)([a-z]+):\]/.exec(rest);
      if (m) {
        this.pos += m[0].length;
        const name = m[2];
        if (!(name in ASCII)) throw this.err(ERR.UNKNOWN_POSIX_CLASS, this.pos);
        return { k: 'posix', name, neg: m[1] === '^' };
      }
    }
    if (c === 0x5b && (this.isChar('.') || this.isChar('='))) {
      const t = this.peek();
      const close = this.cps.indexOf(t, this.pos + 1);
      if (close > 0 && this.cps[close + 1] === 0x5d) throw untranslatable('a POSIX collating element', start);
    }
    if (c !== 0x5c) return { k: 'char', cp: c };
    if (this.eof()) throw this.err(ERR.END_BACKSLASH, start);
    const e = this.cps[this.pos++];
    const ch = String.fromCodePoint(e);
    if (ch === 'Q') {
      // \Q...\E inside a class: the characters as class members
      const out = [];
      while (!this.eof() && !(this.isChar('\\') && this.isChar('E', 1))) out.push(this.cps[this.pos++]);
      if (!this.eof()) this.pos += 2;
      return out.length === 0 ? null : { k: 'chars', cps: out };
    }
    if (ch === 'E') return null;
    const single = this.singleCharEscape(ch, start, true);
    if (single !== undefined) return { k: 'char', cp: single };
    if ('dDwWsShHvV'.includes(ch)) return { k: 'esc', e: ch };
    if (ch === 'p' || ch === 'P') return this.parseProperty(ch === 'P', start);
    if (ch === 'N') throw this.err(ERR.BACKSLASH_N_IN_CLASS, start);
    // (`\8` and `\9` are no octal escape: declined rather than guessed)
    if (e === 0x38 || e === 0x39) throw untranslatable(`the escape \\${ch} in a character class`, start);
    if (e >= 0x31 && e <= 0x37) { this.pos--; return { k: 'char', cp: this.octal(start) }; }
    if (ch === 'R' || ch === 'X' || ch === 'B') throw this.err(ERR.ESCAPE_INVALID_IN_CLASS, this.pos);
    if (isAlnumAscii(e)) throw this.err(ERR.UNKNOWN_ESCAPE, this.pos);
    return { k: 'char', cp: e };
  }
}

const isHex = (c) => c !== undefined && ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66));
const isAlnumAscii = (c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
// PCRE2's extended-mode white space: ASCII space characters, plus in UTF mode the Pattern_White_Space ones
const isPatternSpace = (c, utf) => c === 0x20 || (c >= 0x09 && c <= 0x0d) ||
  (utf && (c === 0x85 || c === 0x200e || c === 0x200f || c === 0x2028 || c === 0x2029));

// the minimum and maximum length (code points) a node matches (`Infinity`: unbounded; a zero
// count times anything is zero). `capMin` (group -> a lower bound of its captures' lengths)
// gives back references a minimum, for groups certainly set where they are referenced
function width(n, capMin) {
  const mul = (a, b) => (a === 0 || b === 0 ? 0 : a * b);
  switch (n.t) {
    case 'seq': {
      let min = 0, max = 0;
      for (const it of n.items) { const w = width(it, capMin); min += w.min; max += w.max; }
      return { min, max };
    }
    case 'alt': {
      let min = Infinity, max = 0;
      for (const a of n.alts) { const w = width(a, capMin); min = Math.min(min, w.min); max = Math.max(max, w.max); }
      return { min, max };
    }
    case 'group':
      if (n.kind === 'la' || n.kind === 'nla' || n.kind === 'lb' || n.kind === 'nlb') return { min: 0, max: 0 };
      return width(n.body, capMin);
    case 'quant': {
      const w = width(n.body, capMin);
      return { min: mul(w.min, n.min), max: mul(w.max, n.max) };
    }
    case 'char': case 'class': case 'dot': return { min: 1, max: 1 };
    case 'R': return { min: 1, max: 2 };
    case 'backref': return { min: capMin?.get(n.group) ?? 0, max: Infinity };
    default: return { min: 0, max: 0 };
  }
}

// whether a lookbehind body has an unbounded repetition (outside nested lookaheads)
function unbounded(n) {
  if (!n || typeof n !== 'object') return false;
  // (a quantified assertion is obeyed at most once: its repeat count isn't a length)
  if (n.t === 'quant' && n.body.t === 'group' && ['la', 'nla', 'lb', 'nlb'].includes(n.body.kind)) return unbounded(n.body);
  if (n.t === 'quant') return n.max === Infinity || unbounded(n.body);
  if (n.t === 'seq') return n.items.some(unbounded);
  if (n.t === 'alt') return n.alts.some(unbounded);
  if (n.t === 'group') return n.kind !== 'la' && n.kind !== 'nla' && unbounded(n.body);
  return false;
}

// group -> the minimum length of its captures, a back reference inside one counting its own
// group's minimum (computed to a fixed point); a reference to a group whose minimum depends on
// itself, through references, counts 0
function captureMins(ast) {
  const bodies = new Map();            // group -> its capture bodies
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (n.t === 'group' && n.kind === 'cap') { if (!bodies.has(n.group)) bodies.set(n.group, []); bodies.get(n.group).push(n.body); }
    if (n.t === 'seq') n.items.forEach(walk);
    else if (n.t === 'alt') n.alts.forEach(walk);
    else if (n.t === 'group' || n.t === 'quant') walk(n.body);
  })(ast);
  const refs = (n, out) => {
    if (!n || typeof n !== 'object') return out;
    if (n.t === 'backref') out.add(n.group);
    if (n.t === 'seq') n.items.forEach((it) => refs(it, out));
    else if (n.t === 'alt') n.alts.forEach((a) => refs(a, out));
    else if (n.t === 'group' || n.t === 'quant') refs(n.body, out);
    return out;
  };
  const deps = new Map([...bodies].map(([g, bs]) => [g, bs.reduce((o, b) => refs(b, o), new Set())]));
  const cyclic = new Set([...bodies.keys()].filter((g) => {
    const seen = new Set(), todo = [...(deps.get(g) ?? [])];
    while (todo.length) {
      const h = todo.pop();
      if (h === g) return true;
      if (seen.has(h)) continue;
      seen.add(h);
      todo.push(...(deps.get(h) ?? []));
    }
    return false;
  }));
  let mins = new Map();
  for (let round = 0; round <= bodies.size; round++) {
    const next = new Map();
    for (const [g, bs] of bodies) {
      if (cyclic.has(g)) continue;
      next.set(g, Math.min(...bs.map((b) => width(b, mins).min)));
    }
    const same = next.size === mins.size && [...next].every(([g, m]) => mins.get(g) === m);
    mins = next;
    if (same) break;
  }
  return mins;
}

// ---------------------------------------------------------------------------------------------
// Emitter: AST -> ECMAScript `v`-mode source. JS capture numbers are assigned in source order;
// atomic groups (and possessive quantifiers) add a capture each: `(?>X)` is `(?=(X))\k`.

class Emitter {
  constructor(p, mopts, flags) {
    this.p = p;
    this.utf = p.utf;
    this.ucp = p.ucp && p.utf;
    this.notbol = (mopts & PCRE.NOTBOL) !== 0;
    this.noteol = (mopts & PCRE.NOTEOL) !== 0;
    this.globalI = flags.i;      // the JS `i` flag (UTF mode only)
    this.js = 0;                 // JS capture counter
    this.groupMap = new Int32Array(p.ncap + 1);
    this.dollarEndOnly = p.dollarEndOnly;
    this.altCircumflex = p.altCircumflex;
  }
  newGroup() { return ++this.js; }

  // wrap `src` for the caseless state `i` relative to the context's `ctxI`
  caseWrap(src, i, ctxI) {
    if (!this.utf || i === ctxI) return src;
    return i ? `(?i:${src})` : `(?-i:${src})`;
  }

  emit(n, ctxI) {
    switch (n.t) {
      case 'seq': return n.items.map((it) => this.emit(it, ctxI)).join('');
      case 'alt': return n.alts.map((a) => this.emit(a, ctxI)).join('|');
      case 'char': return this.emitChar(n, ctxI);
      case 'class': return this.emitClass(n, ctxI);
      case 'dot': return this.utf ? (n.s ? '[^\\p{Cs}]' : '[^\\n\\p{Cs}]') : (n.s ? '[\\0-\\xff]' : '[^\\n]');
      case 'bol':
        if (!n.m) return this.notbol ? '(?!)' : '^';
        return this.altCircumflex
          ? (this.notbol ? '(?<=\\n)' : '(?:^|(?<=\\n))')
          : (this.notbol ? '(?<=\\n)(?=[^])' : '(?:^|(?<=\\n)(?=[^]))');
      case 'eol':
        if (n.m) return this.noteol ? '(?=\\n)' : '(?=\\n|$)';
        if (this.noteol) return '(?!)';
        return this.dollarEndOnly ? '$' : '(?=\\n?$)';
      case 'A': return '^';
      case 'z': return '$';
      case 'Z': return '(?=\\n?$)';
      case 'R': {
        const g = this.newGroup();
        return `(?=(\\r\\n|[\\n\\x0b\\f\\r${this.utf ? '\\x85\\u2028\\u2029' : '\\x85'}]))\\${g}(?:)`;
      }
      case 'wordb': {
        const W = classSrc(this.utf && this.ucp ? ucd('ucp:w') : ASCII.w);
        const w = this.utf ? `(?-i:${W})` : W;
        return n.neg
          ? `(?:(?<=${w})(?=${w})|(?<!${w})(?!${w}))`
          : `(?:(?<=${w})(?!${w})|(?<!${w})(?=${w}))`;
      }
      case 'backref': {
        const g = this.groupMap[n.group];
        if (n.i) throw untranslatable(this.utf ? 'a caseless back reference (V8 folds with Unicode 17, PCRE2 with 16)' : 'a caseless back reference in byte mode', n.at);
        return this.caseWrap(`\\${g}(?:)`, n.i, ctxI);
      }
      case 'quant': return this.emitQuant(n, ctxI);
      case 'group': return this.emitGroup(n, ctxI);
    }
    throw new Error(`internal: node ${n.t}`);
  }

  emitChar(n, ctxI) {
    if (this.utf) return this.caseWrap(vchar(n.cp), n.i && !touchesU17(n.cp, n.cp), ctxI);
    // byte mode: ASCII letters fold by PCRE2's C tables only
    if (n.i && ((n.cp >= 0x41 && n.cp <= 0x5a) || (n.cp >= 0x61 && n.cp <= 0x7a)))
      return `[${vchar(n.cp & ~0x20)}${vchar(n.cp | 0x20)}]`;
    return vchar(n.cp);
  }

  emitQuant(n, ctxI) {
    const body = this.emit(n.body, ctxI);
    const q = n.min === 0 && n.max === Infinity ? '*' : n.min === 1 && n.max === Infinity ? '+' :
      n.min === 0 && n.max === 1 ? '?' : n.max === Infinity ? `{${n.min},}` :
      n.min === n.max ? `{${n.min}}` : `{${n.min},${n.max}}`;
    return `(?:${body})${q}${n.greedy ? '' : '?'}`;
  }

  emitGroup(n, ctxI) {
    switch (n.kind) {
      case 'cap': {
        const g = this.newGroup();
        this.groupMap[n.group] = g;
        return `(${this.emit(n.body, ctxI)})`;
      }
      case 'noncap': return `(?:${this.emit(n.body, ctxI)})`;
      case 'la': return `(?=${this.emit(n.body, ctxI)})`;
      case 'nla': return `(?!${this.emit(n.body, ctxI)})`;
      case 'lb': return `(?<=${this.emit(n.body, ctxI)})`;
      case 'nlb': return `(?<!${this.emit(n.body, ctxI)})`;
      case 'atomic': {
        const g = this.newGroup();
        return `(?=(${this.emit(n.body, ctxI)}))\\${g}(?:)`;
      }
    }
    throw new Error(`internal: group ${n.kind}`);
  }

  // ---- classes

  // the code points of a non-literal class item (escape, POSIX class, property)
  itemSet(it, caseless) {
    let set, neg = false;
    if (it.k === 'esc') {
      const lower = it.e.toLowerCase();
      neg = it.e !== lower;
      if (!this.utf) set = lower === 'h' || lower === 'v' ? BYTE_HV[lower] : ASCII[lower];
      else if (this.ucp || lower === 'h' || lower === 'v') set = ucd(`ucp:${lower}`);
      else set = ASCII[lower];
    } else if (it.k === 'posix') {
      neg = it.neg;
      set = this.ucp ? ucd(`posix:${it.name}`) : ASCII[it.name];
      // without UCP: caseless [:upper:] and [:lower:] are all letters (PCRE2's C tables)
      if (!this.ucp && caseless && (it.name === 'upper' || it.name === 'lower')) set = ASCII.alpha;
    } else if (it.k === 'prop') {
      neg = it.neg;
      set = caseless && it.caseless ? it.caseless : it.set;
    } else throw new Error(`internal: class item ${it.k}`);
    return neg ? complement(set) : set;
  }

  // the class as a JS source that matches one code point (never an invalid byte's surrogate)
  emitClass(n, ctxI) {
    if (!this.utf) return this.byteClass(n);
    const lits = [], props = [];
    for (const it of n.items) {
      if (it.k === 'char') lits.push([it.cp, it.cp]);
      else if (it.k === 'range') lits.push([it.lo, it.hi]);
      else props.push(this.itemSet(it, n.i));
    }
    // (a literal range spanning U+D800-U+DFFF has no surrogates: they are invalid bytes here)
    const L = minus(normalize(lits), []), P = union(...props);
    if (!n.i) {
      const all = union(L, P);
      return this.caseWrap(classSrc(n.neg ? complement(all) : all), false, ctxI);
    }
    // caseless: the literals fold (V8's folding, but not into code points new in Unicode 17);
    // escapes, POSIX classes and properties are sets as PCRE2 has them under caseless matching
    const parts = [];
    if (L.length) {
      // Unicode-17 code points in the class match only themselves (no case in Unicode 16); the
      // others fold, but never to a Unicode-17 code point
      const far = L.some(([, b]) => b >= U17_LOWEST);
      const Lnew = far ? minus(L, complement(u17New())) : [], Lold = far ? minus(L, u17New()) : L;
      if (Lnew.length) parts.push(`(?-i:${classSrc(Lnew)})`);
      if (Lold.length) {
        const lit = `(?i:${classSrc(Lold)})`;
        parts.push(Lold.some(([a, b]) => touchesU17(a, b)) ? `(?:(?!(?-i:${classSrc(u17New())}))${lit})` : lit);
      }
    }
    if (P.length) parts.push(`(?-i:${classSrc(P)})`);
    if (!n.neg) return parts.length ? `(?:${parts.join('|')})` : '(?!)';
    return `(?!${parts.join('|') || '(?!)'})[^\\p{Cs}]`;
  }

  // byte mode: the class as an explicit set of bytes
  byteClass(n) {
    let set = [];
    const lits = [];
    for (const it of n.items) {
      if (it.k === 'char') lits.push([it.cp, it.cp]);
      else if (it.k === 'range') lits.push([it.lo, it.hi]);
      else set = union(set, this.itemSet(it, n.i));
    }
    for (const [lo, hi] of lits) {
      set = union(set, [[lo, hi]]);
      // caseless: ASCII letters only (PCRE2's C tables)
      if (n.i) for (let c = lo; c <= Math.min(hi, 0x7a); c++) {
        if (c >= 0x41 && c <= 0x5a) set = union(set, [[c | 0x20, c | 0x20]]);
        if (c >= 0x61 && c <= 0x7a) set = union(set, [[c & ~0x20, c & ~0x20]]);
      }
    }
    set = normalize(set.map(([a, b]) => [a, Math.min(b, 0xff)]));
    if (n.neg) set = complement(set, 0xff);
    return classSrc(set);
  }
}

// Lowering and checks, between parsing and emission:
// - possessive quantifiers become atomic groups (emitted as `(?=(X))\k`);
// - `X?` whose X can match empty and holds captures becomes `(?:X|)` (`(?:|X)` lazy): PCRE2
//   accepts the empty iteration and sets the captures, ECMAScript rejects it (RepeatMatcher's
//   empty check) and leaves them unset;
// - shapes where ECMAScript's capture semantics differ from PCRE2's and that have no exact
//   rewrite are rejected: captures in a repetition (max > 1) that a later iteration may skip
//   (ECMAScript resets them per iteration, PCRE2 keeps the earlier value) or that can match
//   empty; back references to a group that may be unset there (PCRE2 fails, ECMAScript matches
//   empty); back references in lookbehinds, and captures in variable-length ones (ECMAScript
//   matches lookbehinds right to left).
function lower(n, ctx) {
  if (!n || typeof n !== 'object') return n;
  switch (n.t) {
    case 'seq': n.items = n.items.map((it) => lower(it, ctx)); return n;
    case 'alt': n.alts = n.alts.map((a) => lower(a, ctx)); return n;
    case 'group': {
      const lb = n.kind === 'lb' || n.kind === 'nlb';
      if (lb && hasCaptures(n.body)) {
        const w = width(n.body);
        if (w.min !== w.max) throw untranslatable('a capture group in a variable-length lookbehind', n.at ?? 0);
      }
      // (atomic groups are emulated with a lookahead and a back reference, which run forwards)
      if (ctx.inLookbehind && n.kind === 'atomic') throw untranslatable('an atomic group in a lookbehind', n.at ?? 0);
      n.body = lower(n.body, lb ? { ...ctx, inLookbehind: true } : ctx);
      return n;
    }
    case 'R':
      if (ctx.inLookbehind) throw untranslatable('\\R in a lookbehind', n.at ?? 0);
      return n;
    case 'backref':
      if (ctx.inLookbehind) throw untranslatable('a back reference in a lookbehind', n.at);
      return n;
    case 'quant': {
      // ECMAScript matches a lookbehind backwards: a repeated capture records another repetition
      if (ctx.inLookbehind && n.max > 1 && hasCaptures(n.body)) throw untranslatable('a repeated capture group in a lookbehind', n.at);
      if (ctx.inLookbehind && n.possessive) throw untranslatable('a possessive quantifier in a lookbehind', n.at);
      n.body = lower(n.body, ctx);
      // a quantified assertion: PCRE2 obeys it at most once ({0,n}: as `?`; min >= 1: as is)
      if (n.body.t === 'group' && ['la', 'nla', 'lb', 'nlb'].includes(n.body.kind)) {
        if (n.min >= 1) return n.body;
        if (n.max > 1) n.max = 1;
      }
      let out = n;
      const nullable = width(n.body, ctx.capMin).min === 0;
      if (nullable && n.max > n.min) {
        // an optional iteration of a body that can match empty: PCRE2 accepts the empty
        // iteration (and ends the repetition), ECMAScript rejects it and backtracks into the
        // body for a non-empty one; `X?` is exactly `(?:X|)` (`(?:|X)` lazy), others aren't
        if (n.min === 0 && n.max === 1) {
          const empty = { t: 'seq', items: [] };
          out = { t: 'group', kind: 'noncap', at: n.at,
            body: { t: 'alt', alts: n.greedy ? [n.body, empty] : [empty, n.body] } };
        } else {
          throw untranslatable('a repetition of a group that can match an empty string', n.at);
        }
      } else if (hasCaptures(n.body)) {
        if (n.max > 1) {
          const must = mustSet(n.body, new Set());
          for (const g of captures(n.body)) {
            if (!must.has(g)) throw untranslatable('a capture group that some repetitions may skip', n.at);
          }
        }
      }
      if (n.possessive) {
        if (out === n) out = { ...n, possessive: false, greedy: true };
        out = { t: 'group', kind: 'atomic', body: out, at: n.at };
      }
      return out;
    }
  }
  return n;
}

function* captures(n) {
  if (!n || typeof n !== 'object') return;
  if (n.t === 'group' && n.kind === 'cap') yield n.group;
  if (n.t === 'seq') for (const it of n.items) yield* captures(it);
  else if (n.t === 'alt') for (const a of n.alts) yield* captures(a);
  else if (n.t === 'group' || n.t === 'quant') yield* captures(n.body);
}
const hasCaptures = (n) => !captures(n).next().done;
function hasBackref(n) {
  if (!n || typeof n !== 'object') return false;
  if (n.t === 'backref') return true;
  if (n.t === 'seq') return n.items.some(hasBackref);
  if (n.t === 'alt') return n.alts.some(hasBackref);
  return (n.t === 'group' || n.t === 'quant') && hasBackref(n.body);
}

// the groups certainly set once `n` has matched, given `before`
function mustSet(n, before) {
  switch (n.t) {
    case 'seq': { let s = before; for (const it of n.items) s = mustSet(it, s); return s; }
    case 'alt': {
      let r = null;
      for (const a of n.alts) {
        const s = mustSet(a, before);
        r = r === null ? s : new Set([...r].filter((g) => s.has(g)));
      }
      return r ?? before;
    }
    case 'group':
      if (n.kind === 'nla' || n.kind === 'nlb') return before;
      { const s = new Set(mustSet(n.body, before)); if (n.kind === 'cap') s.add(n.group); return s; }
    case 'quant': return n.min >= 1 ? mustSet(n.body, before) : before;
  }
  return before;
}

// back references to groups that may be unset where they are (unless PCRE2_MATCH_UNSET_BACKREF,
// whose semantics are ECMAScript's)
function checkBackrefs(n, before) {
  switch (n.t) {
    case 'seq': { let s = before; for (const it of n.items) s = checkBackrefs(it, s); return s; }
    case 'alt': {
      let r = null;
      for (const a of n.alts) {
        const s = checkBackrefs(a, before);
        r = r === null ? s : new Set([...r].filter((g) => s.has(g)));
      }
      return r ?? before;
    }
    case 'group': {
      const s = new Set(checkBackrefs(n.body, before));
      if (n.kind === 'nla' || n.kind === 'nlb') return before;
      if (n.kind === 'cap') s.add(n.group);
      return s;
    }
    case 'quant': { const s = checkBackrefs(n.body, before); return n.min >= 1 ? s : before; }
    case 'backref':
      if (!before.has(n.group)) throw untranslatable('a back reference to a group that may be unset', n.at);
      return before;
  }
  return before;
}

// An upper estimate of the size of PCRE2's compiled code for `n`, in code units (8-bit,
// LINK_SIZE 2: patterns over 65,536 fail with "regular expression is too large"). Above
// SIZE_LIMIT the translator declines the pattern (900): it can't tell PCRE2's exact limit.
const SIZE_LIMIT = 60000;
function codeSize(n) {
  switch (n.t) {
    case 'seq': return n.items.reduce((a, it) => a + codeSize(it), 0);
    case 'alt': return n.alts.reduce((a, b) => a + codeSize(b) + 3, 0);
    case 'group': return codeSize(n.body) + 8;
    case 'quant': {
      const b = codeSize(n.body) + 4;
      // (a group is repeated by copies of it: the minimum, then one per optional repeat)
      const copies = Math.max(n.min, 1) + (n.max === Infinity ? 1 : n.max - n.min);
      return n.body.t === 'group' ? b * copies : b + 4;
    }
    case 'char': return 7;
    case 'class': return 43 + 9 * n.items.length;
    default: return 6;
  }
}

// PCRE2's start optimization for `.*` (PCRE2_NO_DOTSTAR_ANCHOR unset), as found by probes:
// when every top-level branch starts with `.*` (greedy or lazy; `\N*`; also inside groups
// that aren't atomic, optional or back-referenced) or with `^`, the pattern is "startline"
// (matches start only at the start offset and after a newline); when every branch starts
// with a DOTALL `.*` or `\A`/non-multiline `^`, "anchored" (only at the start offset). On a
// subject of valid UTF-8 neither changes a match; around invalid bytes they do (`exec`).
function dotstarKind(ast) {
  const referenced = new Set();
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (n.t === 'backref') referenced.add(n.group);
    if (n.t === 'seq') n.items.forEach(walk);
    else if (n.t === 'alt') n.alts.forEach(walk);
    else if (n.t === 'group' || n.t === 'quant') walk(n.body);
  })(ast);
  // {anch, line, star}: the branch starts anchored / at a line start; `star`: by a `.*`
  const start = (n) => {
    const none = { anch: false, line: false, star: false };
    if (!n) return none;
    switch (n.t) {
      case 'alt': {
        const ks = n.alts.map(start);
        return { anch: ks.every((k) => k.anch), line: ks.every((k) => k.line), star: ks.some((k) => k.star) };
      }
      case 'seq': return n.items.length ? start(n.items[0]) : none;
      case 'quant':
        if (n.body.t === 'dot' && n.min === 0 && n.max === Infinity && !n.possessive)
          return n.body.s ? { anch: true, line: false, star: true } : { anch: false, line: true, star: true };
        if (n.body.t === 'group' && n.min >= 1 && !n.possessive) return start(n.body);
        return none;
      case 'group':
        if (n.kind === 'noncap' || (n.kind === 'cap' && !referenced.has(n.group))) return start(n.body);
        return none;
      case 'bol': return n.m ? { anch: false, line: true, star: false } : { anch: true, line: true, star: false };
      case 'A': return { anch: true, line: false, star: false };
    }
    return none;
  };
  const k = start(ast);
  if (!k.star) return null;
  return k.anch ? 'anchored' : k.line ? 'startline' : null;
}

// ---------------------------------------------------------------------------------------------
// Public translator

/**
 * translate(pattern, options) -> { utf, ncap, names: [[name, group]...], variant(mopts) }
 * `pattern` is a Uint8Array (the pattern's bytes, as Julia passes them) or a string.
 * Throws RegexCompileError (offset in pattern bytes).
 */
export function translate(pattern, options, internal = {}) {
  const bytes = typeof pattern === 'string' ? new TextEncoder().encode(pattern) : pattern;
  // PCRE2_MATCH_INVALID_UTF implies PCRE2_UTF
  if (options & PCRE.MATCH_INVALID_UTF) options = (options | PCRE.UTF) >>> 0;
  const utf = (options & PCRE.UTF) !== 0;
  if ((options & ~SUPPORTED_COMPILE) !== 0) {
    throw new RegexCompileError(ERR.UNTRANSLATABLE, 0,
      `compile options 0x${(options & ~SUPPORTED_COMPILE >>> 0).toString(16)} are not supported by the Wasm regex translator`);
  }
  if ((options & PCRE.UTF) && (options & PCRE.NEVER_UTF))
    throw new RegexCompileError(174, 0, 'using UTF is disabled by the application');
  if ((options & PCRE.UCP) && (options & PCRE.NEVER_UCP))
    throw new RegexCompileError(175, 0, 'using UCP is disabled by the application');
  if ((options & PCRE.LITERAL) && (options & ~LITERAL_OPTIONS) !== 0)
    throw new RegexCompileError(192, 0, 'invalid option bits with PCRE2_LITERAL');
  if (!utf && (options & PCRE.UCP)) {
    throw new RegexCompileError(ERR.UNTRANSLATABLE, 0, 'PCRE2_UCP without PCRE2_UTF is not supported by the Wasm regex translator');
  }
  let cps, cpByte;
  if (utf) {
    let s;
    try { s = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
    catch { throw new RegexCompileError(ERR.UTF8_ERROR, firstInvalidUtf8(bytes), 'UTF-8 error: invalid UTF-8 string in the pattern'); }
    cps = Array.from(s, (ch) => ch.codePointAt(0));
  } else {
    cps = Array.from(bytes);
  }
  // code point index -> byte offset, for error offsets
  cpByte = new Uint32Array(cps.length + 1);
  for (let k = 0, b = 0; k < cps.length; k++) {
    cpByte[k] = b;
    b += !utf ? 1 : cps[k] < 0x80 ? 1 : cps[k] < 0x800 ? 2 : cps[k] < 0x10000 ? 3 : 4;
    cpByte[k + 1] = b;
  }
  const p = new Parser(cps, options);
  let ast;
  try {
    if (options & PCRE.LITERAL) {
      ast = { t: 'seq', items: cps.map((cp) => ({ t: 'char', cp, i: p.opts.i })) };
    } else {
      ast = p.parse();
      // (back references count with their group's length: checkBackrefs requires them set,
      // unless PCRE2_MATCH_UNSET_BACKREF)
      ast = lower(ast, { capMin: (options & PCRE.MATCH_UNSET_BACKREF) ? undefined : captureMins(ast) });
      if (!(options & PCRE.MATCH_UNSET_BACKREF)) checkBackrefs(ast, new Set());
    }
  } catch (e) {
    if (e instanceof RegexCompileError) e.offset = cpByte[Math.min(e.offset, cps.length)];
    throw e;
  }
  const names = [...p.names.entries()];
  // whether the pattern can match an empty string (a match options aren't needed for that)
  // (back references: to groups certainly set there, unless PCRE2_MATCH_UNSET_BACKREF)
  const minLength = width(ast, (options & PCRE.MATCH_UNSET_BACKREF) ? undefined : captureMins(ast)).min;
  const nullable = minLength === 0;
  if (internal.analysisOnly) return { minLength, nullable };
  if (codeSize(ast) > SIZE_LIMIT)
    throw new RegexCompileError(ERR.UNTRANSLATABLE, cpByte[cps.length], 'a pattern whose compiled size may exceed PCRE2\'s limit is not supported by the Wasm regex translator');
  const dotstar = utf ? dotstarKind(ast) : null;
  const compileAnchored = (options & PCRE.ANCHORED) !== 0;
  const compileEndAnchored = (options & PCRE.ENDANCHORED) !== 0;
  const globalI = utf && (options & PCRE.CASELESS) !== 0;
  const variants = new Map();
  return {
    utf, ncap: p.ncap, names, nullable, compileAnchored, dotstar,
    // the JS RegExp and group map for the match options `mopts`
    // (`exec` adds the internal flags V_STICKY and V_AFTER_NL)
    variant(mopts) {
      if ((mopts & ~(SUPPORTED_MATCH | V_STICKY | V_AFTER_NL)) !== 0) {
        throw new RegexCompileError(ERR.UNTRANSLATABLE, 0,
          `match options 0x${(mopts & ~SUPPORTED_MATCH >>> 0).toString(16)} are not supported by the Wasm regex translator`);
      }
      const key = mopts & (PCRE.NOTBOL | PCRE.NOTEOL | PCRE.NOTEMPTY | PCRE.NOTEMPTY_ATSTART | PCRE.ANCHORED | PCRE.ENDANCHORED | V_STICKY | V_AFTER_NL);
      let v = variants.get(key);
      if (v) return v;
      const anchored = compileAnchored || (mopts & (PCRE.ANCHORED | V_STICKY)) !== 0;
      const endAnchored = compileEndAnchored || (mopts & PCRE.ENDANCHORED) !== 0;
      const nonEmpty = (mopts & (PCRE.NOTEMPTY | PCRE.NOTEMPTY_ATSTART)) !== 0;
      const em = new Emitter(p, mopts, { i: globalI });
      // a non-empty match: the rest of the subject captured where the match starts differs
      // from the rest where it ends
      const restGroup = nonEmpty ? em.newGroup() : 0;
      let body;
      try {
        em.emit(ast, globalI);           // numbers the groups (back references may come first)
        em.js = restGroup;
        body = em.emit(ast, globalI);
      } catch (e) {
        // (the emitter's positions are code points; errors report bytes)
        if (e instanceof RegexCompileError && !e.bytes) { e.offset = cpByte[Math.min(e.offset, cps.length)]; e.bytes = true; }
        throw e;
      }
      body = (mopts & V_AFTER_NL) ? `(?<=\\n)(?:${body})` : `(?:${body})`;
      // (an invalid UTF-8 sequence ends a segment, and PCRE2 takes a segment's end for the end;
      // the position just after an invalid sequence only when the search starts there: `exec`)
      // (PCRE2's interpreter, which runs for the match options ANCHORED and ENDANCHORED, takes a
      // segment's end; its JIT, otherwise, the subject's: `exec`)
      const segmentEnd = utf && (mopts & (PCRE.ANCHORED | PCRE.ENDANCHORED)) !== 0;
      if (endAnchored) body += segmentEnd ? '(?![^\\p{Cs}])' : '$';
      if (nonEmpty) body = `(?=([^]*))${body}(?!(?-i:\\${restGroup}))`;
      const notEmptyAtStartOnly = (mopts & PCRE.NOTEMPTY_ATSTART) !== 0 && (mopts & PCRE.NOTEMPTY) === 0;
      // (non-anchored NOTEMPTY_ATSTART: a sticky non-empty match at the start offset, then `plain`)
      const sticky = anchored || notEmptyAtStartOnly;
      const flags = 'dv' + (sticky ? 'y' : 'g') + (globalI ? 'i' : '');
      let re;
      try { re = new RegExp(body, flags); }
      catch (e) {
        throw new RegexCompileError(ERR.UNTRANSLATABLE, 0, `internal translation error: ${e.message} (source /${body}/${flags})`);
      }
      v = { re, groupMap: em.groupMap, source: body, flags, anchored, notEmptyAtStartOnly, endAnchoredUtf: segmentEnd };
      if (v.notEmptyAtStartOnly && !anchored) {
        // non-anchored NOTEMPTY_ATSTART: a non-empty match at the start offset, else any match
        // from the next character on
        v.plain = this.variant(mopts & ~PCRE.NOTEMPTY_ATSTART);
      }
      variants.set(key, v);
      return v;
    },
  };
}

function firstInvalidUtf8(bytes) {
  let k = 0;
  while (k < bytes.length) {
    const n = utf8SeqLen(bytes, k);
    if (n === 0) return k;
    k += n;
  }
  return bytes.length;
}

// ---------------------------------------------------------------------------------------------
// Subjects: bytes -> JS string, with exact offset maps.

// the length of the valid UTF-8 sequence at `k` (as PCRE2 and Julia's isvalid define it), or 0
function utf8SeqLen(b, k) {
  const c = b[k];
  if (c < 0x80) return 1;
  if (c < 0xc2) return 0;
  if (c < 0xe0) return k + 1 < b.length && (b[k + 1] & 0xc0) === 0x80 ? 2 : 0;
  if (c < 0xf0) {
    if (k + 2 >= b.length) return 0;
    const c1 = b[k + 1];
    if ((c1 & 0xc0) !== 0x80 || (b[k + 2] & 0xc0) !== 0x80) return 0;
    if (c === 0xe0 && c1 < 0xa0) return 0;          // overlong
    if (c === 0xed && c1 >= 0xa0) return 0;         // surrogate
    return 3;
  }
  if (c < 0xf5) {
    if (k + 3 >= b.length) return 0;
    const c1 = b[k + 1];
    if ((c1 & 0xc0) !== 0x80 || (b[k + 2] & 0xc0) !== 0x80 || (b[k + 3] & 0xc0) !== 0x80) return 0;
    if (c === 0xf0 && c1 < 0x90) return 0;          // overlong
    if (c === 0xf4 && c1 >= 0x90) return 0;         // > U+10FFFF
    return 4;
  }
  return 0;
}

/**
 * A subject: its bytes, and per mode its JS string with maps. `u2b[i]` is the byte offset of
 * UTF-16 index i (length+1 entries); `b2u[k]` the UTF-16 index of byte offset k, for k at a
 * character start (else the next one's). Both null for ASCII/byte mode (identity).
 */
export class Subject {
  constructor(bytes) {
    this.bytes = bytes;
    this.utf = null;
    this.latin1 = null;
  }
  static isAscii(b) {
    for (let k = 0; k < b.length; k++) if (b[k] >= 0x80) return false;
    return true;
  }
  forMode(utf) {
    if (utf) return this.utf ??= decodeUtf8(this.bytes);
    return this.latin1 ??= { str: latin1(this.bytes), u2b: null, b2u: null, segStarts: null, invalid: false };
  }
}

function latin1(b) {
  let s = '';
  for (let k = 0; k < b.length; k += 0x8000) s += String.fromCharCode.apply(null, b.subarray(k, k + 0x8000));
  return s;
}

export function decodeUtf8(b) {
  if (Subject.isAscii(b)) return { str: latin1(b), u2b: null, b2u: null, segStarts: null, invalid: false };
  const units = new Uint16Array(b.length);   // UTF-16 never needs more units than UTF-8 bytes
  const u2b = new Uint32Array(b.length + 1);
  const b2u = new Uint32Array(b.length + 1);
  const segStarts = [];                       // UTF-16 indices just past a run of invalid bytes
  let invalid = false;
  let u = 0, k = 0;
  while (k < b.length) {
    const n = utf8SeqLen(b, k);
    b2u[k] = u;
    if (n === 0) {
      invalid = true;
      u2b[u] = k;
      units[u++] = 0xdc00 | b[k];       // an invalid byte: a lone low surrogate
      k += 1;
      if (k < b.length && utf8SeqLen(b, k) !== 0) segStarts.push(u);
      continue;
    }
    let cp;
    if (n === 1) cp = b[k];
    else if (n === 2) cp = ((b[k] & 0x1f) << 6) | (b[k + 1] & 0x3f);
    else if (n === 3) cp = ((b[k] & 0x0f) << 12) | ((b[k + 1] & 0x3f) << 6) | (b[k + 2] & 0x3f);
    else cp = ((b[k] & 0x07) << 18) | ((b[k + 1] & 0x3f) << 12) | ((b[k + 2] & 0x3f) << 6) | (b[k + 3] & 0x3f);
    if (cp < 0x10000) {
      u2b[u] = k;
      units[u++] = cp;
    } else {
      cp -= 0x10000;
      u2b[u] = k; units[u++] = 0xd800 | (cp >> 10);
      u2b[u] = k; units[u++] = 0xdc00 | (cp & 0x3ff);
    }
    // an offset inside a character starts at the next one
    for (let j = 1; j < n; j++) b2u[k + j] = u;
    k += n;
  }
  u2b[u] = b.length;
  b2u[b.length] = u;
  let str = '';
  for (let j = 0; j < u; j += 0x8000) str += String.fromCharCode.apply(null, units.subarray(j, Math.min(u, j + 0x8000)));
  return { str, u2b: u2b.subarray(0, u + 1), b2u, segStarts, invalid };
}

/**
 * exec(compiled, subject, startByte, mopts) -> null (no match) or Int32Array/array of
 * 2*(ncap+1) byte offsets (-1 = unset). Throws RegexCompileError for unsupported options and
 * RangeError for a bad offset.
 */
export function exec(compiled, subject, startByte, mopts) {
  const s = subject.forMode(compiled.utf);
  if (startByte < 0 || startByte > subject.bytes.length) throw new RangeError('bad offset');
  // Where empty matches can be on a subject with invalid UTF-8 depends on details of PCRE2's
  // JIT (where it starts and resumes around invalid bytes) the host doesn't reproduce; a pattern
  // that can't match the empty string only matches valid characters, where the host is exact
  // (investigation.md §3). The other case fails loudly.
  if (s.invalid && compiled.nullable) {
    throw new RegexCompileError(ERR.UNTRANSLATABLE, 0,
      'matching a pattern that can match an empty string against a string that is not valid UTF-8 is not supported by the Wasm regex host');
  }
  const orig = s.b2u ? s.b2u[startByte] : startByte;
  // PCRE2 (its JIT, as Julia runs it) never starts a match on a continuation byte of an invalid
  // sequence: it moves past them first, also when anchored. NOTEMPTY_ATSTART concerns the
  // caller's start offset only.
  // These are the rules of PCRE2's interpreter, which pcre2_match uses for the match options
  // ANCHORED and ENDANCHORED (its JIT doesn't support them); otherwise the JIT runs, and a
  // pattern anchored at compile time is anchored at the start offset as given, never retried
  if ((mopts & (V_STICKY | V_AFTER_NL)) !== 0) {
    throw new RegexCompileError(ERR.UNTRANSLATABLE, 0, `match options 0x${(mopts >>> 0).toString(16)} are not supported by the Wasm regex host`);
  }
  const interpreter = (mopts & (PCRE.ANCHORED | PCRE.ENDANCHORED)) !== 0;
  // a pattern PCRE2 anchors itself (a leading DOTALL `.*`) is anchored like one compiled
  // with PCRE2_ANCHORED; one starting with `.*` only starts at the start offset and after a
  // newline (`dotstarKind`; observable only around invalid bytes)
  const ds = s.invalid ? compiled.dotstar : null;
  const start = (compiled.compileAnchored || ds === 'anchored') && !interpreter ? orig : advance(s, orig);
  if (start !== orig) mopts &= ~PCRE.NOTEMPTY_ATSTART;
  if (ds === 'anchored') mopts |= V_STICKY;
  const v = compiled.variant(mopts);
  // ENDANCHORED: an empty match just after an invalid byte counts only where the search starts
  const accept = (w, m) => !(w.endAnchoredUtf && s.invalid && m[0].length === 0 && m.index !== start && afterInvalid(s, m.index));
  const search = (w, from) => {
    let m = run(w.re, s, from);
    while (m !== null && !accept(w, m)) m = w.re.sticky ? null : run(w.re, s, advance(s, nextPos(s, m.index)));
    return m;
  };
  if (ds === 'startline' && !compiled.compileAnchored && (mopts & PCRE.ANCHORED) === 0) {
    // (the attempt at the start offset is made there, also on an invalid continuation byte)
    const w0 = compiled.variant(mopts | V_STICKY);
    let m = search(w0, orig);
    if (m) return ovector(m, compiled, w0, s);
    if (orig >= s.str.length) return null;
    const w = compiled.variant((mopts & ~PCRE.NOTEMPTY_ATSTART) | V_AFTER_NL);
    m = search(w, advance(s, nextPos(s, orig)));
    return m === null ? null : ovector(m, compiled, w, s);
  }
  let m = search(v, start);
  if (m === null && v.anchored && interpreter && s.segStarts && s.segStarts.length) {
    // PCRE2_MATCH_INVALID_UTF: an anchored match is tried again at the start of every valid
    // segment after the start offset
    const w = compiled.variant(mopts & ~PCRE.NOTEMPTY_ATSTART);
    for (const seg of s.segStarts) {
      if (seg <= start) continue;
      m = search(w, seg);
      if (m) return ovector(m, compiled, w, s);
    }
    return null;
  }
  if (m === null && v.plain) {
    // NOTEMPTY_ATSTART, not anchored: then any match from the next character on
    if (start < s.str.length) {
      m = search(v.plain, advance(s, nextPos(s, start)));
      if (m) return ovector(m, compiled, v.plain, s);
    }
    return null;
  }
  return m === null ? null : ovector(m, compiled, v, s);
}

// whether index `i` holds an invalid continuation byte (0x80-0xBF: a lone U+DC80-U+DCBF)
const isInvalidCont = (s, i) => {
  if (!s.invalid || i >= s.str.length) return false;
  const u = s.str.charCodeAt(i);
  return u >= 0xdc80 && u <= 0xdcbf && !(i > 0 && (s.str.charCodeAt(i - 1) & 0xfc00) === 0xd800);
};
// `i`, moved past invalid continuation bytes
function advance(s, i) {
  while (isInvalidCont(s, i)) i++;
  return i;
}

// V8 (13.6) may try a position between the halves of a surrogate pair in a non-sticky search,
// where lookarounds see a lone surrogate: such a match is not one; the search goes on after it.
// Nor does a match start on an invalid continuation byte (see `exec`).
function run(re, s, start) {
  const str = s.str;
  re.lastIndex = start;
  for (;;) {
    const m = re.exec(str);
    if (m === null) return null;
    const i = m.index;
    if (isInvalidCont(s, i)) {
      if (re.sticky) return null;
      re.lastIndex = advance(s, i);
      continue;
    }
    const mid = i > 0 && i < str.length && (str.charCodeAt(i - 1) & 0xfc00) === 0xd800 && (str.charCodeAt(i) & 0xfc00) === 0xdc00;
    if (!mid) return m;
    re.lastIndex = i + 1;
  }
}

// whether index `i` is just after an invalid byte (a lone low surrogate, not a pair's half)
const afterInvalid = (s, i) => i > 0 && (s.str.charCodeAt(i - 1) & 0xfc00) === 0xdc00 &&
  !(i > 1 && (s.str.charCodeAt(i - 2) & 0xfc00) === 0xd800);

// the index after the character (or invalid byte) at `i`
const nextPos = (s, i) => i + (s.str.codePointAt(i) > 0xffff ? 2 : 1);

function ovector(m, compiled, v, s) {
  const out = new Array(2 * (compiled.ncap + 1)).fill(-1);
  const toByte = (u) => (s.u2b ? s.u2b[u] : u);
  const [a, b] = m.indices[0];
  out[0] = toByte(a); out[1] = toByte(b);
  for (let g = 1; g <= compiled.ncap; g++) {
    const ix = m.indices[v.groupMap[g]];
    if (ix) { out[2 * g] = toByte(ix[0]); out[2 * g + 1] = toByte(ix[1]); }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// The import namespace

/**
 * makeJuliaRegex() -> { imports, bindMemory(memory), stats }
 *
 * Imports (all scalar i32; offsets/lengths into memory 0):
 *   compile(pat_off, pat_len, options, out_off, out_cap) -> handle | -errno
 *   subject(off, len, append) -> 0 | errno
 *   match(h, start, mopts, out_off, out_cap) -> rc | -errno
 *   free(h) -> 0 | errno
 *   errmsg(out_off, cap) -> len
 * The records: see the header of this file.
 */
export function makeJuliaRegex() {
  let memory = null;
  const handles = new Map();     // h -> { compiled, key, refs }
  const byKey = new Map();       // `${options}:${pattern}` -> h
  let nextHandle = 0;
  let staged = null;             // chunks of a subject being staged, or null
  let current = new Subject(new Uint8Array(0));
  let lastError = '';
  const stats = { compiles: 0, cacheHits: 0, matches: 0, subjectBytes: 0, decodeReuse: 0 };

  const u8 = () => new Uint8Array(memory.buffer);
  const dv = () => new DataView(memory.buffer);
  const enc = new TextEncoder();

  // unexpected exceptions: -EIO from handle/count imports, EIO from status imports
  const guard = (f, status = false) => (...args) => {
    try { return f(...args); }
    catch (e) { lastError = String(e?.stack ?? e); return status ? E.IO : -E.IO; }
  };

  function writeRecord(off, cap, fields) {
    // fields: array of u32 numbers or Uint8Array strings (u32 length + bytes)
    let n = 0;
    for (const f of fields) n += typeof f === 'number' ? 4 : 4 + f.length;
    const view = dv();
    if (cap < n) {
      if (cap >= 4) view.setUint32(off, n, true);
      return -E.NOBUFS;
    }
    const mem = u8();
    let p = off;
    for (const f of fields) {
      if (typeof f === 'number') { view.setUint32(p, f >>> 0, true); p += 4; }
      else { view.setUint32(p, f.length, true); mem.set(f, p + 4); p += 4 + f.length; }
    }
    return n;
  }

  const imports = {
    compile: guard((patOff, patLen, options, outOff, outCap) => {
      options >>>= 0;
      if (outCap < 4) return -E.INVAL;
      const pat = u8().slice(patOff, patOff + patLen);
      const key = `${options}:${Buffer.from(pat).toString('latin1')}`;
      let h = byKey.get(key);
      if (h !== undefined) {
        const e = handles.get(h);
        const r = writeRecord(outOff, outCap, infoFields(e.compiled));
        if (r < 0) return r;
        e.refs++;
        stats.cacheHits++;
        return h;
      }
      let compiled;
      try { compiled = translate(pat, options); compiled.variant(0); }
      catch (e) {
        if (!(e instanceof RegexCompileError)) throw e;
        lastError = e.message;
        const r = writeRecord(outOff, outCap, [e.code, e.offset, enc.encode(e.message)]);
        return r < 0 ? r : -E.INVAL;
      }
      const r = writeRecord(outOff, outCap, infoFields(compiled));
      if (r < 0) return r;
      h = nextHandle++;
      handles.set(h, { compiled, key, refs: 1 });
      byKey.set(key, h);
      stats.compiles++;
      return h;
    }),
    subject: guard((off, len, append) => {
      const chunk = u8().slice(off, off + len);
      if (!append || staged === null) staged = [];
      staged.push(chunk);
      return 0;
    }, true),
    match: guard((h, start, mopts, outOff, outCap) => {
      const e = handles.get(h);
      if (!e) return -E.BADF;
      const c = e.compiled;
      if (outCap < 4) return -E.INVAL;
      if (outCap < 8 * (c.ncap + 1)) { dv().setUint32(outOff, 8 * (c.ncap + 1), true); return -E.NOBUFS; }
      if (staged !== null) {
        // the staged subject becomes current (its decoding is kept if the bytes are the same)
        const total = staged.reduce((n, p) => n + p.length, 0);
        let bytes;
        if (staged.length === 1) bytes = staged[0];
        else { bytes = new Uint8Array(total); let p = 0; for (const x of staged) { bytes.set(x, p); p += x.length; } }
        if (Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length).equals(
          Buffer.from(current.bytes.buffer, current.bytes.byteOffset, current.bytes.length))) stats.decodeReuse++;
        else current = new Subject(bytes);
        stats.subjectBytes += total;
        staged = null;
      }
      stats.matches++;
      let ov;
      try { ov = exec(c, current, start >>> 0, mopts >>> 0); }
      catch (err) {
        if (err instanceof RangeError) { lastError = 'bad offset into the subject'; return -E.INVAL; }
        if (err instanceof RegexCompileError) { lastError = err.message; return -E.NOTSUP; }
        throw err;
      }
      if (ov === null) return 0;
      const view = dv();
      let rc = 1;
      for (let g = 0; g <= c.ncap; g++) {
        const a = ov[2 * g], b = ov[2 * g + 1];
        view.setUint32(outOff + 8 * g, a < 0 ? 0xffffffff : a, true);
        view.setUint32(outOff + 8 * g + 4, b < 0 ? 0xffffffff : b, true);
        if (a >= 0) rc = g + 1;
      }
      return rc;
    }),
    free: guard((h) => {
      const e = handles.get(h);
      if (!e) return E.BADF;
      if (--e.refs === 0) { handles.delete(h); byKey.delete(e.key); }
      return 0;
    }, true),
    errmsg: guard((outOff, cap) => {
      const b = enc.encode(lastError);
      const n = Math.min(b.length, Math.max(cap, 0));
      u8().set(b.subarray(0, n), outOff);
      return n;
    }),
  };
  return {
    imports,
    bindMemory(m) { memory = m; },
    stats,
    handles,
  };
}

function infoFields(c) {
  const enc = new TextEncoder();
  const f = [c.ncap, c.names.length];
  for (const [name, group] of c.names) { f.push(group); f.push(enc.encode(name)); }
  return f;
}
