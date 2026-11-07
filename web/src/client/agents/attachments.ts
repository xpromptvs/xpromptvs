import type {AgentObject} from './protocol';
import type {LocalPasteApi} from '../paste-local';
export type DraftAttachment={id:string;name:string;file:File;image:boolean;preview?:string;hostID?:string;epoch?:string};
async function bytes(blob:Blob):Promise<ArrayBuffer>{
 if(typeof blob.arrayBuffer==='function')return blob.arrayBuffer();
 return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onerror=()=>reject(reader.error);reader.onload=()=>resolve(reader.result as ArrayBuffer);reader.readAsArrayBuffer(blob);});
}
/** Files belong to the local draft until Send, and to that exact thread throughout upload. */
export class AgentAttachments{
 private drafts=new Map<string,DraftAttachment[]>();
 list(thread:string):readonly DraftAttachment[]{return this.drafts.get(thread)??[];}
 add(thread:string,files:readonly File[]):void{
  const current=this.list(thread);
  if(current.length+files.length>16)throw Error('Attach at most 16 files per message');
  if(files.some(file=>file.size>32*1024*1024))throw Error('Attachments must be at most 32 MiB');
  if([...current.map(a=>a.file),...files].reduce((sum,file)=>sum+file.size,0)>64*1024*1024)throw Error('Attachments must total at most 64 MiB');
  const added=files.map(file=>{
   const image=/^image\/(png|jpeg|gif|webp|heic|heif|tiff|bmp)$/i.test(file.type)||(!file.type||file.type==='application/octet-stream')&&/\.(png|jpe?g|gif|webp|heic|heif|tiff?|bmp)$/i.test(file.name);
   const extension:Record<string,string>={'image/png':'.png','image/jpeg':'.jpg','image/gif':'.gif','image/webp':'.webp','image/heic':'.heic','image/heif':'.heif','image/tiff':'.tiff','image/bmp':'.bmp'};
   let name=file.name||(image?'Pasted image':'Attachment');if(image&&!/\.[a-z0-9]+$/i.test(name))name+=extension[file.type]??'.png';
   return{id:crypto.randomUUID(),name,file,image,preview:image&&typeof URL.createObjectURL==='function'?URL.createObjectURL(file):undefined};
  });
  this.drafts.set(thread,[...current,...added]);
 }
 remove(thread:string,id:string):void{
  const rows=this.list(thread);for(const row of rows)if(row.id===id&&row.preview)URL.revokeObjectURL(row.preview);
  const keep=rows.filter(row=>row.id!==id);if(keep.length)this.drafts.set(thread,keep);else this.drafts.delete(thread);
 }
 consume(thread:string,items:readonly DraftAttachment[]):void{for(const item of items)this.remove(thread,item.id);}
 async upload(thread:string,items:readonly DraftAttachment[],epoch:string,send:(thread:string,args:AgentObject)=>Promise<unknown>,valid:()=>boolean):Promise<string[]>{
  const ids:string[]=[];const check=()=>{if(!valid())throw Error('Connection changed; attachments remain in the draft');};
  for(const item of items){
   check();if(item.epoch===epoch&&item.hostID){ids.push(item.hostID);continue;}
   const id=crypto.randomUUID();
   for(let start=0,seq=0;start<Math.max(item.file.size,1);start+=16384,seq++){
    const data=new Uint8Array(await bytes(item.file.slice(start,start+16384)));check();
    await send(thread,{upload:id,name:item.name,image:item.image,seq,data:btoa(String.fromCharCode(...data)),last:start+16384>=item.file.size});check();
   }
   item.hostID=id;item.epoch=epoch;ids.push(id);
  }return ids;
 }
 dispose():void{for(const[thread,items]of this.drafts)this.consume(thread,[...items]);}
}
/** Capture File objects synchronously: clipboard DataTransfer is empty after the event returns. */
export function pasteAttachments(event:ClipboardEvent,options:{stage:(files:File[])=>void;valid:()=>boolean;error:(error:unknown)=>void;local?:LocalPasteApi|null;pending?:(on:boolean)=>void}):boolean{
 const data=event.clipboardData;if(!data)return false;
 const files=[...data.files];
 if(!files.length)for(const item of [...data.items??[]]){if(item.kind==='file'){const file=item.getAsFile();if(file)files.push(file);}}
 const hinted=[...data.types].includes('Files')||[...data.types].includes('text/uri-list')&&data.getData('text/uri-list').startsWith('file:');
 if(!files.length&&!(hinted&&options.local))return false;
 event.preventDefault();event.stopPropagation();
 options.pending?.(true);
 void (async()=>{
  const local=options.local;
  if(local&&(!files.length||files.some(file=>file.size===0&&!file.type))){
   const copied=await local.files();if(!options.valid())return;
   if(copied.some(file=>file.dir))throw Error('Compress folders before attaching them');
   if(copied.length){
    const prepared=await local.prepare(copied.map(file=>file.path));
    try{
     if(!options.valid())return;
     if(prepared.length>16||prepared.some(file=>file.size>32*1024*1024)||prepared.reduce((sum,file)=>sum+file.size,0)>64*1024*1024)throw Error('Attach at most 16 files, 32 MiB each and 64 MiB total');
     const actual:File[]=[];
     for(const file of prepared){const blob=await local.read(file.url);if(!options.valid())return;actual.push(new File([blob],file.name,{type:file.type||blob.type}));}
     options.stage(actual);return;
    }finally{local.discard(prepared.map(file=>file.url));}
   }
  }
  if(options.valid())options.stage(files);
 })().catch(error=>{if(options.valid())options.error(error);}).finally(()=>options.pending?.(false));return true;
}
