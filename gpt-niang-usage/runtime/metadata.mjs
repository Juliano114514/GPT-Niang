import fs from 'node:fs';

// Runtime and installer report the version registered in the plugin manifest.
const registered = new URL('../.codex-plugin/plugin.json', import.meta.url);
const manifest = JSON.parse(fs.readFileSync(fs.existsSync(registered) ? registered : new URL('../package.json', import.meta.url), 'utf8').replace(/^\uFEFF/, ''));
export const pluginVersion = manifest.version;
