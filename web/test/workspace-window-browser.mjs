// Actual WindowManager, stylesheet, renderer and xterm with a local packed MediaStream.
// No host, native app, or desktop mutation. node web/test/workspace-window-browser.mjs
import { chromium } from '../../e2e/node_modules/playwright/index.mjs';
import { build } from '../node_modules/esbuild/lib/main.js';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
const script=(await build({stdin:{contents:'export { installWindowChrome } from "./web/src/client/window-chrome"; export { WindowManager } from "./web/src/client/window-manager"; export { Terminal } from "./web/node_modules/@xterm/xterm";',resolveDir:process.cwd()},bundle:true,format:'iife',globalName:'Product',write:false})).outputFiles[0].text;
const css=await readFile('web/src/client/style.css','utf8'),termCss=await readFile('web/node_modules/@xterm/xterm/css/xterm.css','utf8');
const chromeCss=await readFile('web/src/client/window-chrome.css','utf8');
const server=createServer((req,res)=>{if(req.url!=='/'){res.writeHead(404);res.end();return;}res.setHeader('Content-Type','text/html');res.end(`<!doctype html><html data-layout="floating" data-theme="dark"><style>${css}\n${chromeCss}\n${termCss}\n#session{position:fixed;inset:0} #terminal{position:absolute;inset:0}.xterm{height:100%}</style><body><div id="session"><div id="terminal"></div><div id="windows"></div></div><script>${script}</script>`);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
try {
 browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:1440,height:1000}});
 page.on('pageerror',e=>console.log('PAGE ERROR',e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 await page.evaluate(()=>{
  Product.installWindowChrome();
  const terminal=new Product.Terminal({cols:140,rows:50});terminal.open(document.querySelector('#terminal'));terminal.write('Real terminal underneath workspace\r\n');
  window.termData='';terminal.onData(data=>window.termData+=data);window.messages=[];window.terminalPresses=0;
  document.querySelector('#terminal').addEventListener('pointerdown',()=>window.terminalPresses++);
  // Match session.ts: this holder-backed proxy exposes send only; it gates its live channel internally.
  const channel={send:bytes=>window.messages.push(JSON.parse(new TextDecoder().decode(bytes.slice(1))))};
  const wm=new Product.WindowManager(document.querySelector('#windows'),{workspaceSupported:true,workspaceActive:()=>true,onFocus:()=>{},onClose:()=>{},onMinimize:()=>{},onPrefs:()=>{},onRecovery:()=>{},onPlayoutDelay:()=>{},inputChannel:channel,nowMs:()=>performance.now()});
  const source=document.createElement('canvas');source.width=3840;source.height=800;const c=source.getContext('2d');
  const draw=()=>{c.fillStyle='black';c.fillRect(0,0,3840,800);c.fillStyle='red';c.fillRect(0,0,640,400);c.fillStyle='white';c.fillRect(1280,0,640,400);c.fillRect(2560,0,640,400);};draw();
  let stream=source.captureStream(30);window.stream=stream;window.timer=setInterval(draw,30);
  const format={format:'workspace-rgb-alpha-hit-v1',logicalWidth:1280,logicalHeight:800,capturedWidth:1280,capturedHeight:800,codedWidth:3840,codedHeight:800,codec:'av1'};
  const view={source:'apps:test',name:'Apps',focused:true,fps:60,scale:1,bitrateBps:8000000,presentation:format};
  window.sync=(valid=true)=>wm.sync([{...view,presentation:valid?format:undefined}],new Map([['apps:test',stream]]));
  window.replaceTrack=()=>{stream.getTracks().forEach(t=>t.stop());stream=source.captureStream(30);window.stream=stream;window.sync();};
  window.wm=wm;window.sync();wm.setSourceSize('apps:test',1280,800);
 });
 await page.waitForFunction(()=>document.querySelector('.workspace-unavailable')?.hidden,{timeout:10000});
 const geometry=await page.evaluate(()=>{const el=document.querySelector('.workspace-window'),r=el.querySelector('.win-body').getBoundingClientRect();return {left:r.left,top:r.top,width:r.width,height:r.height,pointer:getComputedStyle(el).pointerEvents,opacity:getComputedStyle(el.querySelector('video')).opacity};});
 assert.equal(geometry.pointer,'none');assert.equal(geometry.opacity,'0');assert.ok(Math.abs(geometry.width/geometry.height-1.6)<.01,JSON.stringify(geometry));
 const point=(x,y)=>({x:geometry.left+geometry.width*x,y:geometry.top+geometry.height*y});const occupied=point(.25,.25),gap=point(.75,.75);
 await page.mouse.click(gap.x,gap.y);await page.keyboard.type('gap');
 let result=await page.evaluate(()=>({presses:terminalPresses,data:termData,messages}));assert.equal(result.presses,1);assert.equal(result.data,'gap');assert.equal(result.messages.filter(m=>m.t==='touch').length,0);
 await page.mouse.move(occupied.x,occupied.y);await page.mouse.down();await page.mouse.move(gap.x,gap.y);await page.mouse.up();
 result=await page.evaluate(()=>({presses:terminalPresses,messages,focused:wm.wins.get('apps:test').focused,ready:wm.wins.get('apps:test').workspace.isReady,hit:wm.wins.get('apps:test').workspace.hitAt(.25,.25)}));assert.equal(result.presses,1);assert.deepEqual(result.messages.filter(m=>m.t==='touch').map(m=>m.phase),['down','move','up']);
 const down=result.messages.find(m=>m.t==='touch'&&m.phase==='down');assert.ok(Math.abs(down.x-.25)<.002&&Math.abs(down.y-.25)<.002,JSON.stringify(down));
 await page.evaluate(()=>{wm.suspendWorkspaces();sync();});
 await page.mouse.click(gap.x,gap.y);
 assert.deepEqual(await page.evaluate(()=>({presses:terminalPresses,note:!document.querySelector('.workspace-unavailable').hidden,ready:wm.wins.get('apps:test').workspace.isReady})),{presses:1,note:true,ready:false});
 await page.evaluate(()=>replaceTrack());
 await page.waitForFunction(()=>document.querySelector('.workspace-unavailable')?.hidden);
 await page.evaluate(()=>sync(false));await page.mouse.click(gap.x,gap.y);
 result=await page.evaluate(()=>({presses:terminalPresses,note:!document.querySelector('.workspace-unavailable').hidden,canvases:document.querySelectorAll('.workspace-picture').length,touches:messages.filter(m=>m.t==='touch').length}));
 assert.equal(result.presses,1);assert.equal(result.note,true);assert.equal(result.canvases,0);assert.equal(result.touches,3);
 await page.evaluate(()=>{wm.clear();clearInterval(timer);stream.getTracks().forEach(t=>t.stop());});
 console.log('PASS actual WindowManager + stylesheet + WebGL + xterm: logical geometry, transparent trusted terminal input, occupied drag latch, peer suspension blocks gaps until a fresh track, metadata withdrawal blocks gaps');
} finally {await browser?.close();await new Promise(resolve=>server.close(resolve));}
