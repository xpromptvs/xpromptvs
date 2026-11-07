import {describe,it,expect} from 'vitest';
import {NativeSourceScroll,type NativeScrollBatch} from '../src/client/native-source/scroll';
function setup(){
  const sent:Record<string,unknown>[]=[];let enabled=true,picture=true;
  const scroll=new NativeSourceScroll({enabled:()=>enabled,viewport:()=>({width:400,height:300}),
    target:()=>picture?{left:100,top:50,width:200,height:200,scale:0.5}:undefined,send:m=>sent.push(m)});
  let sequence=0;
  const batch=(events:NativeScrollBatch['events'],extra:Partial<NativeScrollBatch>={})=>({sequence:++sequence,gesture:1,x:0.5,y:0.5,width:400,height:300,mods:1,events,...extra});
  return{scroll,sent,batch,disable:()=>{enabled=false;},local:()=>{picture=false;}};
}
describe('native source scroll presentation',()=>{
  it('keeps DOM fallback through a gesture whose begin preceded negotiation',()=>{
    let enabled=false;const sent:Record<string,unknown>[]=[];
    const scroll=new NativeSourceScroll({enabled:()=>enabled,viewport:()=>({width:400,height:300}),
      target:()=>({left:0,top:0,width:400,height:300,scale:1}),send:m=>sent.push(m)});
    const base={gesture:1,x:.5,y:.5,width:400,height:300,mods:0};
    scroll.handle({...base,sequence:1,events:[{kind:'begin'}]});enabled=true;
    expect(scroll.suppressesDOM()).toBe(false);
    scroll.handle({...base,sequence:2,events:[{kind:'scroll',dx:0,dy:10,precise:true}]});
    scroll.handle({...base,sequence:3,events:[{kind:'end',vx:0,vy:500}]});
    expect(scroll.suppressesDOM()).toBe(false);expect(sent).toEqual([]);
    scroll.handle({...base,gesture:2,sequence:4,events:[{kind:'begin'}]});
    expect(scroll.suppressesDOM()).toBe(true);expect(sent).toHaveLength(1);
  });
  it('uses the release modifier snapshot for host inertia',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'begin'}],{mods:1}));
    t.scroll.handle(t.batch([{kind:'end',vx:0,vy:500}],{mods:0}));
    expect(t.sent.at(-1)).toMatchObject({phase:'end',mods:0});
  });
  it('scales motion and one release velocity into host points',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'begin'},{kind:'scroll',dx:3,dy:4,precise:true}]));
    t.scroll.handle(t.batch([{kind:'end',vx:300,vy:400}]));
    expect(t.sent).toEqual([
      {t:'scroll-gesture',phase:'begin',x:0.5,y:0.5,vx:0,vy:0,mods:1},
      {t:'scroll',x:0.5,y:0.5,dx:6,dy:8,unit:'px',mods:1},
      {t:'scroll-gesture',phase:'end',x:0.5,y:0.5,vx:600,vy:800,mods:1},
    ]);
  });
  it('keeps the gesture anchor through a pointer leaving the picture',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'begin'}]));t.local();
    t.scroll.handle(t.batch([{kind:'scroll',dx:0,dy:10,precise:true}],{x:2,y:-1}));
    t.scroll.handle(t.batch([{kind:'end',vx:0,vy:500}]));
    expect(t.sent.at(-1)).toMatchObject({phase:'end',x:0.5,y:0.5,vy:1000});
  });
  it('does not forward local controls or disabled old-host presentations',()=>{
    const t=setup();t.local();t.scroll.handle(t.batch([{kind:'begin'},{kind:'scroll',dx:0,dy:10,precise:true}]));
    t.scroll.handle(t.batch([{kind:'end',vx:0,vy:500}]));expect(t.sent).toEqual([]);
    const old=setup();old.disable();old.scroll.handle(old.batch([{kind:'begin'},{kind:'scroll',dx:0,dy:10,precise:true}]));expect(old.sent).toEqual([]);
  });
  it('ignores stale callbacks and releases once on retirement',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'begin'}],{gesture:2,sequence:5}));
    t.scroll.handle(t.batch([{kind:'end',vx:0,vy:500}],{gesture:1,sequence:4}));
    t.scroll.cancel();t.scroll.cancel();
    expect(t.sent.map(m=>m.phase)).toEqual(['begin','cancel']);
  });
  it('preserves line wheel notches and does not turn them into a gesture',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'scroll',dx:0,dy:3,precise:false}],{gesture:0}));
    expect(t.sent).toEqual([{t:'scroll',x:0.5,y:0.5,dx:0,dy:3,unit:'line',mods:1}]);
  });
  it('does not acquire a contact that began on local UI when its pointer later enters the picture',()=>{
    const t=setup();t.local();t.scroll.handle(t.batch([{kind:'begin'}]));
    // Another positive gesture ID with no accepted begin must not forward even if a target exists.
    const other=setup();other.scroll.handle(other.batch([{kind:'scroll',dx:0,dy:10,precise:true}],{gesture:4}));
    expect(other.sent).toEqual([]);expect(t.sent).toEqual([]);
  });
  it('preserves the existing ctrl-wheel suppression and cancels rather than launching on it',()=>{
    const t=setup();t.scroll.handle(t.batch([{kind:'begin'}],{mods:0}));
    t.scroll.handle(t.batch([{kind:'scroll',dx:0,dy:10,precise:true}],{mods:2}));
    expect(t.sent.map(e=>e.phase)).toEqual(['begin','cancel']);
  });
});
