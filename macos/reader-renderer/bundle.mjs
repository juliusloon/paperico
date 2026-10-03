import {rolldown} from 'rolldown';
import {fileURLToPath} from 'node:url';
import {readFile, writeFile, copyFile, readdir, mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, join} from 'node:path';
const require = createRequire(import.meta.url);
const resource = fileURLToPath(new URL('../Paperico/Resources/Reader/', import.meta.url));
const bundle = await rolldown({input:fileURLToPath(new URL('./reader.mjs',import.meta.url))});
const output = await bundle.write({file:join(resource,'reader.js'),format:'iife',minify:true});
await bundle.close();
const katex = dirname(require.resolve('katex/package.json'));
await copyFile(join(katex,'dist/katex.min.css'),join(resource,'katex.min.css'));
await copyFile(join(katex,'LICENSE'),join(resource,'KaTeX-LICENSE.txt'));
await mkdir(join(resource,'fonts'),{recursive:true});
for (const name of await readdir(join(katex,'dist/fonts'))) {
  if (name.endsWith('.woff2')) await copyFile(join(katex,'dist/fonts',name),join(resource,'fonts',name));
}
// Retain notices for exactly the packages included in the generated browser bundle.
const roots = new Set();
for (const chunk of output.output) for (const id of Object.keys(chunk.modules ?? {})) {
  const match = id.match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//);
  if (match) roots.add(match[1]);
}
const notices = ['Paperico offline reader — third-party notices'];
for (const root of [...roots].sort()) {
  const info = JSON.parse(await readFile(join(root,'package.json'),'utf8'));
  const name = (await readdir(root)).find(x => /^licen[sc]e(?:\.|$)/i.test(x));
  const fallback = ['rehype-katex','remark-math'].includes(info.name)
    ? fileURLToPath(new URL('./licenses/remark-math-MIT.txt',import.meta.url)) : null;
  if (!name && !fallback) throw new Error(`Missing license for ${info.name}`);
  notices.push(`\n${info.name} ${info.version}\n${await readFile(name ? join(root,name) : fallback,'utf8')}`);
}
await writeFile(join(resource,'THIRD-PARTY-NOTICES.txt'),notices.join('\n'));
