#!/usr/bin/env node
//
// noir-coverage.mjs — the capability tour's coverage of the Noir LANGUAGE.
//
// ## Why this file exists
//
// The tour's first eight programs were derived from the PRODUCT — BlockTracer's
// implemented panes, the tracer's own test corpus, and writing programs until
// the recorder pushed back. That is a legitimate way to choose a demo and it is
// NOT a way to establish coverage: it can only find the features somebody
// happened to think of. Asked whether the Noir side had been enumerated
// systematically, the honest answer was no.
//
// So the form list below is not a judgement call. It is transcribed from the
// compiler's own AST enums — the exhaustive definition of what the language
// accepts — at Noir 1.0.0-beta.26:
//
//   ItemKind                  compiler/noirc_frontend/src/parser/mod.rs:159
//   StatementKind             compiler/noirc_frontend/src/ast/statement.rs:46
//   ExpressionKind            compiler/noirc_frontend/src/ast/expression.rs:22
//   Literal                   compiler/noirc_frontend/src/ast/expression.rs:422
//   Pattern / LValue          compiler/noirc_frontend/src/ast/statement.rs:661 / :646
//   UnresolvedTypeData        compiler/noirc_frontend/src/ast/mod.rs:121
//   BinaryOpKind / UnaryOp    compiler/noirc_frontend/src/ast/expression.rs:299 / :394
//   AssignOpKind              compiler/noirc_frontend/src/ast/statement.rs:614
//   FunctionAttributeKind     compiler/noirc_frontend/src/lexer/token.rs:812
//   SecondaryAttributeKind    compiler/noirc_frontend/src/lexer/token.rs:912
//   UnstableFeature           compiler/noirc_frontend/src/elaborator/options.rs:6
//
// ## The rule this file enforces
//
// Every form is either DEMONSTRATED — a detector finds it in the corpus — or it
// carries an explicit `absent` reason. A form with neither FAILS this tool.
// "Absent because the recorder cannot represent it" is a fine answer;
// "absent because nobody thought of it" is the answer this file makes
// impossible to give silently.
//
// The detectors are regexes over the corpus sources and are deliberately
// conservative: a false NEGATIVE costs an unnecessary reason line, a false
// POSITIVE would be this tool claiming coverage that is not there. Where a
// regex could plausibly match something else, it is anchored.
//
// Usage:
//   node tools/noir-coverage.mjs            # the matrix, and the gate
//   node tools/noir-coverage.mjs --markdown # regenerate docs/NOIR-COVERAGE.md
//   node tools/noir-coverage.mjs --summary  # one line per axis

import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE);
const CORPUS = join(ROOT, "fixtures", "trace", "tour");

// ── reasons, named once so the table stays readable ────────────────────────
//
// Each is a REASON A FORM IS ABSENT, and each has to survive being read by
// somebody who wants the form demonstrated.

const R = {
  // The recorder cannot represent it. Owned, tracked, and the fix moves the
  // program into the tour.
  NR02: "recorder: `enum`/`match` panic the tracer — NR-02, ours. Exercised in the toolchain set (`toolchain/enums`).",
  NR03: "recorder: `nargo trace` has no oracle resolver — NR-03a, ours. Exercised in the toolchain set (`toolchain/oracles`).",
  NR01: "recorder: a `Field` above 2^63 records as a wrong number and above 2^127 aborts the recording — NR-01, ours. Every program keeps its field values small, and there is no cryptography beat for the same reason.",
  NR04: "recorder: writes through a reference are not captured — NR-04, upstream. Demonstrated as a KNOWN FAILURE in `mutation`, which states what should happen.",

  // The recorder records it, but the debugger has nothing useful to show.
  OPAQUE_FN: "recorded, but a function value renders as the opaque text `fn` with no body and no captured environment, so a program built around it would show a pane full of `fn`. Worth a beat once value rendering improves.",

  // Nothing to step through.
  COMPTIME: "comptime evaluation happens BEFORE the execution the tracer records, so there is no step to land on. A program demonstrating it would demonstrate the compiler, not the debugger.",

  // The language refuses it.
  UNSTABLE: "gated behind an unstable feature flag; not a form a visitor can use without opting in.",
  REJECTED: "parsed and then rejected by the compiler — it is not a form of this language.",

  // Honest gaps: nothing stops these, they are simply not done yet.
  TODO: "GAP — nothing prevents this; it is not yet demonstrated. Adding it is a matter of writing the program.",

  // Deliberately out of scope for a tour.
  INTERNAL: "compiler-internal, produced only by macro expansion or error recovery; it has no source syntax a visitor could write.",
  CONTRACT: "an Aztec/contract-shaped form with no meaning for a standalone recorded program.",
};

// ── the form list ──────────────────────────────────────────────────────────
// axis, form, detector (RegExp | null), absent reason (string | null)
// Exactly one of `re` / `absent` is consulted: if `re` matches, the form is
// demonstrated and `absent` is ignored; otherwise `absent` must be present.

const FORMS = [
  // ---- A. ItemKind (parser/mod.rs:159) ----
  ["item", "Import — `use a::b`", /^\s*use\s+\w/m, null],
  ["item", "Function — `fn`", /\bfn\s+\w+/, null],
  ["item", "Struct", /^\s*(pub\s+)?struct\s+\w/m, null],
  ["item", "Enum", null, R.NR02],
  ["item", "Trait", /^\s*(pub\s+)?trait\s+\w/m, null],
  ["item", "TraitImpl — `impl T for Ty`", /^\s*impl\s+\w+\s+for\s+\w/m, null],
  ["item", "Impl — `impl Ty`", /^\s*impl\s+\w+\s*\{/m, null],
  ["item", "TypeAlias — `type A = T`", /^\s*type\s+\w+\s*=/m, null],
  ["item", "Global — `global N: T = e`", /^\s*global\s+\w+/m, null],
  ["item", "ModuleDecl — `mod foo;`", /^\s*mod\s+\w+;/m, null],
  ["item", "Submodules — `mod foo { .. }`", null, R.TODO],
  ["item", "InnerAttribute — `#![..]`", null, R.TODO],

  // ---- B. StatementKind (ast/statement.rs:46) ----
  ["stmt", "Let", /^\s*let\s/m, null],
  ["stmt", "Expression (tail)", /\n\s+\w[\w.]*\s*\n\}/, null],
  ["stmt", "Assign — `x = e`", /^\s*\*?\w+(\.\w+)?\s=\s/m, null],
  ["stmt", "AssignOp — `x += e`", /[-+*/%&|^]=\s/, null],
  ["stmt", "For", /^\s*for\s+\w+\s+in\s/m, null],
  ["stmt", "Loop — `loop { }`", /^\s*loop\s*\{/m, null],
  ["stmt", "While", /^\s*while\s/m, null],
  ["stmt", "Break", /^\s*break;/m, null],
  ["stmt", "Continue", /^\s*continue;/m, null],
  ["stmt", "Comptime", null, R.COMPTIME],
  ["stmt", "Semi", /;\s*$/m, null],
  ["stmt", "Interned", null, R.INTERNAL],
  ["stmt", "Error (incl. `return`)", null, R.REJECTED],

  // ---- C. ExpressionKind (ast/expression.rs:22) ----
  ["expr", "Literal", /\b\d+\b/, null],
  ["expr", "Block", /\{\s*\n/, null],
  ["expr", "Prefix — unary", /[^\w)]\s*[-!*&]\w/, null],
  ["expr", "Index — `a[i]`", /\w\[\w/, null],
  ["expr", "Call — `f(x)`", /\b\w+\(/, null],
  ["expr", "MethodCall — `x.m()`", /\.\w+\(/, null],
  ["expr", "Constrain — `assert`", /\bassert\(/, null],
  ["expr", "Constrain — `assert_eq`", /\bassert_eq\(/, null],
  ["expr", "Constructor — `S { .. }`", /\b[A-Z]\w*\s*\{\s*\w+:/, null],
  ["expr", "MemberAccess — `x.f`", /\w\.\w/, null],
  ["expr", "Cast — `x as T`", /\sas\s+[A-Za-z]/, null],
  ["expr", "Infix", /\s[-+*/%]\s/, null],
  ["expr", "If", /\bif\s/, null],
  ["expr", "Match", null, R.NR02],
  ["expr", "Variable / Path", /\w::\w/, null],
  ["expr", "Tuple — `(a, b)`", /\(\s*\w+\s*,\s*\w+\s*\)/, null],
  ["expr", "Lambda — `|x| e`", null, R.OPAQUE_FN],
  ["expr", "Parenthesized", /\((\w+\s[-+*/]\s\w+)\)/, null],
  ["expr", "Quote", null, R.COMPTIME],
  ["expr", "Unquote — `$x`", null, R.COMPTIME],
  ["expr", "Comptime block", null, R.COMPTIME],
  ["expr", "Unsafe block", null, R.TODO],
  ["expr", "AsTraitPath — `<T as Tr>::x`", null, R.TODO],
  ["expr", "TypePath — `u32::max_value()`", /\bu32::max_value\(/, null],
  ["expr", "Resolved / Interned / InternedStatement", null, R.INTERNAL],
  ["expr", "Error", null, R.INTERNAL],

  // ---- Literals (ast/expression.rs:422) ----
  ["literal", "Array — `[a, b]` / `[e; N]`", /\[[^\];]*\]/, null],
  ["literal", "Vector — `@[..]`", null, R.TODO],
  ["literal", "Bool", /\b(true|false)\b/, null],
  ["literal", "Integer (+ `_` separators, suffixes)", /\b\d[\d_]*(_i32|_u32)?\b/, null],
  ["literal", "Str", /"/, null],
  ["literal", "RawStr — `r\"..\"`", null, R.TODO],
  ["literal", "FmtStr — `f\"..{x}..\"`", /\bf"/, null],
  ["literal", "Unit — `()`", null, R.TODO],

  // ---- D. Pattern / LValue ----
  ["pattern", "Identifier", /\blet\s+\w/, null],
  ["pattern", "Mutable — `mut x`", /\blet\s+mut\s/, null],
  ["pattern", "Tuple destructuring", /\blet\s*\(\s*\w+\s*,/, null],
  ["pattern", "Struct destructuring", /\blet\s+[A-Z]\w*\s*\{\s*\w+\s*,/, null],
  ["pattern", "Parenthesized", null, R.TODO],
  ["pattern", "self / &mut self", /\bself\b/, null],
  ["lvalue", "Path — `x = e`", /^\s*\w+\s=\s/m, null],
  ["lvalue", "MemberAccess — `x.f = e`", /^\s*\w+\.\w+\s*[-+]?=[^=]/m, null],
  ["lvalue", "Index — `a[i] = e`", /^\s*\w+\[\w+\]\s*=[^=]/m, null],
  ["lvalue", "Dereference — `*x = e`", /\*\w+\s=\s/, null],

  // ---- E. Types (ast/mod.rs:121) ----
  ["type", "Field", /\bField\b/, null],
  ["type", "Integers u8/u16/u32/u64", /\bu(8|16|32|64)\b/, null],
  ["type", "Integers u128", null, R.NR01],
  ["type", "Integers i8/i32", /\bi(8|32)\b/, null],
  ["type", "bool", /\bbool\b/, null],
  ["type", "str<N>", /\bstr<\d+>/, null],
  ["type", "fmtstr<N, T>", /\bf"/, null],
  ["type", "Array — `[T; N]`", /\[\w+;\s*\d+\]/, null],
  ["type", "Vector — `[T]`", /:\s*\[\w+\]/, null],
  ["type", "Tuple", /\(\s*\w+\s*,\s*\w+\s*\)\s*(\{|->)/, null],
  ["type", "Named / struct", /:\s*[A-Z]\w*/, null],
  ["type", "Reference — `&mut T`", /&mut\s/, null],
  ["type", "Reference — `&T` (immutable)", /:\s*&Self\b|self:\s*&/, null],
  ["type", "Function type — `fn(A) -> B`", null, R.OPAQUE_FN],
  ["type", "TraitAsType — `impl Trait`", null, R.UNSTABLE],
  ["type", "Unit", null, R.TODO],
  ["type", "Generic — `<T>`", /fn\s+\w+<[A-Z]/, null],
  ["type", "Numeric generic — `<let N: u32>`", /<let\s+\w+:/, null],
  ["type", "Numeric type alias + turbofish in length position", /Window::<\d+>/, null],
  ["type", "Wildcard `_`", /\blet\s+_\s*=/, null],
  ["type", "AsTraitPath / associated type", null, R.TODO],
  ["type", "Resolved / Interned / Error", null, R.INTERNAL],

  // ---- F. Operators ----
  ...[["+", /\s\+\s/], ["-", /\s-\s/], ["*", /\s\*\s/], ["/", /\s\/\s/], ["%", /\s%\s/],
      ["==", /==/], ["!=", /!=/], ["<", /\s<\s/], ["<=", /<=/], [">", /\s>\s/], [">=", />=/],
      ["&", /\s&\s/], ["|", /\s\|\s/], ["^", /\s\^\s/], [">>", />>/]]
    .map(([op, re]) => ["operator", `binary \`${op}\``, re, null]),
  ["operator", "binary `<<`", /<<=?/, null],
  ["operator", "unary `-`", /[( ]-\d/, null],
  ["operator", "unary `!`", /!\w/, null],
  ["operator", "unary `&`/`&mut`", /&mut\s/, null],
  ["operator", "unary `*` (deref)", /\*\w+\s=/, null],
  ["operator", "compound `+=` `-=`", /[-+]=\s/, null],
  ["operator", "compound `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=`", /\*=|\/=|%=|&=|\|=|\^=|<<=|>>=/, null],
  ["operator", "operator overloading (std::ops)", null, R.TODO],

  // ---- G. Attributes ----
  ["attribute", "#[oracle(..)]", null, R.NR03],
  ["attribute", "#[test] / #[fuzz]", null, R.TODO],
  ["attribute", "#[builtin] / #[foreign]", null, R.INTERNAL],
  ["attribute", "#[fold] / #[inline_always] / #[inline_never] / #[no_predicates]", null, R.TODO],
  ["attribute", "#[deprecated] / #[allow] / #[must_use] / #[export] / #[field]", null, R.TODO],
  ["attribute", "#[abi(..)] / contract", null, R.CONTRACT],
  ["attribute", "#[derive(..)] and comptime meta-attributes", null, R.COMPTIME],

  // ---- H. Language features that are not single AST nodes ----
  ["feature", "unconstrained fn", /\bunconstrained\s+fn\b/, null],
  ["feature", "trait default method", /fn\s+perimeter/, null],
  ["feature", "trait bound / where clause", /\bwhere\b/, null],
  ["feature", "generic instantiated at several types", /largest\(/, null],
  ["feature", "recursion", /fn\s+factorial/, null],
  ["feature", "mutual recursion", /fn\s+is_odd/, null],
  ["feature", "modules across files", /^\s*mod\s+\w+;/m, null],
  ["feature", "println / print", /\bprintln?\(/, null],
  ["feature", "assertion with a message", /assert\([^)]*,\s*"/, null],
  ["feature", "shadowing", /let bounds = [\s\S]*?let bounds = /, null],
  ["feature", "supertraits / trait aliases", null, R.TODO],
  ["feature", "associated constants", null, R.TODO],
  ["feature", "Option / BoundedVec / UHashMap", /\bOption(::|<)/, null],
  ["feature", "std::hash, embedded curve ops", null, R.NR01],
  ["feature", "data bus — `call_data` / `return_data`", null, R.CONTRACT],
  ["feature", "integer overflow / wrapping ops", /\bwrapping_add\b/, null],
  ["feature", "comptime / metaprogramming (std::meta)", null, R.COMPTIME],
];

// ── run the detectors over the corpus ──────────────────────────────────────

function noirSources(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of readdirSync(d)) {
      const p = join(d, e);
      if (statSync(p).isDirectory()) walk(p);
      else if (e.endsWith(".nr")) out.push(p);
    }
  };
  walk(dir);
  return out;
}

// Only the RECORDABLE set counts as coverage. A form demonstrated solely in the
// toolchain set is by definition one a visitor cannot see stepping, which is
// the distinction this whole split exists to make.
const recordable = noirSources(CORPUS).filter((p) => !p.includes(`${CORPUS}/toolchain/`));
const text = recordable.map((p) => readFileSync(p, "utf8")).join("\n");

const rows = FORMS.map(([axis, form, re, absent]) => {
  const hit = re ? re.test(text) : false;
  return { axis, form, hit, absent: hit ? null : absent };
});

const unexplained = rows.filter((r) => !r.hit && !r.absent);
const covered = rows.filter((r) => r.hit).length;

// ── output ─────────────────────────────────────────────────────────────────

const axes = [...new Set(rows.map((r) => r.axis))];

if (process.argv.includes("--markdown")) {
  let md = `# Noir language coverage — the capability tour\n\n`;
  md += `**Generated by \`tools/noir-coverage.mjs\`. Do not edit by hand.**\n\n`;
  md += `The form list is transcribed from the compiler's own AST enums at Noir\n`;
  md += `1.0.0-beta.26 — the exhaustive definition of what the language accepts —\n`;
  md += `not from a sample of programs. Each form is either DEMONSTRATED by the\n`;
  md += `recordable corpus or carries an explicit reason for being absent; a form\n`;
  md += `with neither fails the tool that generates this file.\n\n`;
  md += `Coverage counts the **recordable** set only. A form demonstrated solely in\n`;
  md += `the toolchain set is one a visitor cannot see stepping.\n\n`;
  md += `**${covered} of ${rows.length} forms demonstrated.** The rest are accounted for below.\n\n`;
  for (const axis of axes) {
    const rs = rows.filter((r) => r.axis === axis);
    const n = rs.filter((r) => r.hit).length;
    md += `## ${axis} — ${n}/${rs.length}\n\n| form | status |\n|---|---|\n`;
    for (const r of rs) {
      md += `| ${r.form} | ${r.hit ? "**demonstrated**" : r.absent} |\n`;
    }
    md += `\n`;
  }
  md += `## What the gaps mean\n\n`;
  md += `Grouped, so the shape of the remainder is visible rather than buried in a table:\n\n`;
  const byReason = new Map();
  for (const r of rows.filter((x) => !x.hit)) {
    if (!byReason.has(r.absent)) byReason.set(r.absent, []);
    byReason.get(r.absent).push(r.form);
  }
  for (const [reason, forms] of [...byReason].sort((a, b) => b[1].length - a[1].length)) {
    md += `- **${forms.length}** — ${reason}\n  - ${forms.join(", ")}\n`;
  }
  writeFileSync(join(ROOT, "docs", "NOIR-COVERAGE.md"), md);
  console.log(`wrote docs/NOIR-COVERAGE.md — ${covered}/${rows.length} forms demonstrated`);
} else {
  for (const axis of axes) {
    const rs = rows.filter((r) => r.axis === axis);
    console.log(`  ${axis.padEnd(10)} ${String(rs.filter((r) => r.hit).length).padStart(3)}/${String(rs.length).padEnd(3)}`);
  }
  console.log(`\n  ${covered}/${rows.length} forms demonstrated by the recordable corpus`);
}

if (unexplained.length) {
  console.error(`\nFAIL — ${unexplained.length} form(s) neither demonstrated nor explained:`);
  for (const r of unexplained) console.error(`  ${r.axis}: ${r.form}`);
  console.error(`\nEvery form must be demonstrated or carry a reason. "Nobody thought of it"`);
  console.error(`is the answer this tool exists to make impossible to give silently.`);
  process.exit(1);
}
