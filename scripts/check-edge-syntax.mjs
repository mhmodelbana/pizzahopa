import { readFileSync } from 'node:fs';
import ts from 'typescript';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const file = resolve(root, 'supabase/functions/hopa-public-api/index.ts');
const source = readFileSync(file, 'utf8');
const result = ts.transpileModule(source, {
  fileName: file,
  reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
});
const errors = (result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error);
if (errors.length) {
  for (const item of errors) console.error(ts.flattenDiagnosticMessageText(item.messageText, '\n'));
  process.exit(1);
}
console.log('Edge Function TypeScript syntax passed (syntax-only; not a live Supabase deployment test).');
