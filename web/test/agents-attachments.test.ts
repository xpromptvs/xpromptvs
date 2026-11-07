import {afterEach,expect,it,vi} from 'vitest';
import {AgentAttachments,pasteAttachments} from '../src/client/agents/attachments';
import type {AgentObject} from '../src/client/agents/protocol';
afterEach(()=>{vi.restoreAllMocks();vi.unstubAllGlobals();});
it('stages removable image/file drafts without uploading and keeps threads separate',()=>{
 const uploads=vi.fn(),drafts=new AgentAttachments();
 drafts.add('one',[new File(['image'],'photo.png',{type:'image/png'}),new File(['text'],'notes.txt')]);
 expect(drafts.list('one').map(a=>a.name)).toEqual(['photo.png','notes.txt']);expect(drafts.list('two')).toHaveLength(0);expect(uploads).not.toHaveBeenCalled();
 drafts.remove('one',drafts.list('one')[0]!.id);expect(drafts.list('one').map(a=>a.name)).toEqual(['notes.txt']);drafts.dispose();
});
it('uploads only the captured Send snapshot and reuses completed upload IDs on retry',async()=>{
 const drafts=new AgentAttachments();drafts.add('one',[new File(['hello'],'notes.txt')]);const snapshot=[...drafts.list('one')];
 const upload=vi.fn(async(_thread:string,_args:AgentObject)=>({}));const ids=await drafts.upload('one',snapshot,'epoch',upload,()=>true);
 expect(upload).toHaveBeenCalledTimes(1);expect(upload.mock.calls[0]?.[0]).toBe('one');expect(ids).toHaveLength(1);
 drafts.add('one',[new File(['next'],'later.txt')]);
 expect(await drafts.upload('one',snapshot,'epoch',upload,()=>true)).toEqual(ids);expect(upload).toHaveBeenCalledTimes(1);
 drafts.consume('one',snapshot);expect(drafts.list('one').map(a=>a.name)).toEqual(['later.txt']);drafts.dispose();
});
it('sequences chunks and stops a changed epoch before sending any more bytes',async()=>{
 const drafts=new AgentAttachments();drafts.add('one',[new File([new Uint8Array(32769)],'large.bin')]);const snapshot=[...drafts.list('one')];
 const send=vi.fn(async(_thread:string,_args:AgentObject)=>({}));await drafts.upload('one',snapshot,'one',send,()=>true);
 expect(send.mock.calls.map(c=>c[1].seq)).toEqual([0,1,2]);expect(send.mock.calls.map(c=>atob(c[1].data).length)).toEqual([16384,16384,1]);expect(send.mock.calls.map(c=>c[1].last)).toEqual([false,false,true]);
 let valid=true;const changed=vi.fn(async()=>{valid=false;return{};});
 await expect(drafts.upload('one',snapshot,'new-epoch',changed,()=>valid)).rejects.toThrow('Connection changed');expect(changed).toHaveBeenCalledTimes(1);expect(drafts.list('one')).toHaveLength(1);drafts.dispose();
});
it('revokes image previews on removal and disposal',()=>{
 const revoke=vi.fn();vi.stubGlobal('URL',{createObjectURL:()=> 'blob:preview',revokeObjectURL:revoke});const drafts=new AgentAttachments();
 drafts.add('one',[new File(['png'],'image.png',{type:'image/png'})]);expect(drafts.list('one')[0]?.preview).toBe('blob:preview');drafts.remove('one',drafts.list('one')[0]!.id);expect(revoke).toHaveBeenCalledTimes(1);
 drafts.add('two',[new File(['png'],'other.png',{type:'image/png'})]);drafts.dispose();expect(revoke).toHaveBeenCalledTimes(2);
});
it('reads native Finder files into the captured draft and discards prepared URLs',async()=>{
 const stage=vi.fn(),discard=vi.fn(),local={files:async()=>[{path:'/copied/photo.png',name:'photo.png',dir:false}],prepare:async()=>[{url:'app://client/__paste/token/photo.png',name:'photo.png',type:'image/png',size:3}],read:async()=>new Blob(['png'],{type:'image/png'}),discard,cancel:()=>{}};
 const event=new Event('paste',{cancelable:true}) as ClipboardEvent;Object.defineProperty(event,'clipboardData',{value:{files:[new File([],'photo.png')],types:['Files']}});
 pasteAttachments(event,{stage,local,valid:()=>true,error:error=>{throw error;}});
 await vi.waitFor(()=>expect(stage).toHaveBeenCalledTimes(1));expect(stage.mock.calls[0]![0][0].name).toBe('photo.png');expect(discard).toHaveBeenCalledWith(['app://client/__paste/token/photo.png']);
});
it('does not stage a native paste after control changes and still discards its prepared files',async()=>{
 let valid=true,resolve!:(blob:Blob)=>void;const stage=vi.fn(),discard=vi.fn();
 const local={files:async()=>[{path:'/copied/a',name:'a',dir:false}],prepare:async()=>[{url:'prepared',name:'a',type:'',size:1}],read:()=>new Promise<Blob>(r=>{resolve=r;}),discard,cancel:()=>{}};
 const event=new Event('paste',{cancelable:true}) as ClipboardEvent;Object.defineProperty(event,'clipboardData',{value:{files:[],types:['Files']}});
 pasteAttachments(event,{stage,local,valid:()=>valid,error:()=>{}});await vi.waitFor(()=>expect(resolve).toBeTypeOf('function'));
 valid=false;resolve(new Blob(['a']));await vi.waitFor(()=>expect(discard).toHaveBeenCalled());expect(stage).not.toHaveBeenCalled();
});
it('enforces file limits before adding any file to the draft',()=>{
 const drafts=new AgentAttachments();const huge=new File(['x'],'huge');Object.defineProperty(huge,'size',{value:33*1024*1024});
 expect(()=>drafts.add('one',[new File(['ok'],'ok'),huge])).toThrow('32 MiB');expect(drafts.list('one')).toHaveLength(0);drafts.dispose();
});
it('pasting files consumes the file payload but leaves plain text paste alone',async()=>{
 const stage=vi.fn(),file=new File(['image'],'clip.png',{type:'image/png'});
 const event=new Event('paste',{cancelable:true}) as ClipboardEvent;Object.defineProperty(event,'clipboardData',{value:{files:[file],types:['Files','text/plain']}});
 expect(pasteAttachments(event,{stage,valid:()=>true,error:()=>{}})).toBe(true);expect(event.defaultPrevented).toBe(true);
 await Promise.resolve();expect(stage).toHaveBeenCalledWith([file]);
 const plain=new Event('paste',{cancelable:true}) as ClipboardEvent;Object.defineProperty(plain,'clipboardData',{value:{files:[],types:['text/plain']}});
 expect(pasteAttachments(plain,{stage,valid:()=>true,error:()=>{}})).toBe(false);expect(plain.defaultPrevented).toBe(false);
});
