import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const load=()=>import('../lib/product-features.mjs');
test('product profiles preserve development features and disable publication features',async()=>{
 const {resolveProductFeatures}=await load();
 assert.deepEqual(resolveProductFeatures('development'),{graphicalAgents:true,glasses:true});
 assert.deepEqual(resolveProductFeatures('publication'),{graphicalAgents:false,glasses:false});
 assert.throws(()=>resolveProductFeatures('publicaton'),/Unknown product profile/);
});
test('native generated configuration agrees with the canonical profile',async()=>{
 const {resolveProductFeatures}=await load(),dir=mkdtempSync(join(tmpdir(),'rdev-features-'));
 try{for(const profile of ['development','publication']){
  const out=join(dir,profile+'.swift');
  const r=spawnSync('python3',['config/generate_product_features.py','config/product-features.json',profile,out],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  const text=readFileSync(out,'utf8');
  for(const [name,value] of Object.entries(resolveProductFeatures(profile)))assert.match(text,new RegExp(`static let ${name} = ${value}`));
 }}finally{rmSync(dir,{recursive:true,force:true});}
});
test('publication helper build succeeds without any SDK or helper source',()=>{
 const dir=mkdtempSync(join(tmpdir(),'rdev-no-sdk-'));
 try{
  const script=new URL('../build-agent-helper.mjs',import.meta.url);
  const r=spawnSync(process.execPath,[script.pathname],{cwd:dir,env:{...process.env,RDEV_PRODUCT_PROFILE:'publication'},encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  assert.throws(()=>readFileSync(join(dir,'dist/agents/claude-helper.mjs')),/ENOENT/);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('Bazel product profile rejects unknown names instead of enabling development features',()=>{
 const r=spawnSync('bazelisk',['build','--//config:profile=publicaton','//config:native_product_features'],{encoding:'utf8',maxBuffer:2*1024*1024});
 assert.notEqual(r.status,0);
 assert.match(r.stderr,/Unknown product profile/);
});
test('publication HTML does not advertise glasses capability',async()=>{
 const {transformProductHtml,resolveProductFeatures}=await load();
 const html='<html data-theme="dark"><meta name="mrbd-web-app-capable" content="yes" /></html>';
 const published=transformProductHtml(html,resolveProductFeatures('publication'));
 assert.match(published,/data-glasses-enabled="false"/);assert.doesNotMatch(published,/mrbd-web-app-capable/);
 assert.match(transformProductHtml(html,resolveProductFeatures('development')),/mrbd-web-app-capable/);
});
