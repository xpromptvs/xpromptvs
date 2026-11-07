import {afterEach,expect,it,vi} from 'vitest';
import type {AgentObject} from '../src/client/agents/protocol';
import {AgentImages} from '../src/client/agents/images';
let intersection:(entries:{target:Element;isIntersecting:boolean}[])=>void;
function setup(fetch:ConstructorParameters<typeof AgentImages>[1]){
 vi.stubGlobal('IntersectionObserver',class{constructor(cb:typeof intersection){intersection=cb;}observe(){}unobserve(){}disconnect(){}});
 const scroll=document.body.appendChild(document.createElement('div'));
 const images=new AgentImages(scroll,fetch);images.setVisible(true);
 const slot=images.slot('thread',{id:'i',_turn:'turn'},'/image.png');scroll.append(slot);
 return{images,scroll,slot,near:()=>intersection([{target:slot,isIntersecting:true}])};
}
afterEach(()=>{document.body.replaceChildren();vi.unstubAllGlobals();vi.restoreAllMocks();vi.useRealTimers();});
const info={width:800,height:400,mime:'image/png',name:'image.png'};
it('retries a just-sent image before persistence, but cancels retry timers when hidden',async()=>{
 vi.useFakeTimers();const fetch=vi.fn().mockRejectedValueOnce(Error('This record has not been persisted by Claude yet')).mockResolvedValueOnce(info).mockResolvedValue({mime:'image/png',data:'AQID'});
 const{images,slot,near}=setup(fetch);near();await vi.runAllTimersAsync();
 expect(fetch).toHaveBeenCalledTimes(3);expect(slot.querySelector('img')).not.toBeNull();images.dispose();
 const later=vi.fn().mockRejectedValue(Error('This record has not been persisted by Claude yet'));const second=setup(later);second.near();
 await Promise.resolve();await Promise.resolve();second.images.setVisible(false);await vi.runAllTimersAsync();expect(later).toHaveBeenCalledTimes(1);second.images.dispose();
 const never=vi.fn().mockRejectedValue(Error('Sent image has not been persisted yet'));const third=setup(never);third.near();
 await vi.runAllTimersAsync();expect(never).toHaveBeenCalledTimes(4);expect(third.slot.querySelector('button')?.textContent).toBe('Show image');third.images.dispose();
});
it('keeps a decoded BlurHash placeholder until full image decoding finishes',async()=>{
 vi.spyOn(HTMLCanvasElement.prototype,'getContext').mockReturnValue({createImageData:()=>({data:new Uint8ClampedArray(32*32*4)}),putImageData:()=>{}} as unknown as GPUCanvasContext);
 let pixels!:(v:AgentObject)=>void;const fetch=vi.fn((op:string)=>op==='asset-info'?Promise.resolve({...info,blurhash:'K~TI:j|cfQ|c$5fQfQfQfQ'}):new Promise<AgentObject>(r=>{pixels=r;}));
 const{images,slot,near}=setup(fetch);near();await vi.waitFor(()=>expect(slot.querySelector('canvas')).not.toBeNull());
 pixels({mime:'image/png',data:'AQID'});await vi.waitFor(()=>expect(slot.querySelector('img')).not.toBeNull());
 const image=slot.querySelector('img')!;let decoded!:()=>void;image.decode=()=>new Promise<void>(r=>{decoded=r;});
 image.dispatchEvent(new Event('load'));expect(slot.querySelector('canvas')).not.toBeNull();decoded();
 await vi.waitFor(()=>expect(slot.querySelector('canvas')).toBeNull());expect(image.classList.contains('agent-image-loading')).toBe(false);images.dispose();
});
it('does not fetch offscreen images; measures then reserves space before fetching pixels',async()=>{
 let pixels!:(value:AgentObject)=>void;
 const fetch=vi.fn((op:string)=>op==='asset-info'?Promise.resolve(info):new Promise<AgentObject>(resolve=>{pixels=resolve;}));
 const{images,slot,near}=setup(fetch);expect(fetch).not.toHaveBeenCalled();near();
 await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(2));
 expect(fetch.mock.calls.map(c=>c[0])).toEqual(['asset-info','asset']);
 expect(slot.style.aspectRatio).toBe('800 / 400');expect(slot.querySelector('img')).toBeNull();
 pixels({mime:'image/png',data:'AQID',name:'image.png'});
 await vi.waitFor(()=>expect(slot.querySelector('img')?.width).toBe(800));
 expect(slot.querySelector('img')?.height).toBe(400);images.dispose();
});
it('passes exact sent-image turn and item references through lazy requests',async()=>{
 const fetch=vi.fn(async()=>info);const{images,scroll}=setup(fetch);
 const slot=images.slot('thread',{id:'sent',_turn:'turn'},'input:1');scroll.append(slot);
 intersection([{target:slot,isIntersecting:true}]);
 await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(2));
 expect(fetch.mock.calls[0]).toEqual(['asset-info','thread',{item:'sent',path:'input:1',turnId:'turn'}]);images.dispose();
});
it('keeps a manual fallback for unmeasurable files and ignores reset responses',async()=>{
 const fetch=vi.fn().mockRejectedValue(Error('missing'));const{images,slot,near}=setup(fetch);near();
 await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(1));
 expect(slot.querySelector('button')?.textContent).toBe('Show image');expect(slot.querySelector('img')).toBeNull();
 images.reset();let resolve!:(value:AgentObject)=>void;fetch.mockImplementation(()=>new Promise(r=>{resolve=r;}));
 const next=images.slot('thread',{id:'next'},'/next.png');document.body.append(next);intersection([{target:next,isIntersecting:true}]);
 await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(2));images.reset();resolve(info);
 await Promise.resolve();await Promise.resolve();expect(fetch).toHaveBeenCalledTimes(2);expect(next.querySelector('img')).toBeNull();images.dispose();
});
it('limits concurrent work and does not start pixel reads after the tab is hidden',async()=>{
 const waits:((v:AgentObject)=>void)[]=[];const fetch=vi.fn(()=>new Promise<AgentObject>(resolve=>waits.push(resolve)));
 const{images,scroll,slot}=setup(fetch);const slots=[slot,...Array.from({length:4},(_,i)=>images.slot('thread',{id:String(i)},'/'+i+'.png'))];scroll.append(...slots);
 intersection(slots.map(target=>({target,isIntersecting:true})));expect(fetch).toHaveBeenCalledTimes(2);
 images.setVisible(false);waits.forEach(resolve=>resolve(info));await Promise.resolve();await Promise.resolve();
 expect(fetch).toHaveBeenCalledTimes(2);images.dispose();
});
it('allows a manual fallback and does not download pixels for a released metadata slot',async()=>{
 const fetch=vi.fn().mockRejectedValueOnce(Error('unmeasurable')).mockResolvedValue({mime:'image/png',data:'AQID'});
 const{images,slot,near,scroll}=setup(fetch);near();await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(1));
 await vi.waitFor(()=>expect(slot.hasAttribute('data-measured')).toBe(false));
 await vi.waitFor(()=>expect(slot.querySelector('button')!.disabled).toBe(false));
 slot.querySelector('button')!.click();await vi.waitFor(()=>expect(slot.querySelector('img')).not.toBeNull());
 expect(fetch.mock.calls.map(c=>c[0])).toEqual(['asset-info','asset']);
 let resolve!:(v:AgentObject)=>void;fetch.mockImplementation(()=>new Promise(r=>{resolve=r;}));
 const next=images.slot('thread',{id:'released'},'/released.png');scroll.append(next);intersection([{target:next,isIntersecting:true}]);
 await vi.waitFor(()=>expect(fetch).toHaveBeenCalledTimes(3));images.release(next);next.remove();resolve(info);
 await Promise.resolve();await Promise.resolve();expect(fetch).toHaveBeenCalledTimes(3);images.dispose();
});
it('reuses measured cached images, but refetches evicted pixels on demand',async()=>{
 const fetch=vi.fn(async(op:string)=>op==='asset-info'?info:{mime:'image/png',data:'A'.repeat(17*1024*1024)});
 const{images,slot,scroll,near}=setup(fetch);near();await vi.waitFor(()=>expect(slot.querySelector('img')).not.toBeNull());
 images.release(slot);slot.remove();
 const second=images.slot('thread',{id:'second'},'/second.png');scroll.append(second);intersection([{target:second,isIntersecting:true}]);
 await vi.waitFor(()=>expect(second.querySelector('img')).not.toBeNull());expect(fetch).toHaveBeenCalledTimes(4);
 const again=images.slot('thread',{id:'i',_turn:'turn'},'/image.png');scroll.append(again);
 expect(again.querySelector('img')).toBeNull();intersection([{target:again,isIntersecting:true}]);
 await vi.waitFor(()=>expect(again.querySelector('img')).not.toBeNull());expect(fetch).toHaveBeenCalledTimes(5);
 expect(fetch.mock.calls.at(-1)?.[0]).toBe('asset');images.dispose();
});
