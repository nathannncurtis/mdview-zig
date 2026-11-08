import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const [inp, out] = process.argv.slice(2);
const cases = JSON.parse(readFileSync(inp, 'utf8'));
const res = [];
for (const c of cases) {
  const github = execFileSync('gh', ['api', '-X', 'POST', 'markdown', '-f', `text=${c.md}`, '-f', 'mode=markdown'], { encoding: 'utf8', maxBuffer: 1 << 24 });
  res.push({ n: c.n, section: c.section, md: c.md, html: c.html, github });
}
writeFileSync(out, '[\n' + res.map((r) => JSON.stringify(r)).join(',\n') + '\n]\n');
console.log(res.length);
