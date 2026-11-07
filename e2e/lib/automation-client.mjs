import net from 'node:net';
/** Attach to an explicitly named, loopback DEV automation port owned by a test. No app discovery. */
export async function automationClient(port) {
  const socket=await new Promise((resolve,reject)=>{const socket=net.connect(port,'127.0.0.1',()=>resolve(socket));socket.once('error',reject);});
  let sequence=0,buffer='';const pending=new Map();
  const fail=()=>{for(const {reject,timer}of pending.values()){clearTimeout(timer);reject(Error('automation connection closed'));}pending.clear();};
  socket.on('close',fail);socket.on('error',fail);
  socket.on('data',bytes=>{buffer+=bytes;for(let i;(i=buffer.indexOf('\n'))>=0;){const reply=JSON.parse(buffer.slice(0,i));buffer=buffer.slice(i+1);const call=pending.get(reply.id);if(!call)continue;pending.delete(reply.id);clearTimeout(call.timer);reply.ok?call.resolve(reply.value):call.reject(Error(reply.error));}});
  return {call(command,parameters={}){return new Promise((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>{pending.delete(id);reject(Error(`automation timed out: ${command}`));},15000);pending.set(id,{resolve,reject,timer});socket.write(JSON.stringify({id,cmd:command,...parameters})+'\n');});},close(){socket.destroy();}};
}
