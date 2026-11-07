import {createRequire} from 'node:module';
import net from 'node:net';
import {homedir} from 'node:os';
import {join} from 'node:path';
const require=createRequire(new URL('../../web/package.json',import.meta.url));
const WebSocket=require('ws');
export async function codexClient({socketPath=process.env.RDEV_CODEX_SOCKET??join(process.env.CODEX_HOME??join(homedir(),'.codex'),'app-server-control/app-server-control.sock')}={}){
 const ws=new WebSocket('ws://localhost/',{createConnection:()=>net.connect(socketPath)}),pending=new Map(),events=[],requests=[];let serial=0,onEvent=()=>{};
 ws.on('message',raw=>{const m=JSON.parse(raw.toString());if(m.method){(m.id==null?events:requests).push(m);if(m.id==null)onEvent(m);return;}const waiter=pending.get(m.id);if(!waiter)return;clearTimeout(waiter.timer);pending.delete(m.id);m.error?waiter.reject(Error(m.error.message)):waiter.resolve(m.result);});
 const closed=error=>{for(const waiter of pending.values()){clearTimeout(waiter.timer);waiter.reject(error);}pending.clear();};
 ws.on('close',()=>closed(Error('Codex connection closed')));ws.on('error',closed);
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Codex socket timed out')),8000);ws.once('open',()=>{clearTimeout(timer);resolve();});ws.once('error',reject);});
 const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial,timer=setTimeout(()=>{pending.delete(id);reject(Error('Codex RPC timed out: '+method));},20000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}));});
 await call('initialize',{clientInfo:{name:'xpromptvs_disposable_check',title:'Xpromptvs disposable integration check',version:'1'},capabilities:{experimentalApi:true,requestAttestation:false}});
 ws.send(JSON.stringify({method:'initialized'}));
 return{call,events,requests,onEvent:callback=>onEvent=callback,answer:(id,result)=>ws.send(JSON.stringify({id,result})),close:()=>ws.close(),terminate:()=>ws.terminate(),
  wait:async(predicate,timeout=20000)=>{const deadline=Date.now()+timeout;while(Date.now()<deadline){const value=predicate();if(value)return value;await new Promise(resolve=>setTimeout(resolve,50));}throw Error('Codex condition timed out');}};
}
