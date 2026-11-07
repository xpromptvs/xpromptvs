import {spawnSync} from 'node:child_process';
import {mkdirSync,copyFileSync,rmSync} from 'node:fs';
import {resolveProductFeatures,productProfile} from './lib/product-features.mjs';
const out='dist/agents';
if(!resolveProductFeatures(productProfile()).graphicalAgents){
 rmSync(out,{recursive:true,force:true});
}else{
 mkdirSync(out,{recursive:true});
 const r=spawnSync('node_modules/.bin/esbuild',['src/agents/claude-helper.mjs','--bundle','--platform=node','--format=esm','--target=node20','--packages=bundle','--outfile='+out+'/claude-helper.mjs',"--banner:js=import { createRequire as _createRequire } from 'node:module'; const require = _createRequire(import.meta.url);"],{stdio:'inherit'});
 if(r.error)throw r.error;if(r.status!==0)process.exit(r.status??1);
 copyFileSync('node_modules/@anthropic-ai/claude-agent-sdk/LICENSE.md',out+'/CLAUDE-AGENT-SDK-LICENSE.md');
}
