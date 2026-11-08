# jison fixtures

Reference data for `tools/gen_jison.zig`, `src/mermaid/jison/runtime.zig` and `src/mermaid/jison/regex.zig`.
Everything here was made once with Node in a scratch folder; no JavaScript is committed.

Pinned versions: mermaid 11.16.1, jison 0.4.18 (jison-lex 0.3.4, lex-parser 0.1.4, ebnf-parser 0.1.10).

| File | What it is |
|---|---|
| `flow.jison`, `sequenceDiagram.jison` | The upstream grammars from the `mermaid@11.16.1` tag (`packages/mermaid/src/diagrams/flowchart/parser/flow.jison`, `.../sequence/parser/sequenceDiagram.jison`). MIT licence, (c) Knut Sveidqvist. |
| `expr.jison`, `dangling.jison` | Small grammars written for this repo that hit every conflict rule: `%left`, `%right`, `%prec`, shift/reduce by default and reduce/reduce. |
| `*.tables.json` | The symbol table, productions, parse table, default actions, lexer rule regexes and start conditions jison 0.4.18 builds for each grammar. `zig build test` runs `gen-jison check` on each pair and fails on the first differing line. |
| `errors_flow.json`, `errors_sequence.json` | The exact text of the `Error` that `mermaid.parse()` throws for broken input (and `null` for accepted input). The parity test feeds `input + "\n"` to the generated parser and compares byte for byte. |
| `regex_cases.json` | For every lexer pattern of the two grammars, the grammar-file scanners and extra edge patterns: a hash of the match length JavaScript's `RegExp` gives at every offset of five texts. |

## Reproducing

Tables, from a folder with `npm i jison@0.4.18`. The script loads `new jison.Generator(grammarText, { moduleType: 'js' })`, records the `new RegExp("^(?:...)")` source strings jison-lex builds, and writes `symbols_`, `terminals_`, `productions_`, `table`, `defaultActions`, `lexer.conditions` in the layout `gen-jison check` writes (one JSON array per state).

The tables mermaid 11.16.1 ships in `dist/chunks/mermaid.core/chunk-JQJVKLGR.mjs` (flowchart) and `sequenceDiagram-SI44F4Z6.mjs` are identical to these (`m.diagram.parser.parser.table`).

Error strings, from a folder with `npm i mermaid@11.16.1 jsdom`:

```js
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!DOCTYPE html><body></body>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false });
try { await mermaid.parse(input); message = null; } catch (e) { message = e.message; }
```

Mermaid hands the parser `input + "\n"` (`Diagram.fromText`). Inputs that mermaid rewrites first (`%%` comment lines, entities) were left out; a case is kept only when the jison parser alone, run on `input + "\n"`, gives the same string as `mermaid.parse(input)`.
Strings with lone surrogates are written with `toWellFormed()`.

Regex hashes: for each pattern, `re = new RegExp("^(?:" + pattern + ")", flags)`, then for every offset `o` of a text, `re.exec(text.slice(o))` gives a match length or none; the values (`length + 1`, or 0) are folded with FNV-1a (32 bit, `h = imul(h ^ v, 16777619)`) per text and the texts folded with `h = imul(h, 31) + hash`.

Other grammars: the same check was run in scratch on all 19 `.jison` files of the 11.16.1 tag and every one produced identical tables.
