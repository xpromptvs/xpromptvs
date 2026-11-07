export type NativeScrollOutput = {kind:'begin'|'cancel'} | {kind:'end';vx:number;vy:number}
  | {kind:'scroll';dx:number;dy:number;precise:boolean};
export interface NativeScrollBatch {
  sequence:number; gesture:number; x:number; y:number; width:number; height:number; mods:number;
  events:NativeScrollOutput[];
}
export interface NativeScrollTarget { left:number;top:number;width:number;height:number;scale:number }
interface Dependencies {
  enabled():boolean;
  viewport():{width:number;height:number};
  target(x:number,y:number):NativeScrollTarget|undefined;
  send(message:Record<string,unknown>):void;
}
/** Owns only remote-picture gestures. Original WebKit wheel events keep local default scrolling. */
export class NativeSourceScroll {
  private sequence=0;
  private fallback=false;
  private contact?:{gesture:number;x:number;y:number;scale:number;mods:number};
  constructor(private readonly deps:Dependencies) {}
  suppressesDOM():boolean {return this.deps.enabled()&&!this.fallback;}
  handle(batch:NativeScrollBatch):void {
    if(!Number.isSafeInteger(batch.sequence)||batch.sequence<=this.sequence)return;
    this.sequence=batch.sequence;
    if(!this.deps.enabled()){this.contact=undefined;this.fallback=true;return;}
    if(![batch.x,batch.y,batch.width,batch.height,batch.mods].every(Number.isFinite)
      ||batch.width<=0||batch.height<=0||!Number.isSafeInteger(batch.gesture)||!Array.isArray(batch.events))return;
    if(batch.mods&2){this.cancel();return;} // Keep the existing picture ctrl-wheel/pinch suppression.
    // A contact that started before capability negotiation keeps its DOM sender and momentum
    // tail through completion. Acquire native delivery only at the next explicit contact begin.
    if(this.fallback&&!batch.events.some(event=>event.kind==='begin'))return;
    if(this.contact?.gesture===batch.gesture)this.contact.mods=batch.mods&31;
    const viewport=this.deps.viewport(),sx=viewport.width/batch.width,sy=viewport.height/batch.height;
    const point=()=>{
      const target=this.deps.target(batch.x*viewport.width,batch.y*viewport.height);
      if(!target||target.width<=0||target.height<=0||!(target.scale>0))return;
      return {gesture:batch.gesture,x:Math.max(0,Math.min(1,(batch.x*viewport.width-target.left)/target.width)),
        y:Math.max(0,Math.min(1,(batch.y*viewport.height-target.top)/target.height)),scale:target.scale,mods:batch.mods&31};
    };
    for(const event of batch.events){
      if(event.kind==='begin'){
        this.fallback=false;
        this.cancel();this.contact=point();if(this.contact)this.boundary('begin',0,0);
      }else if(event.kind==='scroll'){
        if(!Number.isFinite(event.dx)||!Number.isFinite(event.dy))continue;
        // Positive IDs are contact gestures: one that began on local UI cannot migrate onto the picture.
        const target=this.contact?.gesture===batch.gesture?this.contact:batch.gesture===0?point():undefined;
        if(!target)continue;
        const scale=event.precise?target.scale:1;
        this.deps.send({t:'scroll',x:target.x,y:target.y,dx:event.dx*(event.precise?sx:1)/scale,
          dy:event.dy*(event.precise?sy:1)/scale,unit:event.precise?'px':'line',mods:batch.mods&31});
      }else if(this.contact?.gesture===batch.gesture){
        if(event.kind==='end'&&Number.isFinite(event.vx)&&Number.isFinite(event.vy)){
          this.boundary('end',event.vx*sx/this.contact.scale,event.vy*sy/this.contact.scale);this.contact=undefined;
        }else if(event.kind==='cancel')this.cancel();
      }
    }
  }
  private boundary(phase:'begin'|'end'|'cancel',vx:number,vy:number):void {
    const c=this.contact;if(c)this.deps.send({t:'scroll-gesture',phase,x:c.x,y:c.y,vx,vy,mods:c.mods});
  }
  cancel():void {this.boundary('cancel',0,0);this.contact=undefined;}
}
