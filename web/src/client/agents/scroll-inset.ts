/** Extend the native scrollbar beside the fixed controls without hiding the last message. */
export class AgentScrollInset {
 private observer?:ResizeObserver;
 private conversation:HTMLElement;
 height=0;
 private viewportHeight:number|undefined;
 private resizing=false;
 constructor(private scroll:HTMLElement,private footerStart:HTMLElement,private resize:(change:()=>void,previousHeight?:number)=>void){
  this.conversation=scroll.parentElement!;
  if(typeof ResizeObserver==='function'){
   this.observer=new ResizeObserver(()=>this.resizeViewport(()=>{}));
   this.observer.observe(this.conversation);
   for(const node of this.conversation.children)if(node!==scroll)this.observer.observe(node);
  }
 }
 observe(node:HTMLElement):void{this.observer?.observe(node);}
 resizeViewport(change:()=>void):void{
  if(this.resizing){change();return;}
  this.resizing=true;
  try{this.resize(()=>{change();this.measure();},this.viewportHeight);}finally{this.resizing=false;}
 }
 private measure():void{
  if(!this.scroll.getClientRects().length)return;
  const height=Math.max(0,this.conversation.getBoundingClientRect().bottom-this.footerStart.getBoundingClientRect().top);
  if(Math.abs(height-this.height)>=.01){this.height=height;this.conversation.style.setProperty('--agent-footer-height',`${height}px`);}
  // Native disclosures/viewport resizing can change geometry before ResizeObserver runs.
  // Keep the last measured visible height so their correction still starts from the old band.
  this.viewportHeight=Math.max(0,this.scroll.clientHeight-this.height);
 }
 dispose():void{this.observer?.disconnect();}
}
