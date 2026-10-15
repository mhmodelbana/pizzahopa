import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
import { spawnSync } from 'node:child_process';

const files = ['index.html', 'admin.html'];
let failed = false;
for (const file of files) {
  const html = readFileSync(resolve(root, file), 'utf8');
  const scripts = [...html.matchAll(/<script\b(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)<\/script\s*>/gi)];
  for (let i = 0; i < scripts.length; i++) {
    const temp = join(tmpdir(), `hopa-${file.replace(/\W/g, '-')}-${i}.js`);
    writeFileSync(temp, scripts[i][1]);
    const result = spawnSync(process.execPath, ['--check', temp], { encoding: 'utf8' });
    rmSync(temp, { force: true });
    if (result.status !== 0) {
      failed = true;
      console.error(`Syntax error in ${file}, inline script ${i + 1}:\n${result.stderr}`);
    }
  }
  console.log(`${file}: checked ${scripts.length} inline script(s).`);
}
if (failed) process.exit(1);
console.log('Inline JavaScript syntax checks passed.');
