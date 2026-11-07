// scrollHeight/clientHeight are rounded; native scrollTop and elastic entry are not.
const END_TOLERANCE=1;
type Entry<T>={item:T;node:HTMLElement};
type Anchor={key:string;offset:number};
type Options<T>={key:(item:T)=>string;same:(a:T,b:T)=>boolean;render:(item:T)=>HTMLElement;estimate?:(item:T)=>number;bottomInset?:()=>number;capture?:(item:T,node:HTMLElement)=>void;release?:(item:T,node:HTMLElement)=>void};
/** Variable-height keyed DOM window. No detached row DOM is cached. */
export class VirtualList<T>{
 private items:T[]=[];
 private keys:string[]=[];
 private offsets:number[]=[0];
 private heights=new Map<string,number>();
 private mounted=new Map<string,Entry<T>>();
 private observer?:ResizeObserver;
 private frame:number|null=null;
 private visible=true;
 private disposed=false;
 private following=true;
 private lastScrollTop=0;
 private pendingAnchor:Anchor|null=null;
 private lastAnchor:Anchor|null=null;
 private width=0;
 private rendering=false;
 private pointerDown=false;
 private touchY:number|null=null;
 private elasticScroll=false;
 private elasticReading=false;
 private elasticAnchor:Anchor|null=null;
 private elasticStartTop=0;
 private overscrollFallback:string|undefined;
 private readonly overscan=600;
 constructor(private scroll:HTMLElement,private content:HTMLElement,private options:Options<T>){
  scroll.addEventListener('scroll',this.onScroll,{passive:true});
  scroll.addEventListener('scrollend',this.onScrollEnd,{passive:true});
  scroll.addEventListener('wheel',this.onWheel,{passive:true});
  scroll.addEventListener('touchstart',this.onTouchStart,{passive:true});scroll.addEventListener('touchmove',this.onTouchMove,{passive:true});
  scroll.addEventListener('touchend',this.onTouchEnd,{passive:true});scroll.addEventListener('touchcancel',this.onTouchEnd,{passive:true});
  // Without a native gesture-completion signal, prefer a calm endpoint to timed guesses
  // that can interrupt a fingers-down pause. Modern WebKit/Chromium retain native elasticity.
  if(!Reflect.has(scroll,'onscrollend')){this.overscrollFallback=scroll.style.overscrollBehaviorY;scroll.style.overscrollBehaviorY='none';}
  content.addEventListener('toggle',this.schedule,true);content.addEventListener('load',this.schedule,true);content.addEventListener('focusout',this.schedule);
  content.addEventListener('pointerdown',this.press);
  content.ownerDocument.addEventListener('pointerup',this.releasePress);content.ownerDocument.addEventListener('pointercancel',this.releasePress);content.ownerDocument.defaultView!.addEventListener('blur',this.releasePress);
  if(typeof ResizeObserver==='function'){this.observer=new ResizeObserver(()=>{if(this.visible&&!this.rendering)this.schedule();});this.observer.observe(scroll);this.observer.observe(content);}
 }
 private viewportHeight():number{return Math.max(0,this.scroll.clientHeight-(this.options.bottomInset?.()??0));}
 private activeElement():HTMLElement|null{return (this.content.getRootNode() as Document|ShadowRoot).activeElement as HTMLElement|null;}
 private scale():number{return this.scroll.offsetWidth?this.scroll.getBoundingClientRect().width/this.scroll.offsetWidth||1:1;}
 private listTop():number{return this.scroll.scrollTop+(this.content.getBoundingClientRect().top-this.scroll.getBoundingClientRect().top)/this.scale()-this.scroll.clientTop;}
 private rebuild():void{this.offsets=[0];for(let i=0;i<this.items.length;i++)this.offsets.push(this.offsets[i]!+(this.heights.get(this.keys[i]!)??Math.max(1,this.options.estimate?.(this.items[i]!)??96)));}
 private indexAt(y:number):number{
  let lo=0,hi=this.items.length;while(lo<hi){const mid=(lo+hi)>>>1;if(this.offsets[mid+1]!<=y)lo=mid+1;else hi=mid;}return Math.min(lo,Math.max(0,this.items.length-1));
 }
 private anchor():Anchor|null{
  if(!this.items.length)return null;const y=this.scroll.scrollTop-this.listTop(),i=this.indexAt(Math.max(0,y));return{key:this.keys[i]!,offset:y-this.offsets[i]!};
 }
 preservePosition():void{this.pendingAnchor=this.anchor();this.following=false;}
 /** Keep viewport changes in the same task as their scroll correction, before paint. */
 resizeViewport(change:()=>void,previousHeight=this.viewportHeight()):void{
  const anchor=this.anchor(),following=this.followsLatest,rendering=this.rendering,height=previousHeight;
  this.rendering=true;
  try{change();}finally{this.rendering=rendering;}
  // Preserve distance from the composer, including while reading older messages.
  if(anchor&&!following)anchor.offset+=height-this.viewportHeight();
  if(this.elasticScroll&&this.elasticAnchor&&!following)this.elasticAnchor.offset+=height-this.viewportHeight();
  this.following=following;this.layout(anchor);
 }

 setItems(items:T[]):void{
  if(this.disposed)return;const anchor=this.pendingAnchor??this.anchor();this.pendingAnchor=null;
  for(const e of this.mounted.values())this.options.capture?.(e.item,e.node);
  this.items=items;this.keys=items.map(this.options.key);const valid=new Set(this.keys);
  for(const key of this.heights.keys())if(!valid.has(key))this.heights.delete(key);
  this.rebuild();this.layout(anchor);
 }
 private onScroll=()=>{
  if(this.rendering||!this.visible||!this.scroll.clientHeight)return;
  const top=this.scroll.scrollTop,max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight),distance=max-top;
  if(this.elasticScroll&&!this.elasticReading&&distance<=END_TOLERANCE)this.following=true;
  // WebKit exposes native rubber-banding outside the ordinary scroll range. Its return
  // movement is not a request to read older output, and refreshing it must not clamp it.
  if(top < -END_TOLERANCE || top > Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight)+END_TOLERANCE){this.beginElasticScroll();return;}
  if(this.elasticScroll){
   // Live growth can put an intermediate rubber-band coordinate inside the new range.
   // Only scrollend owns the end of this phase. Upward input, not native rebound
   // coordinates, releases following; fractional/mobile rebound is not reading intent.
   this.schedule();return;
  }
  // Any upward movement releases the tail, even before it clears a whole CSS pixel.
  // An anchor-correction scroll event at the same position must keep that choice.
  if(top<this.lastScrollTop&&distance>0)this.following=false;
  else if(distance<=0||(top>this.lastScrollTop&&distance<=END_TOLERANCE))this.following=true;
  else if(distance>END_TOLERANCE)this.following=false;
  this.lastScrollTop=top;this.lastAnchor=this.anchor();this.schedule();
 };
 private scrollIntent(delta:number):void{
  if(!delta)return;
  if(this.elasticScroll){this.elasticReading=delta<0;if(delta<0)this.following=false;}
  // A downward gesture at the native endpoint may produce no scroll event at all.
  if(delta>0&&this.scroll.scrollHeight-this.scroll.scrollTop-this.scroll.clientHeight<=END_TOLERANCE)this.following=true;
 }
 private onWheel=(event:WheelEvent)=>{
  if(!event.ctrlKey&&Math.abs(event.deltaY)>=Math.abs(event.deltaX))this.scrollIntent(event.deltaY);
 };
 private onTouchStart=(event:TouchEvent)=>{this.touchY=event.touches.length===1?event.touches[0]!.clientY:null;};
 private onTouchMove=(event:TouchEvent)=>{
  const y=event.touches.length===1?event.touches[0]!.clientY:null;
  if(y!==null&&this.touchY!==null)this.scrollIntent(this.touchY-y);
  this.touchY=y;
 };
 private onTouchEnd=()=>{this.touchY=null;};
 private beginElasticScroll():void{
  if(this.elasticScroll)return;
  const top=this.scroll.scrollTop,max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight);
  this.elasticStartTop=Math.min(max,Math.max(0,top));this.elasticReading=false;
  if(top>max)this.following=true;
  // Async native elasticity can expose scrollTop and client rectangles from different phases.
  // Translate the last in-range keyed anchor instead of deriving it from the stretched frame.
  if(this.lastAnchor)this.elasticAnchor={...this.lastAnchor,offset:this.lastAnchor.offset+this.elasticStartTop-this.lastScrollTop};
  else{this.elasticAnchor=this.anchor();if(this.elasticAnchor)this.elasticAnchor.offset-=top-this.elasticStartTop;}
  this.elasticScroll=true;
 }
 private onScrollEnd=()=>{
  if(!this.elasticScroll||this.disposed||!this.visible)return;
  const anchor=this.elasticReadingAnchor(),top=this.scroll.scrollTop,max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight),distance=max-top;
  // Reaching the tail through rubber-banding is still an explicit return to following.
  // A fractional upward escape must remain detached.
  if(distance<=0||(top>this.elasticStartTop&&distance<=END_TOLERANCE))this.following=true;
  this.elasticScroll=false;this.elasticReading=false;this.elasticAnchor=null;
  // Native completion can arrive before the final stretched coordinate is normalized.
  // Finish once here instead of letting layout immediately start another elastic phase.
  if(top < -END_TOLERANCE || top > max+END_TOLERANCE)this.scroll.scrollTop=Math.min(max,Math.max(0,top));
  this.layout(this.following?null:anchor);
 };
 private elasticReadingAnchor():Anchor|null{
  if(!this.elasticAnchor)return null;
  // Preserve keyed prepend/height corrections and the user's net movement, without
  // replaying the rubber-band displacement itself as a reading position.
  const max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight);
  return{...this.elasticAnchor,offset:this.elasticAnchor.offset+Math.min(max,Math.max(0,this.scroll.scrollTop))-this.elasticStartTop};
 }
 private schedule=()=>{
  if(this.disposed||!this.visible||this.frame!==null)return;
  this.frame=this.content.ownerDocument.defaultView!.requestAnimationFrame(()=>{this.frame=null;this.refresh();});
 };
 private press=()=>{this.pointerDown=true;};
 private releasePress=()=>{if(this.pointerDown){this.pointerDown=false;this.schedule();}};
 refresh():void{if(!this.disposed)this.layout(this.anchor());}
 get isOverscrolling():boolean{return this.elasticScroll;}
 get followsLatest():boolean{return this.scroll.clientHeight?this.following&&(this.elasticScroll||this.scroll.scrollHeight-this.scroll.scrollTop-this.scroll.clientHeight<=END_TOLERANCE):this.following;}
 scrollToEnd():void{
  // An explicit jump may end rubber-banding; automatic redraws may not.
  const max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight);
  if(this.elasticScroll||this.scroll.scrollTop<0||this.scroll.scrollTop>max)this.scroll.scrollTop=max;
  this.elasticScroll=false;this.elasticReading=false;this.elasticAnchor=null;this.following=true;this.layout(null);
 }
 restorePosition(top:number,follow:boolean):void{
  this.following=follow;
  if(follow){this.scrollToEnd();return;}
  if(!this.items.length)return;
  if(!this.content.getBoundingClientRect().width){this.scroll.scrollTop=top;this.lastScrollTop=this.scroll.scrollTop;return;}
  const y=top-this.listTop(),index=this.indexAt(Math.max(0,y));
  this.layout({key:this.keys[index]!,offset:y-this.offsets[index]!});
 }
 private range():number[]{
  if(this.items.length<=40||!this.scroll.clientHeight)return this.items.map((_,i)=>i);
  const y=this.scroll.scrollTop-this.listTop(),first=this.indexAt(Math.max(0,y-this.overscan)),last=this.indexAt(y+this.viewportHeight()+this.overscan);
  const indices=new Set<number>();for(let i=first;i<=last;i++)indices.add(i);
  const focused=this.activeElement();if(focused)for(const[key,e]of this.mounted)if(e.node.contains(focused)){const i=this.keys.indexOf(key);if(i>=0)indices.add(i);break;}
  return [...indices].sort((a,b)=>a-b);
 }
 private evict(key:string,e:Entry<T>):void{
  this.options.capture?.(e.item,e.node);this.options.release?.(e.item,e.node);this.observer?.unobserve(e.node);e.node.remove();this.mounted.delete(key);
 }
 private sync(indices:number[]):void{
  const keep=new Set(indices.map(i=>this.keys[i]!));
  // Removing spacers first clamps native scrollTop to the mounted rows' short height. Restoring
  // it afterward cancels WebKit's wheel/momentum movement on every live-output redraw.
  const gaps=new Map([...this.content.querySelectorAll<HTMLElement>(':scope > .agent-virtual-gap')].map(node=>[node.dataset.gapKey,node]));
  const usedGaps=new Set<HTMLElement>();
  const sequence:HTMLElement[]=[];
  const gap=(height:number,before:string|null,after:string|null)=>{
   if(height<.1)return;const key=JSON.stringify([before,after]);let node=gaps.get(key);
   if(!node){node=this.content.ownerDocument.createElement('div');node.className='agent-virtual-gap';node.dataset.gapKey=key;node.setAttribute('aria-hidden','true');}
   if(Math.abs((parseFloat(node.style.height)||0)-height)>.01)node.style.height=height+'px';usedGaps.add(node);sequence.push(node);
  };
  let end=0,previousKey:string|null=null;
  for(const index of indices){
   const item=this.items[index]!,key=this.keys[index]!;gap(this.offsets[index]!-end,previousKey,key);let e=this.mounted.get(key);
   const active=this.activeElement(),previous=e;
   const protectedRow=previous&&(this.pointerDown||(active&&previous.node.contains(active)&&active.matches('input,textarea,select,[contenteditable="true"]')));
   if(!e||(!protectedRow&&!this.options.same(e.item,item))){
    if(e){this.options.capture?.(e.item,e.node);this.options.release?.(e.item,e.node);this.observer?.unobserve(e.node);}
    const focused=this.activeElement(),hadFocus=e&&focused&&e.node.contains(focused),focusKey=hadFocus?focused.dataset.focus:undefined;
    const focusables='a[href],button,input,textarea,select,summary,[tabindex]';
    const focusIndex=hadFocus?[...e!.node.querySelectorAll(focusables)].indexOf(focused):-1;
    const node=this.options.render(item);if(e)e.node.replaceWith(node);e={item,node};this.mounted.set(key,e);this.observer?.observe(node);
    if(hadFocus){const replacement=focusKey?[...node.querySelectorAll<HTMLElement>('[data-focus]')].find(n=>n.dataset.focus===focusKey):node.querySelectorAll<HTMLElement>(focusables)[focusIndex];replacement?.focus({preventScroll:true});}
   }
   e.node.dataset.virtualIndex=String(index);e.node.setAttribute('aria-posinset',String(index+1));e.node.setAttribute('aria-setsize',String(this.items.length));sequence.push(e.node);end=this.offsets[index+1]!;previousKey=key;
  }
  gap(this.offsets.at(-1)!-end,previousKey,null);let cursor=this.content.firstChild;
  const wanted=new Set<Node>(sequence);
  for(const node of sequence){
   // Retired nodes may remain temporarily, but must not cause kept/focused rows to be moved.
   while(cursor&&!wanted.has(cursor))cursor=cursor.nextSibling;
   if(cursor===node)cursor=cursor.nextSibling;else this.content.insertBefore(node,cursor);
  }
  // Install the complete next window before removing retired rows/spacers: the scroll range
  // must never collapse transiently while the person is moving through the conversation.
  for(const[key,e]of this.mounted)if(!keep.has(key))this.evict(key,e);
  for(const node of gaps.values())if(!usedGaps.has(node))node.remove();
 }
 private measure():boolean{
  let changed=false;
  for(const[key,{node}]of this.mounted){const rect=node.getBoundingClientRect();if(!rect.height)continue;
   const style=this.content.ownerDocument.defaultView!.getComputedStyle(node),height=rect.height/this.scale()+(parseFloat(style.marginTop)||0)+(parseFloat(style.marginBottom)||0);
   if(Math.abs((this.heights.get(key)??0)-height)>.5){this.heights.set(key,height);changed=true;}
  }return changed;
 }
 private layout(anchor:Anchor|null):void{
  if(!this.visible||this.disposed||this.rendering)return;this.rendering=true;
  try{
   // A phone keyboard/request may hide only the scrolling band while the tab stays visible.
   if(this.content.ownerDocument.defaultView!.getComputedStyle(this.scroll).display==='none'){
    this.pendingAnchor??=this.lastAnchor;for(const[key,e]of this.mounted)this.evict(key,e);this.content.replaceChildren();return;
   }
   const top=this.scroll.scrollTop,max=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight);
   if(top < -END_TOLERANCE || top > max+END_TOLERANCE)this.beginElasticScroll();
   const elastic=this.elasticScroll;
   if(this.pendingAnchor){anchor=this.pendingAnchor;this.pendingAnchor=null;}
   const width=this.content.clientWidth;if(width&&this.width&&width!==this.width)this.heights.clear();if(width)this.width=width;this.rebuild();
   for(let pass=0;pass<5;pass++){
    if(!elastic&&this.following){if(!this.followsLatest)this.scroll.scrollTop=Math.max(0,this.listTop()+this.offsets.at(-1)!-this.viewportHeight()+32);}
    else if(!elastic&&anchor){const i=this.keys.indexOf(anchor.key);if(i>=0){const top=Math.max(0,this.listTop()+this.offsets[i]!+anchor.offset);if(Math.abs(this.scroll.scrollTop-top)>.01)this.scroll.scrollTop=top;}}
    const indices=this.range();this.sync(indices);const changed=this.measure();if(changed)this.rebuild();
    // scrollHeight/clientHeight are rounded; native scrollTop can end at a fraction.
    // Do not rewrite a settled position (or interfere with trackpad rubber-banding).
    if(!elastic&&this.following){const top=Math.max(0,this.scroll.scrollHeight-this.scroll.clientHeight);if(Math.abs(this.scroll.scrollTop-top)>END_TOLERANCE)this.scroll.scrollTop=top;}
    else if(!elastic&&anchor){const i=this.keys.indexOf(anchor.key);if(i>=0){const top=Math.max(0,this.listTop()+this.offsets[i]!+anchor.offset);if(Math.abs(this.scroll.scrollTop-top)>.01)this.scroll.scrollTop=top;}}
    const next=this.range();if(!changed&&indices.length===next.length&&indices.every((v,i)=>v===next[i]))break;if(pass===4)this.schedule();
   }
   if(this.scroll.clientHeight&&!elastic){this.lastAnchor=this.anchor();this.lastScrollTop=this.scroll.scrollTop;}
  }finally{this.rendering=false;}
 }
 setVisible(visible:boolean):void{
  if(this.visible===visible||this.disposed)return;this.visible=visible;
  if(!visible){if(this.elasticScroll)this.pendingAnchor=this.elasticReadingAnchor();else if(this.scroll.clientHeight)this.pendingAnchor=this.anchor();else this.pendingAnchor??=this.lastAnchor;this.following=this.followsLatest;this.elasticScroll=false;this.elasticReading=false;this.elasticAnchor=null;this.touchY=null;this.pointerDown=false;if(this.frame!==null){this.content.ownerDocument.defaultView!.cancelAnimationFrame(this.frame);this.frame=null;}this.observer?.disconnect();for(const[key,e]of this.mounted)this.evict(key,e);}
  else{this.observer?.observe(this.scroll);this.observer?.observe(this.content);this.refresh();}
 }
 clear():void{
  for(const[key,e]of this.mounted)this.evict(key,e);this.items=[];this.keys=[];this.heights.clear();this.offsets=[0];this.pendingAnchor=null;this.lastAnchor=null;this.following=true;this.lastScrollTop=0;this.elasticScroll=false;this.elasticReading=false;this.elasticAnchor=null;this.touchY=null;this.pointerDown=false;this.width=0;this.content.replaceChildren();
 }
 dispose():void{
  if(this.disposed)return;this.clear();this.disposed=true;this.observer?.disconnect();if(this.frame!==null)this.content.ownerDocument.defaultView!.cancelAnimationFrame(this.frame);
  this.scroll.removeEventListener('wheel',this.onWheel);this.scroll.removeEventListener('touchstart',this.onTouchStart);this.scroll.removeEventListener('touchmove',this.onTouchMove);
  this.scroll.removeEventListener('touchend',this.onTouchEnd);this.scroll.removeEventListener('touchcancel',this.onTouchEnd);
  this.scroll.removeEventListener('scroll',this.onScroll);this.scroll.removeEventListener('scrollend',this.onScrollEnd);
  if(this.overscrollFallback!==undefined)this.scroll.style.overscrollBehaviorY=this.overscrollFallback;
  this.content.removeEventListener('toggle',this.schedule,true);this.content.removeEventListener('load',this.schedule,true);this.content.removeEventListener('focusout',this.schedule);
  this.content.removeEventListener('pointerdown',this.press);this.content.ownerDocument.removeEventListener('pointerup',this.releasePress);this.content.ownerDocument.removeEventListener('pointercancel',this.releasePress);this.content.ownerDocument.defaultView!.removeEventListener('blur',this.releasePress);
 }
}
