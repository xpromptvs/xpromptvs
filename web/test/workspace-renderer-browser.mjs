// Real shader/pixel verification without a host, fixture app, or native desktop mutation.
// node web/test/workspace-renderer-browser.mjs
import { chromium } from '../../e2e/node_modules/playwright/index.mjs';
import { build } from '../node_modules/esbuild/lib/main.js';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
const script=(await build({entryPoints:['web/src/client/workspace-renderer.ts'],bundle:true,format:'iife',globalName:'Workspace',write:false})).outputFiles[0].text;
const server=createServer((_req,res)=>{res.setHeader('Content-Type','text/html');res.end('<!doctype html><body><script>'+script+'</script>');});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try {
 browser=await chromium.launch({headless:true});
 const page=await browser.newPage();
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 const result=await page.evaluate(async()=>{
  const source=document.createElement('canvas');source.width=3840;source.height=800;
  const ctx=source.getContext('2d');
  let second=false;
  const draw=()=>{
   ctx.fillStyle=second?'rgb(0,0,64)':'rgb(128,0,0)';ctx.fillRect(0,0,1280,800);
   ctx.fillStyle=second?'rgb(64,64,64)':'rgb(128,128,128)';ctx.fillRect(1280,0,1280,800);
   ctx.fillStyle='black';ctx.fillRect(2560,0,1280,800);
   ctx.fillStyle='white';ctx.fillRect(second?3200:2560,0,640,400);
  };
  draw();const stream=source.captureStream(30),video=document.createElement('video');
  video.muted=true;video.playsInline=true;video.srcObject=stream;document.body.append(video);
  const r=new Workspace.WorkspaceRenderer(video,{format:'workspace-rgb-alpha-hit-v1',logicalWidth:1280,logicalHeight:800});
  document.body.append(r.canvas);r.start();await video.play();
  const timer=setInterval(draw,30);
  const deadline=performance.now()+10000;
  while(r.hitAt(.25,.25)===null&&performance.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
  const gl=r.canvas.getContext('webgl'),p=new Uint8Array(4);gl.readPixels(100,100,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);
  const value={pixel:[...p],hits:[r.hitAt(.25,.25),r.hitAt(.75,.25),r.hitAt(.25,.75)],dimensions:[r.canvas.width,r.canvas.height]};
  second=true;draw();
  while(r.hitAt(.25,.25)!==false&&performance.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
  gl.readPixels(100,100,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);value.nextPixel=[...p];value.nextHits=[r.hitAt(.25,.25),r.hitAt(.75,.25)];
  r.stop();value.stopped=r.hitAt(.25,.25);r.dispose();clearInterval(timer);stream.getTracks().forEach(t=>t.stop());return value;
 });
 assert.deepEqual(result.hits,[true,false,false]);assert.deepEqual(result.dimensions,[1280,800]);assert.equal(result.stopped,null);
 assert.ok(Math.abs(result.pixel[0]-128)<=2 && result.pixel[1]<=2 && result.pixel[2]<=2 && Math.abs(result.pixel[3]-128)<=2,JSON.stringify(result));
 assert.deepEqual(result.nextHits,[false,true]);assert.deepEqual(result.nextPixel,[0,0,64,64]);
 console.log('PASS workspace real WebGL premultiplied color, alpha, panel selection, mask orientation and stop',JSON.stringify(result));
} finally {await browser?.close();await new Promise(resolve=>server.close(resolve));}
