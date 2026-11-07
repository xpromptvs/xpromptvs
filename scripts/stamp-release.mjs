import {readRelease} from './lib/release-manifest.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
const [mode,...paths]=process.argv.slice(2), release=readRelease();
if(mode==='write')for(const dir of paths)writeFileSync(join(dir,'release.json'),JSON.stringify(release)+'\n');
else if(mode==='verify')for(const dir of paths){if(JSON.stringify(JSON.parse(readFileSync(join(dir,'release.json'),'utf8')))!==JSON.stringify(release))throw Error(`Stale release metadata: ${dir}`);}
else throw Error('stamp-release.mjs write|verify <directories>');
