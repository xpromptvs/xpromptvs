import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
import {launchApp} from './lib/app.mjs';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,copyFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
// Deterministic composer; argv0 exercises native foreground-agent detection.
const fixtureDir=mkdtempSync(join(tmpdir(),'rdev-prediction-'));
const kind=process.argv[2]||'codex';
const empty=process.argv[3]==='empty';
assert.ok(['codex','claude'].includes(kind));
const fixture=join(fixtureDir,kind);
copyFileSync(new URL('./fixtures/prediction-composer.py',import.meta.url),fixture);
const python=execFileSync('/usr/bin/python3',['-c','import os,sys; p=os.path.join(sys.prefix, "Resources/Python.app/Contents/MacOS/Python"); print(p if os.path.exists(p) else os.path.realpath(sys.executable))'],{encoding:'utf8'}).trim();
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
const app=await launchApp({env:{RDEV_SIGNALING:'http://127.0.0.1:9',RDEV_TMUX_SOCKET:`rdev-prediction-${process.pid}`}});
try {
 const win=await app.waitForLocal();
 await app.waitFor(win.id,"return globalThis.__rdev?.connectionState === 'connected'",30000);
 await app.eval(win.id,`const u=new URL(location.href);u.searchParams.delete('predict');u.searchParams.set('predictlag','400');u.searchParams.set('renderer','dom');location.href=u.href;return true`);
 await sleep(1500);
 await app.waitFor(win.id,"return globalThis.__rdev?.connectionState === 'connected'",30000);
 await app.eval(win.id,`Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});Object.defineProperty(document,'visibilityState',{configurable:true,get:()=> 'visible'});document.dispatchEvent(new Event('visibilitychange'));globalThis.__rdev.sendControl({t:'open-terminal'});return true`);
 await app.waitFor(win.id,"return (globalThis.__rdev?.termTabs?.()??[]).length>0",30000);
 await sleep(1000);
 await app.eval(win.id,`return globalThis.__rdev.sendKey(${JSON.stringify('exec -a '+kind+' '+quote(python)+' -u '+quote(fixture)+' '+kind+(empty?' empty':'')+'\r')})`);
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.includes('Fixture agent'))",20000);
 await sleep(3000);

 const input=ch=>app.eval(win.id,`const root=window.__rdevClientRoot??document;const ta=root.querySelector('#xterm .xterm-tab:not(.is-hidden) .xterm-helper-textarea');if(!ta)throw Error('missing textarea');ta.dispatchEvent(new InputEvent('beforeinput',{inputType:'insertText',data:${JSON.stringify(ch)},bubbles:true,cancelable:true}));return true`);
 const state=()=>app.eval(win.id,'return globalThis.__rdev.termEcho');
 console.log('before',JSON.stringify(await app.eval(win.id,'return {list:globalThis.__rdev.termList,buffer:globalThis.__rdev.termBuffer(),cursor:globalThis.__rdev.termCursor()}')));
 if(empty) {
   // Start typing while the CLI is busy; no pre-existing text and no shortcut footer.
   let expected='';
   for(const ch of 'hello') {
     await input(ch); expected+=ch; await sleep(30);
     const current=await state();
     assert.equal(current.prediction.pending,true);
     assert.equal(current.prediction.text,expected);
   }
   await app.waitFor(win.id,"return !globalThis.__rdev.termEcho.prediction.pending",15000);
 }
 await input('\x7f');
 await sleep(20);
 let first=await state();console.log(kind,'first delete',JSON.stringify(first));
 assert.equal(first.prediction.field,true);assert.equal(first.prediction.text,'hell');assert.equal(first.prediction.pending,true);
 if(kind==='codex') {
   const painted=await app.eval(win.id,`const root=window.__rdevClientRoot??document;return [...root.querySelectorAll('.prediction-overlay-run')].map(el=>({text:el.textContent,width:el.getBoundingClientRect().width,height:el.getBoundingClientRect().height,display:getComputedStyle(el).display,visibility:getComputedStyle(el).visibility}))`);
   assert.ok(painted.some(r=>r.text.startsWith('hell')&&r.width>0&&r.height>0&&r.display!=='none'&&r.visibility==='visible'),JSON.stringify(painted));
 }
 await input('x');await input('y');await input('\x7f');await input('z');
 await sleep(30);
 let next=await state();console.log('pending',JSON.stringify(next));assert.equal(next.prediction.text,'hellxz');
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.includes('hellxz'))",15000);
 await app.waitFor(win.id,"return !globalThis.__rdev.termEcho.prediction.pending",15000);
 // A visibly cleared composer is ready for the next prompt, not a 2.5-second lockout.
 await input('\r');
 await app.waitFor(win.id,"return !globalThis.__rdev.termBuffer().some(s=>s.includes('hellxz'))",15000);
 await sleep(100); // Let the authoritative empty composer settle (still far below the 2.5 s guard).
 await input('n'); await sleep(30);
 const resumed=await state();
 assert.equal(resumed.prediction.pending,true,JSON.stringify(resumed));
 assert.equal(resumed.prediction.text,'n');
 await app.waitFor(win.id,"return !globalThis.__rdev.termEcho.prediction.pending",15000);
 // A transient cursor excursion during repaint must not cancel a live prediction.
 await input('~');
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.includes('Fixture agent cursor restored'))",15000);
 assert.equal((await state()).prediction.pending,true,'transient redraw must retain prediction');
 await app.waitFor(win.id,"return !globalThis.__rdev.termEcho.prediction.pending",15000);
 // The second submit briefly erases its row, then restores it. That intermediate
 // empty frame must not release the guard, and typing ahead must cancel recovery.
 await input('\r');
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.includes('Fixture agent restored'))",15000);
 await input('a'); await sleep(30);
 assert.equal((await state()).prediction.pending,false,'split redraw must not resume prediction');
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.trim()==='"+(kind==='claude'?'❯':'›')+" a')",15000);
 await input('b'); await sleep(30);
 assert.equal((await state()).prediction.pending,false,'typing ahead must retain the guard');
 // Deliver input as soon as a recognized relocation arrives. If WebKit throttles
 // the poll until after settle, the settled check must provide the same protection.
 await sleep(2700);
 await app.eval(win.id,`const poll=setInterval(()=>{
   if(!globalThis.__rdev.termBuffer().some(s=>s.includes('Fixture agent moved')))return;
   clearInterval(poll);
   const before=globalThis.__rdev.termEcho.prediction.pending;
   const root=window.__rdevClientRoot??document;
   root.querySelector('#xterm .xterm-tab:not(.is-hidden) .xterm-helper-textarea').dispatchEvent(new InputEvent('beforeinput',{inputType:'insertText',data:'z',bubbles:true,cancelable:true}));
   setTimeout(()=>{globalThis.__rdev.relocationCheck={before,after:globalThis.__rdev.termEcho.prediction.pending}},0);
 },1);return true`);
 await input('^');
 await app.waitFor(win.id,"return !!globalThis.__rdev.relocationCheck",15000);
 const relocation=await app.eval(win.id,"return globalThis.__rdev.relocationCheck");
 console.log('relocation',JSON.stringify(relocation));
 assert.equal(relocation.after,false,'input must not extend the old field anchor');
 // A layout that remains changed after settling must still stop prediction.
 await sleep(2700);
 await input('#'); await sleep(30);
 assert.equal((await state()).prediction.pending,true);
 await app.waitFor(win.id,"return globalThis.__rdev.termBuffer().some(s=>s.includes('Fixture agent menu'))",15000);
 await app.waitFor(win.id,"return !globalThis.__rdev.termEcho.prediction.pending",15000);
 await input('q'); await sleep(30);
 assert.equal((await state()).prediction.pending,false,'an actual menu must not predict');
 console.log('PASS',kind,'recognized confirmed-text backspace + delayed replacement through native input and xterm');
} finally { await app.quit(); rmSync(fixtureDir,{recursive:true,force:true}); }
