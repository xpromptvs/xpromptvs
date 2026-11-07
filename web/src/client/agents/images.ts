import type {AgentObject} from './protocol';
import {blurhashCanvas} from './blurhash';
type Info={width:number;height:number;mime:string;name:string;blurhash?:string};
type Entry={thread:string;item:string;turn?:string;path:string;info?:Info;src?:string;failed:boolean;pending:boolean;manual:boolean;retries?:number;retry?:ReturnType<typeof setTimeout>};
type Fetch=(op:string,thread:string,args:AgentObject)=>Promise<AgentObject>;
const raster=new Set(['image/png','image/jpeg','image/gif','image/webp','image/heic','image/heif']);
/** Host-authorized local images. Geometry precedes pixels; only near-viewport slots start work. */
export class AgentImages{
 private entries=new Map<string,Entry>();
 private slots=new Map<HTMLElement,{entry:Entry;near:boolean}>();
 private observer?:IntersectionObserver;
 private queue=new Set<Entry>();
 private visible=false;
 private generation=0;
 private running=0;
 private disposed=false;
 constructor(private scroll:HTMLElement,private fetch:Fetch){
  if(typeof IntersectionObserver==='function')this.observer=new IntersectionObserver(rows=>{
   for(const row of rows){const slot=this.slots.get(row.target as HTMLElement);if(!slot)continue;slot.near=row.isIntersecting;if(slot.near)this.enqueue(slot.entry);}
  },{root:scroll,rootMargin:'400px 0px'});
 }
 slot(thread:string,item:AgentObject,path:string):HTMLElement{
  const key=JSON.stringify([thread,item._turn,item.id,path]);let entry=this.entries.get(key);
  if(!entry){entry={thread,item:item.id,turn:item._turn,path,failed:false,pending:false,manual:false};this.entries.set(key,entry);}
  const node=this.scroll.ownerDocument.createElement('div');node.className='agent-image-slot';
  this.slots.set(node,{entry,near:false});this.render(node,entry);
  if(this.visible)this.observer?.observe(node);return node;
 }
 private render(node:HTMLElement,entry:Entry):void{
  const info=entry.info;
  node.toggleAttribute('data-measured',!!info&&!entry.failed);
  if(info&&!entry.failed){node.style.aspectRatio=`${info.width} / ${info.height}`;node.style.width=`min(100%, ${info.width}px, ${600*info.width/info.height}px)`;}
  else{node.style.removeProperty('aspect-ratio');node.style.removeProperty('width');}
  if(info?.blurhash&&!entry.failed&&!node.querySelector('canvas')&&!node.querySelector('img:not(.agent-image-loading)')){
   const canvas=blurhashCanvas(node.ownerDocument,info.blurhash);if(canvas)node.prepend(canvas);
  }
  if(entry.src){
   const previous=node.querySelector('img');if(previous?.getAttribute('src')===entry.src)return;
   const image=node.ownerDocument.createElement('img');image.className='agent-image';image.alt=info?.name??'Session image';image.loading='lazy';image.decoding='async';
   if(info){image.width=info.width;image.height=info.height;}
   const placeholder=node.querySelector('canvas');if(placeholder)image.classList.add('agent-image-loading');
   image.addEventListener('load',()=>{
    void (typeof image.decode==='function'?image.decode():Promise.resolve()).then(()=>{
     if(node.querySelector('img')!==image)return;image.classList.remove('agent-image-loading');node.querySelector('canvas')?.remove();
    }).catch(()=>{image.dispatchEvent(new Event('error'));});
   },{once:true});
   image.addEventListener('error',()=>{
    if(!node.isConnected||node.querySelector('img')!==image)return;entry.src=undefined;entry.failed=true;node.replaceChildren();this.render(node,entry);
   },{once:true});
   image.src=entry.src;node.replaceChildren(...placeholder?[placeholder,image]:[image]);return;
  }
  if(!entry.failed&&node.querySelector('img'))return;
  const existing=node.querySelector('button');if(existing){existing.disabled=entry.pending;return;}
  const button=node.ownerDocument.createElement('button');button.type='button';button.className='agent-link';button.textContent='Show image';button.dataset.focus=`${entry.item}:asset:${entry.path}`;
  button.addEventListener('click',()=>{clearTimeout(entry.retry);entry.retry=undefined;entry.failed=false;entry.manual=true;this.enqueue(entry);});node.append(button);
 }
 private update(entry:Entry):void{for(const[node,slot]of this.slots)if(slot.entry===entry)this.render(node,entry);}
 private needed(entry:Entry):boolean{return this.visible&&[...this.slots].some(([node,slot])=>slot.entry===entry&&node.isConnected&&(slot.near||entry.manual));}
 private enqueue(entry:Entry):void{
  if(this.disposed||entry.pending||entry.src||entry.failed||entry.retry!==undefined)return;
  this.queue.add(entry);this.pump();
 }
 private pump():void{
  if(!this.visible||this.disposed)return;
  for(const entry of this.queue){
   if(this.running>=2)break;this.queue.delete(entry);
   if(!this.needed(entry))continue;
   const generation=this.generation;entry.pending=true;this.running++;this.update(entry);
   void this.load(entry,generation).catch(error=>{
    if(generation!==this.generation||this.disposed)return;
    const retries=entry.retries??0;
    if(!entry.manual&&/not (?:been )?persisted/i.test(String(error?.message))&&retries<3){
     if(this.needed(entry)){entry.retries=retries+1;entry.retry=setTimeout(()=>{entry.retry=undefined;if(generation===this.generation&&this.needed(entry))this.enqueue(entry);},[250,1000,3000][retries]);}
    }else{entry.failed=true;this.update(entry);}
   }).finally(()=>{
    entry.pending=false;entry.manual=false;this.running--;if(generation===this.generation)this.update(entry);this.pump();
   });
  }
 }
 private async load(entry:Entry,generation:number):Promise<void>{
  const current=()=>generation===this.generation&&!this.disposed;
  const args={item:entry.item,path:entry.path,...entry.path.startsWith('input:')?{turnId:entry.turn}:{}};
  if(!entry.info&&!entry.manual){
   const info=await this.fetch('asset-info',entry.thread,args);if(!current())return;
   if(!Number.isSafeInteger(info.width)||!Number.isSafeInteger(info.height)||info.width<=0||info.height<=0||info.width>100_000||info.height>100_000||!raster.has(info.mime))throw Error('Image dimensions unavailable');
   entry.info={width:info.width,height:info.height,mime:info.mime,name:String(info.name??'Session image'),blurhash:typeof info.blurhash==='string'?info.blurhash:undefined};this.update(entry);
  }
  if(!current()||!this.needed(entry))return;
  const asset=await this.fetch('asset',entry.thread,args);if(!current())return;
  const mime=entry.info?.mime??asset.mime;
  if(!raster.has(mime)||typeof asset.data!=='string'||asset.data.length>32*1024*1024*4/3+4)throw Error('Unsupported image');
  entry.src=`data:${mime};base64,${asset.data}`;this.trim(entry);this.update(entry);
  // Display a valid large image, but retain no pixel cache entry larger than the whole budget.
  if(entry.src.length>32*1024*1024)entry.src=undefined;
 }
 private trim(keep:Entry):void{
  let bytes=0;for(const entry of this.entries.values())bytes+=entry.src?.length??0;
  for(const entry of this.entries.values()){
   if(bytes<=32*1024*1024)break;if(entry===keep||!entry.src)continue;
   bytes-=entry.src.length;entry.src=undefined;
  }
 }
 release(root:HTMLElement):void{
  for(const[node,slot]of this.slots)if(root===node||root.contains(node)){this.observer?.unobserve(node);this.slots.delete(node);if(!this.needed(slot.entry)){clearTimeout(slot.entry.retry);slot.entry.retry=undefined;}}
 }
 setVisible(visible:boolean):void{
  if(this.visible===visible)return;
  this.visible=visible;this.observer?.disconnect();
  if(!visible)for(const entry of this.entries.values()){clearTimeout(entry.retry);entry.retry=undefined;}
  for(const[node,slot]of this.slots){slot.near=false;if(visible)this.observer?.observe(node);}
  if(visible)this.pump();
 }
 reset():void{this.generation++;this.observer?.disconnect();for(const entry of this.entries.values())clearTimeout(entry.retry);this.slots.clear();this.entries.clear();this.queue.clear();}
 dispose():void{this.disposed=true;this.visible=false;this.reset();}
}
