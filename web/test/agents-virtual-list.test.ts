import {it,expect,vi} from 'vitest';
import {VirtualList} from '../src/client/agents/virtual-list';

function fixture(bottomInset=()=>0){
 const scroll=document.createElement('div'),content=document.createElement('div');scroll.append(content);document.body.append(scroll);
 Object.defineProperty(scroll,'clientHeight',{value:400,configurable:true});
 Object.defineProperty(scroll,'scrollHeight',{get:()=>[...content.children].reduce((sum,e)=>sum+(e.classList.contains('agent-virtual-gap')?parseFloat((e as HTMLElement).style.height):100),bottomInset())});
 content.getBoundingClientRect=()=>({top:-scroll.scrollTop,width:600} as DOMRect);
 const released:string[]=[],sizes=new Map<string,number>();
 const list=new VirtualList<{id:string,text:string}>(scroll,content,{key:i=>i.id,same:(a,b)=>a===b,estimate:()=>100,bottomInset,render:i=>{const el=document.createElement('article');el.dataset.item=i.id;el.textContent=i.text;el.getBoundingClientRect=()=>({height:sizes.get(i.id)??100} as DOMRect);return el;},release:(i)=>released.push(i.id)});
 const rows=Array.from({length:300},(_,i)=>({id:String(i),text:'Record '+i}));
 return{scroll,content,list,rows,released,sizes,close:()=>{list.dispose();scroll.remove();}};
}
it('releases a mounted row before replacing its presentation',()=>{
 const f=fixture();try{
  f.list.setItems([{id:'one',text:'Before'}]);
  f.list.setItems([{id:'one',text:'After'}]);
  expect(f.released).toEqual(['one']);expect(f.content.textContent).toContain('After');
 }finally{f.close();}
});
it('mounts a bounded window, recycles distant rows and can jump to the end',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);expect(f.content.querySelectorAll('article').length).toBeLessThan(30);
  expect(f.content.querySelector('[data-item="299"]')).not.toBeNull();
  f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(f.content.querySelector('[data-item="100"]')).not.toBeNull();
  expect(f.content.querySelector('[data-item="299"]')).toBeNull();expect(f.released.length).toBeGreaterThan(0);
  f.list.scrollToEnd();expect(f.content.querySelector('[data-item="299"]')).not.toBeNull();
 }finally{f.close();}
});
it('keeps unchanged spacer nodes mounted during live updates outside the reading window',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  const gaps=[...f.content.querySelectorAll('.agent-virtual-gap')];expect(gaps).toHaveLength(2);
  f.list.setItems(f.rows.map((row,i)=>i===299?{...row,text:'Live output'}:row));
  const after=[...f.content.querySelectorAll('.agent-virtual-gap')];expect(after).toHaveLength(2);
  after.forEach((gap,i)=>expect(gap).toBe(gaps[i]));expect(f.scroll.scrollTop).toBe(10000);
 }finally{f.close();}
});
it('anchors the same record when older history is prepended and when leading records are pruned',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  const older=Array.from({length:20},(_,i)=>({id:'old'+i,text:'Older'}));
  f.list.setItems([...older,...f.rows]);expect(f.scroll.scrollTop).toBe(12000);
  f.list.setItems(f.rows.slice(10));expect(f.scroll.scrollTop).toBe(9000);
 }finally{f.close();}
});
it('keeps focused rows mounted, releases rows when hidden, and removes scheduled work on dispose',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const node=f.content.querySelector<HTMLElement>('[data-item="299"]')!;node.tabIndex=0;node.focus();
  f.scroll.scrollTop=0;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(node.isConnected).toBe(true);expect(document.activeElement).toBe(node);
  node.blur();f.list.refresh();expect(node.isConnected).toBe(false);
  f.list.setVisible(false);expect(f.content.querySelectorAll('article')).toHaveLength(0);
  f.list.setVisible(true);expect(f.content.querySelectorAll('article').length).toBeGreaterThan(0);
 }finally{f.close();}
});

it('corrects the anchor when a measured row above the viewport grows',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.sizes.set('96',300);f.list.refresh();expect(f.scroll.scrollTop).toBe(10200);
 }finally{f.close();}
});
it('replaces selected transcript text during live updates and evicts it normally while scrolling',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const node=f.content.querySelector<HTMLElement>('[data-item="299"]')!,range=document.createRange();
  range.selectNodeContents(node);document.getSelection()!.addRange(range);
  f.list.setItems([...f.rows.slice(0,-1),{id:'299',text:'Live replacement'}]);
  expect(node.isConnected).toBe(false);
  const replacement=f.content.querySelector<HTMLElement>('[data-item="299"]')!;
  expect(replacement.textContent).toBe('Live replacement');
  range.selectNodeContents(replacement);document.getSelection()!.addRange(range);
  f.scroll.scrollTop=0;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(replacement.isConnected).toBe(false);expect(f.content.querySelector('[data-item="0"]')).not.toBeNull();
 }finally{document.getSelection()!.removeAllRanges();f.close();}
});
it('defers pending editable-row replacement until a pointer action finishes',()=>{
 const scroll=document.createElement('div'),content=document.createElement('div');scroll.append(content);document.body.append(scroll);
 const list=new VirtualList<{id:string;text:string}>(scroll,content,{key:i=>i.id,same:(a,b)=>a===b,render:i=>{const node=document.createElement('article');node.append(document.createElement('input'),document.createTextNode(i.text));return node;}});
 try{
  list.setItems([{id:'a',text:'Original'}]);const original=content.querySelector('article')!,input=original.querySelector('input')!;input.focus();
  list.setItems([{id:'a',text:'Updated'}]);expect(content.querySelector('article')).toBe(original);
  content.dispatchEvent(new Event('pointerdown',{bubbles:true}));input.blur();list.refresh();expect(content.querySelector('article')).toBe(original);
  document.dispatchEvent(new Event('pointerup',{bubbles:true}));list.refresh();expect(content.querySelector('article')).not.toBe(original);expect(content.textContent).toContain('Updated');
 }finally{list.dispose();scroll.remove();}
});
it('lets the first small upward gesture leave the bottom without snapping back',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;
  f.scroll.scrollTop=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(f.scroll.scrollTop).toBe(bottom-.25);
  // Scroll events from the virtualizer's own anchor correction must not re-enable following.
  f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(f.scroll.scrollTop).toBe(bottom-.25);
  f.scroll.scrollTop-=24;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(f.scroll.scrollTop).toBe(bottom-24.25);
  f.list.setItems([...f.rows,{id:'live',text:'New output'}]);expect(f.scroll.scrollTop).toBe(bottom-24.25);
  f.list.scrollToEnd();expect(f.scroll.scrollTop).toBeGreaterThan(bottom);
 }finally{f.close();}
});

it('leaves a settled native scroll position untouched, including fractional bottom rounding',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);let top=f.scroll.scrollTop+.25;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(writes).toEqual([]);expect(f.scroll.scrollTop).toBe(29600.25);
  top=10000.25;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();writes.length=0;
  f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(writes).toEqual([]);
 }finally{f.close();}
});

it('moves scrolled history with the composer while keeping the same distance from its lower edge',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.list.resizeViewport(()=>Object.defineProperty(f.scroll,'clientHeight',{value:200,configurable:true}));
  expect(f.scroll.scrollTop).toBe(10200);expect(f.list.followsLatest).toBe(false);
  f.list.resizeViewport(()=>Object.defineProperty(f.scroll,'clientHeight',{value:400,configurable:true}));
  expect(f.scroll.scrollTop).toBe(10000);
  f.list.scrollToEnd();f.list.resizeViewport(()=>Object.defineProperty(f.scroll,'clientHeight',{value:200,configurable:true}));
  expect(f.scroll.scrollTop).toBe(29800);expect(f.list.followsLatest).toBe(true);
 }finally{f.close();}
});

it('does not consult browser text selections while updating the transcript',()=>{
 const f=fixture();const spy=vi.spyOn(document,'getSelection').mockImplementation(()=>{throw Error('Transcript selection must not be read');});
 try{
  expect(()=>f.list.setItems(f.rows)).not.toThrow();
  f.list.setItems([...f.rows,{id:'later',text:'Still live'}]);
  expect(f.content.querySelector('[data-item="later"]')).not.toBeNull();expect(spy).not.toHaveBeenCalled();
 }finally{spy.mockRestore();f.close();}
});

it('leaves native bottom overscroll alone during live updates and resumes following after it settles',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;let top=bottom;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  top=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(writes).toEqual([]);expect(f.list.followsLatest).toBe(true);
  // Output can grow past the old rubber-band position while the native gesture owns scrolling.
  const live=[...f.rows,{id:'live',text:'Working'}];f.list.setItems(live);f.list.refresh();
  expect(writes).toEqual([]);expect(top).toBe(bottom+40);
  top=bottom+20;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(writes).toEqual([]);expect(f.list.followsLatest).toBe(true);
  top=f.scroll.scrollHeight-f.scroll.clientHeight;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.scroll.dispatchEvent(new Event('scrollend'));
  expect(writes).toEqual([]);expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...live,{id:'next',text:'More output'}]);
  expect(f.scroll.scrollTop).toBe(f.scroll.scrollHeight-f.scroll.clientHeight);
 }finally{f.close();}
});
it('lets an upward gesture leave the tail directly after native overscroll',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;let top=bottom+40;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));top=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  expect(writes).toEqual([]);expect(f.list.followsLatest).toBe(false);
  f.list.setItems([...f.rows,{id:'live',text:'Working'}]);expect(top).toBe(bottom-.25);
 }finally{f.close();}
});
it('does not clamp native top overscroll while reading history',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=0;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  let top=-30;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();f.list.setItems([...f.rows,{id:'live',text:'Working'}]);
  expect(writes).toEqual([]);expect(top).toBe(-30);expect(f.list.followsLatest).toBe(false);
 }finally{f.close();}
});

it('defers the keyed history-prepend correction until native top overscroll ends',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.scroll.scrollTop=0;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  let top=-30;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.scroll.dispatchEvent(new Event('scroll'));f.list.preservePosition();
  f.list.setItems([...Array.from({length:20},(_,i)=>({id:'old'+i,text:'Older'})),...f.rows]);
  top=0;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(writes).toEqual([]);
  f.scroll.dispatchEvent(new Event('scrollend'));expect(top).toBe(2000);expect(f.list.followsLatest).toBe(false);
 }finally{f.close();}
});

it('recycles rows while an elastic gesture reverses into history before scrollend',async()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);let top=f.scroll.scrollTop+40;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.scroll.dispatchEvent(new Event('scroll'));f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-100}));top=10000;f.scroll.dispatchEvent(new Event('scroll'));
  await new Promise<void>(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve())));
  expect(writes).toEqual([]);expect(f.content.querySelector('[data-item="100"]')).not.toBeNull();
  expect(f.list.followsLatest).toBe(false);
 }finally{f.close();}
});

it('resumes following when a detached reader reaches the bottom through overscroll',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;
  f.scroll.scrollTop=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(f.list.followsLatest).toBe(false);
  f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));
  f.scroll.scrollTop=bottom;f.scroll.dispatchEvent(new Event('scroll'));f.scroll.dispatchEvent(new Event('scrollend'));
  expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...f.rows,{id:'live',text:'Working'}]);expect(f.scroll.scrollTop).toBe(bottom+100);
 }finally{f.close();}
});

it('keeps the reading distance above an overlaid footer when the full-height scroll viewport stays fixed',()=>{
 let inset=100;const f=fixture(()=>inset);try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.list.resizeViewport(()=>{inset=200;});expect(f.scroll.scrollTop).toBe(10100);
  f.list.resizeViewport(()=>{inset=100;});expect(f.scroll.scrollTop).toBe(10000);
  f.list.scrollToEnd();expect(f.scroll.scrollTop).toBe(f.scroll.scrollHeight-f.scroll.clientHeight);
 }finally{f.close();}
});

it('can correct an observer-delivered footer resize using the previous measured visible height',()=>{
 let inset=100;const f=fixture(()=>inset);try{
  f.list.setItems(f.rows);f.scroll.scrollTop=10000;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  // A native disclosure grows before ResizeObserver; the old negative margin is still applied.
  Object.defineProperty(f.scroll,'clientHeight',{value:300,configurable:true});
  f.list.resizeViewport(()=>{inset=200;Object.defineProperty(f.scroll,'clientHeight',{value:400,configurable:true});},300);
  expect(f.scroll.scrollTop).toBe(10100);
 }finally{f.close();}
});

it.each(['touch','wheel'])('keeps an upward %s reversal detached when output grows during bottom overscroll',kind=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;let top=bottom;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  const touch=(type:string,y:number)=>{const event=new Event(type);Object.defineProperty(event,'touches',{value:[{clientY:y}]});f.scroll.dispatchEvent(event);};
  if(kind==='touch'){touch('touchstart',200);touch('touchmove',100);}
  top=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));
  f.list.setItems([...f.rows,...Array.from({length:8},(_,i)=>({id:'live'+i,text:'Live output'}))]);
  if(kind==='touch')touch('touchmove',120);else f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-20}));
  top=bottom+20;f.scroll.dispatchEvent(new Event('scroll'));expect(f.list.followsLatest).toBe(false);expect(writes).toEqual([]);
  f.scroll.dispatchEvent(new Event('scrollend'));expect(top).toBe(bottom+20);expect(f.list.followsLatest).toBe(false);
 }finally{f.close();}
});
it.each(['visual','layout'])('retains the reading position after bottom overscroll with %s-relative content rectangles',mode=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;
  f.scroll.scrollTop=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.content.getBoundingClientRect=()=>({top:-(mode==='visual'?f.scroll.scrollTop:Math.min(bottom,Math.max(0,f.scroll.scrollTop))),width:600} as DOMRect);
  f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));f.scroll.scrollTop=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));f.scroll.dispatchEvent(new Event('scrollend'));
  expect(f.scroll.scrollTop).toBe(bottom-.25);expect(f.list.followsLatest).toBe(false);
 }finally{f.close();}
});

it('re-arms following as soon as a detached reader reaches bottom overscroll, before output grows',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;f.scroll.scrollTop=bottom-100;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();
  f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...f.rows,{id:'live',text:'Live output'}]);expect(f.scroll.scrollTop).toBe(bottom+40);
  f.scroll.scrollTop=bottom;f.scroll.dispatchEvent(new Event('scroll'));f.scroll.dispatchEvent(new Event('scrollend'));
  expect(f.scroll.scrollTop).toBe(bottom+100);expect(f.list.followsLatest).toBe(true);
 }finally{f.close();}
});
it('keeps following through a fractional native rebound without upward input',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));
  f.scroll.scrollTop=bottom-.25;f.scroll.dispatchEvent(new Event('scroll'));expect(f.list.followsLatest).toBe(true);
  f.scroll.dispatchEvent(new Event('scrollend'));f.list.setItems([...f.rows,{id:'live',text:'Live output'}]);
  expect(f.scroll.scrollTop).toBe(bottom+100);expect(f.list.followsLatest).toBe(true);
 }finally{f.close();}
});
it('finishes the elastic phase when scrollend reports a still-stretched native coordinate',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));
  f.scroll.dispatchEvent(new Event('scrollend'));expect(f.list.isOverscrolling).toBe(false);expect(f.scroll.scrollTop).toBe(bottom);
  f.list.setItems([...f.rows,{id:'live',text:'Live output'}]);expect(f.scroll.scrollTop).toBe(bottom+100);
 }finally{f.close();}
});
it('re-arms following after an upward elastic reversal returns down to a growing tail',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;f.scroll.scrollTop=bottom+40;f.scroll.dispatchEvent(new Event('scroll'));
  const live=[...f.rows,...Array.from({length:8},(_,i)=>({id:'live'+i,text:'Live output'}))];f.list.setItems(live);
  f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-20}));f.scroll.scrollTop=bottom+20;f.scroll.dispatchEvent(new Event('scroll'));expect(f.list.followsLatest).toBe(false);
  f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:100}));f.scroll.scrollTop=bottom+840;f.scroll.dispatchEvent(new Event('scroll'));expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...live,{id:'next',text:'More output'}]);f.scroll.scrollTop=bottom+800;f.scroll.dispatchEvent(new Event('scroll'));f.scroll.dispatchEvent(new Event('scrollend'));
  expect(f.scroll.scrollTop).toBe(bottom+900);expect(f.list.followsLatest).toBe(true);
 }finally{f.close();}
});

it('re-arms following on downward contact at the bottom even without a new scroll event',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);f.list.preservePosition();expect(f.list.followsLatest).toBe(false);
  f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:10}));expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...f.rows,{id:'live',text:'Live output'}]);expect(f.scroll.scrollTop).toBe(f.scroll.scrollHeight-f.scroll.clientHeight);
 }finally{f.close();}
});

it('does not keep writing against a native endpoint one pixel below rounded scroll bounds',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);let top=f.scroll.scrollHeight-f.scroll.clientHeight-1;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=Math.max(0,Math.min(value,f.scroll.scrollHeight-f.scroll.clientHeight-1));},configurable:true});
  f.list.refresh();f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(writes).toEqual([]);expect(f.list.followsLatest).toBe(true);
  f.list.setItems([...f.rows,{id:'new',text:'New output'}]);expect(f.scroll.scrollTop).toBe(f.scroll.scrollHeight-f.scroll.clientHeight-1);expect(f.list.followsLatest).toBe(true);
  writes.length=0;f.list.refresh();expect(writes).toEqual([]);
  f.list.preservePosition();f.scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:10}));expect(f.list.followsLatest).toBe(true);
 }finally{f.close();}
});
it('leaves the first one-pixel overscroll sample intact so native elasticity can begin',()=>{
 const f=fixture();try{
  f.list.setItems(f.rows);const bottom=f.scroll.scrollTop;let top=bottom+1;const writes:number[]=[];
  Object.defineProperty(f.scroll,'scrollTop',{get:()=>top,set:(value:number)=>{writes.push(value);top=value;},configurable:true});
  f.list.refresh();f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(writes).toEqual([]);expect(top).toBe(bottom+1);
  top=bottom+2;f.scroll.dispatchEvent(new Event('scroll'));f.list.refresh();expect(writes).toEqual([]);expect(f.list.isOverscrolling).toBe(true);
 }finally{f.close();}
});
