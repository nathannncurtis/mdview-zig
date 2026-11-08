# Math TeX test data

- `corpus.txt`: one TeX expression per line (the constructs from the GitHub frequency survey, the GitHub docs examples, every extension command, and error cases).
- `tex_errors.tsv`: `corpus.txt` run through MathJax 3.2.2; each line is `tex<TAB>error message`, with an empty message when MathJax reports no error. `src/math/tex_test.zig` requires the parser to give the same message for every line.
- `commands.tsv`: every control sequence and environment name in MathJax's maps (base, ams, newcommand, color, boldsymbol and the autoloaded action, amscd, bbox, braket, bussproofs, cancel, enclose, extpfeil, html, mhchem, unicode, verb, require), plus names it rejects (mathtools, physics, KaTeX-only). `accepted` or `rejected` is MathJax's own answer; the parser must agree for every row.
- `trees.tsv`: reviewed parse trees (`tex<TAB>tree dump`) for the common constructs, a regression pin for `src/math/parser.zig`.

## Reference data

Made outside the repo with Node and `mathjax-full` 3.2.2 using the tex component's default packages with autoload expanded (`base ams newcommand noundefined color boldsymbol action amscd bbox braket bussproofs cancel enclose extpfeil html mhchem unicode verb require configmacros`) and the CHTML output jax (bussproofs needs `getBBox`). A new TeX instance per line keeps `\newcommand` definitions from leaking between lines. `\require{<package>}` loads files in a browser and throws in Node, so only its error forms are in the corpus.

```
mkdir ref && cd ref && npm init -y && npm i mathjax-full@3.2.2
node mj.js ../corpus.txt ../tex_errors.tsv
node gen_commands.js ../commands.tsv
```

`mj.js` (also add `mhchem` to `cmdMaps` in `gen_commands.js`):

```js
const {mathjax} = require('mathjax-full/js/mathjax.js');
const {TeX} = require('mathjax-full/js/input/tex.js');
const {CHTML} = require('mathjax-full/js/output/chtml.js');
const {liteAdaptor} = require('mathjax-full/js/adaptors/liteAdaptor.js');
const {RegisterHTMLHandler} = require('mathjax-full/js/handlers/html.js');
const {STATE} = require('mathjax-full/js/core/MathItem.js');
const {SerializedMmlVisitor} = require('mathjax-full/js/core/MmlTree/SerializedMmlVisitor.js');
const cfg = {
  base: 'base/BaseConfiguration', ams: 'ams/AmsConfiguration', newcommand: 'newcommand/NewcommandConfiguration',
  noundefined: 'noundefined/NoUndefinedConfiguration', color: 'color/ColorConfiguration', boldsymbol: 'boldsymbol/BoldsymbolConfiguration',
  action: 'action/ActionConfiguration', amscd: 'amscd/AmsCdConfiguration', bbox: 'bbox/BboxConfiguration', braket: 'braket/BraketConfiguration',
  bussproofs: 'bussproofs/BussproofsConfiguration', cancel: 'cancel/CancelConfiguration', enclose: 'enclose/EncloseConfiguration',
  extpfeil: 'extpfeil/ExtpfeilConfiguration', html: 'html/HtmlConfiguration', mhchem: 'mhchem/MhchemConfiguration',
  unicode: 'unicode/UnicodeConfiguration', verb: 'verb/VerbConfiguration', require: 'require/RequireConfiguration',
  configmacros: 'configmacros/ConfigMacrosConfiguration',
};
for (const p of Object.keys(cfg)) require('mathjax-full/js/input/tex/' + cfg[p] + '.js');
RegisterHTMLHandler(liteAdaptor());
const vis = new SerializedMmlVisitor();
exports.convert = (s) => {
  const tex = new TeX({packages: Object.keys(cfg)});
  const doc = mathjax.document('', {InputJax: tex, OutputJax: new CHTML({fontURL: 'x'})});
  return vis.visitTree(doc.convert(s, {display: true, end: STATE.CONVERT}));
};
if (require.main === module) {
  const fs = require('fs');
  const out = [];
  for (const l of fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(l => l.length)) {
    let mml;
    try { mml = exports.convert(l); } catch (e) { continue; }
    const m = /data-mjx-error="([^"]*)"/.exec(mml);
    out.push(l + '\t' + (m ? m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#x27;/g, "'") : ''));
  }
  fs.writeFileSync(process.argv[3], out.join('\n') + '\n');
}
```

`gen_commands.js` reads every key of MathJax's command and environment maps through `MapHandler.getMap`, runs `\name` (and `\begin{name}`) through `convert`, and writes `accepted` unless the output is the red undefined-command text (or, for environments, "Unknown environment").

`src/math/denied.zig` lists the names in the KaTeX-derived tables that MathJax rejects: for each name in `symbols.zig`, `tables.zig` and `macros.zig`, the same red-text check.

Delete `ref/` (with `node_modules`) afterwards.

## mhchem

`src/math/mhchem.zig` is a port of mhchemParser 4.2.1 (Apache License 2.0, copyright Martin Hensel; the notice is `src/math/mhchem-LICENSE`). `src/math/mhchem_tables.zig` holds its regular expressions and state-machine transitions, generated from the npm package by:

```
node gen_mhchem.mjs ../src/math/mhchem_tables.zig
```

```js
import fs from 'fs';
import path from 'path';
import {pathToFileURL} from 'url';

const src = fs.readFileSync('node_modules/mhchemparser/esm/mhchemParser.js', 'utf8');
const tmp = path.resolve('mhchem_export.mjs');
fs.writeFileSync(tmp, src + '\nexport {_mhchemParser};\n');
const {_mhchemParser} = await import(pathToFileURL(tmp).href);
fs.unlinkSync(tmp);

const z = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
let out = '// Generated from mhchemParser 4.2.1 (Copyright (c) 2015-2023 Martin Hensel, Apache License 2.0; see mhchem-LICENSE).\n';
out += '// The transition tables and regular expressions are copied verbatim; see testdata/math/README.md.\n// Do not edit.\n\n';
out += 'const std = @import("std");\n\n';
out += 'pub const Opt = union(enum) { none, str: []const u8, int: i64, flag: bool };\n';
out += 'pub const Act = struct { name: []const u8, opt: Opt = .none };\n';
out += 'pub const Tr = struct { pattern: []const u8, acts: []const Act, next: []const u8 = "", revisit: bool = false, cont: bool = false };\n';
out += 'pub const State = struct { name: []const u8, list: []const Tr };\n';
out += 'pub const Machine = struct { name: []const u8, states: []const State };\n\n';

out += 'pub const patterns = std.StaticStringMap([]const u8).initComptime(.{\n';
for (const [k, v] of Object.entries(_mhchemParser.patterns.patterns)) {
  if (v instanceof RegExp) out += `    .{ ${z(k)}, ${z(v.source)} },\n`;
}
out += '});\n\n';

const opt = (o) => o === undefined ? '.none' : typeof o === 'string' ? `.{ .str = ${z(o)} }` : typeof o === 'number' ? `.{ .int = ${o} }` : `.{ .flag = ${o} }`;
out += 'pub const machines = [_]Machine{\n';
for (const [name, m] of Object.entries(_mhchemParser.stateMachines)) {
  out += `    .{ .name = ${z(name)}, .states = &.{\n`;
  for (const [state, list] of Object.entries(m.transitions)) {
    out += `        .{ .name = ${z(state)}, .list = &.{\n`;
    for (const t of list) {
      const acts = t.task.action_.map(a => `.{ .name = ${z(a.type_)}, .opt = ${opt(a.option)} }`).join(', ');
      out += `            .{ .pattern = ${z(t.pattern)}, .acts = &.{ ${acts} }`;
      if (t.task.nextState !== undefined) out += `, .next = ${z(t.task.nextState)}`;
      if (t.task.revisit) out += ', .revisit = true';
      if (t.task.toContinue) out += ', .cont = true';
      out += ' },\n';
    }
    out += '        } },\n';
  }
  out += '    } },\n';
}
out += '};\n';
fs.writeFileSync(process.argv[2], out);
const fnPats = Object.entries(_mhchemParser.patterns.patterns).filter(([, v]) => typeof v === 'function').map(([k]) => k);
console.log('function patterns:', JSON.stringify(fnPats));
```

`mhchem_corpus.txt` (`type<TAB>input`) is run through the package's own `toTex` to make `mhchem.tsv` (`type<TAB>input<TAB>TeX`, or `!message` for an error), and each input is also wrapped as `\ce{...}` / `\pu{...}` and added to `corpus.txt`:

```
node gen_mhchem_ref.mjs ../mhchem_corpus.txt ../mhchem.tsv wrapped.txt
```

```js
import fs from 'fs';
import path from 'path';
import {pathToFileURL} from 'url';

const {mhchemParser} = await import(pathToFileURL(path.resolve('node_modules/mhchemparser/esm/mhchemParser.js')).href);
const corpus = process.argv[2];
const out = [];
const wrapped = [];
for (const line of fs.readFileSync(corpus, 'utf8').split('\n')) {
  if (!line.length) continue;
  const tab = line.indexOf('\t');
  const type = line.slice(0, tab);
  const input = line.slice(tab + 1);
  let res;
  try {
    res = mhchemParser.toTex(input, type);
  } catch (e) {
    if (Array.isArray(e)) res = '!' + e[1];
    else { console.error('skipped (js error): ' + line + ' ' + e.message); continue; }
  }
  out.push(type + '\t' + input + '\t' + res);
  if (input.trim().length && !/[{}]$/.test(input.trim()) || /^[^{}]*$/.test(input) || true) wrapped.push('\\' + type + '{' + input + '}');
}
fs.writeFileSync(process.argv[3], out.join('\n') + '\n');
fs.writeFileSync(process.argv[4], wrapped.join('\n') + '\n');
console.log(out.length, 'rows');
```

## Regenerating `src/math/symbols.zig`

From KaTeX `src/symbols.ts` (commit 9de4b3de47d33c685a99ce2eee9a643f28ed59bf):

```
curl -o symbols.ts https://raw.githubusercontent.com/KaTeX/KaTeX/9de4b3de47d33c685a99ce2eee9a643f28ed59bf/src/symbols.ts
zig build gen-math-symbols -- symbols.ts src/math/symbols.zig
```
