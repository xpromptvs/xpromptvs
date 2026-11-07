import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {SourceFocusGate} from '../src/client/native-source/focus';
import {encodeJson} from '../src/lib/codec';
const a={owner:1,generation:1,source:'win:1',incarnation:1}, b={...a,source:'win:2'};
beforeEach(()=>vi.useFakeTimers());afterEach(()=>vi.useRealTimers());
function setup(){
  const control=vi.fn(),input=vi.fn(),state=vi.fn();
  const gate=new SourceFocusGate({control,input,now:()=>Date.now(),requestId:()=> 'fixture',state});
  gate.open();gate.setDriving(true);
  const capable=()=>gate.receive({t:'source-input-capabilities',v:1});
  const request=()=>control.mock.calls.filter(([m])=>m.t==='source-focus').at(-1)?.[0].request as string;
  const ack=(source:string|null,lease='lease')=>gate.receive({t:'source-focus',source,request:request(),...(source?{lease}:{})});
  return{gate,control,input,state,capable,request,ack};
}
const down={t:'win-key',down:true,code:'KeyA',key:'a',mods:0};
describe('native source focus leases',()=>{
  it('enables simulator gestures only after that source lease confirms a prepared cancellation transport',()=>{
    const t=setup(),sim={...a,source:'sim:fixture'};
    t.gate.receive({t:'source-input-capabilities',v:1,scrollGestures:['window','display']});t.gate.activate(sim);
    expect(t.state.mock.lastCall?.[0].scrollGestures).not.toContain('simulator');
    t.gate.receive({t:'source-focus',source:sim.source,request:t.request(),lease:'sim-lease',scrollGestures:['simulator']});
    expect(t.state.mock.lastCall?.[0].scrollGestures).toEqual(['simulator']);
    t.gate.activate(a);expect(t.state.mock.lastCall?.[0].scrollGestures).toEqual(['window','display']);t.gate.dispose();
  });
  it('advertises native scroll only for the current admission and carries boundaries inside the lease',()=>{
    const t=setup();t.gate.receive({t:'source-input-capabilities',v:1,scrollGestures:['window','display']});
    t.gate.activate(a);t.ack(a.source);
    t.gate.send(a,encodeJson({t:'scroll-gesture',phase:'end',x:.5,y:.5,vx:0,vy:500}));
    expect(t.input.mock.lastCall?.[0]).toMatchObject({t:'source-input',source:'win:1',event:{t:'scroll-gesture',phase:'end'}});
    expect(t.state.mock.lastCall?.[0].scrollGestures).toEqual(['window','display']);
    t.gate.open();expect(t.state.mock.lastCall?.[0].scrollGestures).toEqual([]);t.gate.dispose();
  });
  it('fails closed on old or malformed capabilities, never emitting legacy input',()=>{
    const t=setup();t.gate.activate(a);t.gate.send(a,encodeJson(down));
    t.gate.receive({t:'source-input-capabilities',v:true});t.gate.receive({t:'source-input-capabilities',v:2});
    expect(t.control.mock.calls.map(([m])=>m.t)).toEqual(['source-input-capabilities']);expect(t.input).not.toHaveBeenCalled();
    t.gate.dispose();
  });
  it('buffers the first chord until the matching host commit and has no later round trip',()=>{
    const t=setup();t.capable();t.gate.activate(a);
    t.gate.send(a,encodeJson(down));t.gate.send(a,encodeJson({...down,down:false}));expect(t.input).not.toHaveBeenCalled();
    t.ack(a.source);expect(t.input.mock.calls.map(([m])=>m.event.down)).toEqual([true,false]);
    const controls=t.control.mock.calls.length;t.gate.send(a,encodeJson({t:'hover',x:.2,y:.3}));
    expect(t.input.mock.lastCall?.[0]).toMatchObject({t:'source-input',source:a.source,lease:'lease',event:{t:'hover'}});
    expect(t.control).toHaveBeenCalledTimes(controls);t.gate.dispose();
  });
  it('rejects old A acknowledgments after A to B to A, including the same source ID',()=>{
    const t=setup();t.capable();t.gate.activate(a);const old=t.request();t.gate.send(a,encodeJson(down));
    t.gate.activate(b);t.gate.activate(a);expect(t.request()).not.toBe(old);
    t.gate.receive({t:'source-focus',source:a.source,request:old,lease:'old'});expect(t.input).not.toHaveBeenCalled();
    t.gate.send(a,encodeJson(down));t.ack(a.source,'fresh');expect(t.input.mock.lastCall?.[0].lease).toBe('fresh');t.gate.dispose();
  });
  it('never accepts input from another owner or a retired incarnation',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.ack(a.source);
    t.gate.send({...a,owner:2},encodeJson(down));t.gate.send({...a,incarnation:2},encodeJson(down));expect(t.input).not.toHaveBeenCalled();
    t.gate.retire({...a,incarnation:2});t.gate.send(a,encodeJson(down));expect(t.input).toHaveBeenCalledTimes(1);
    t.gate.retire(a);const count=t.input.mock.calls.length;t.gate.send(a,encodeJson(down));expect(t.input).toHaveBeenCalledTimes(count);t.gate.dispose();
  });
  it('drops the entire expired chord rather than replaying its remaining keyup',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.gate.send(a,encodeJson(down));vi.advanceTimersByTime(501);
    t.gate.send(a,encodeJson({...down,down:false}));t.ack(a.source);expect(t.input).not.toHaveBeenCalled();t.gate.dispose();
  });
  it('coalesces consecutive motion but drops a whole queue on overflow',()=>{
    const t=setup();t.capable();t.gate.activate(a);
    for(let i=0;i<100;i++)t.gate.send(a,encodeJson({t:'hover',x:i/100,y:.2}));
    t.ack(a.source);expect(t.input).toHaveBeenCalledTimes(1);expect(t.input.mock.lastCall?.[0].event.x).toBe(.99);
    t.gate.activate(b);t.input.mockClear();for(let i=0;i<65;i++)t.gate.send(b,encodeJson(down));t.ack(b.source);expect(t.input).not.toHaveBeenCalled();t.gate.dispose();
  });
  it('invalidates admission leases across reconnect and requires a fresh capability',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.ack(a.source);const old=t.request();
    t.gate.open();t.input.mockClear();t.gate.send(a,encodeJson(down));
    t.gate.receive({t:'source-focus',source:a.source,request:old,lease:'old'});expect(t.input).not.toHaveBeenCalled();
    t.capable();t.ack(a.source,'new');expect(t.input.mock.lastCall?.[0].lease).toBe('new');t.gate.dispose();
  });
  it('terminal focus releases the old lease and never changes source membership',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.ack(a.source);t.gate.activate(null);
    expect(t.input.mock.lastCall?.[0]).toMatchObject({source:a.source,lease:'lease',event:{t:'win-keys-release'}});
    expect(t.control.mock.lastCall?.[0]).toMatchObject({t:'source-focus',source:null});t.ack(null);
    expect(t.control.mock.calls.some(([m])=>['unsubscribe','focus-source','set-view'].includes(m.t))).toBe(false);t.gate.dispose();
  });
  it('host refusal discards buffered input and a later fresh activation can retry',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.gate.send(a,encodeJson(down));
    t.gate.receive({t:'source-focus',source:a.source,request:t.request(),error:'focus-unavailable'});
    expect(t.state.mock.lastCall?.[0]).toMatchObject({state:'unavailable',key:a});expect(t.input).not.toHaveBeenCalled();
    t.gate.activate(a);t.gate.send(a,encodeJson(down));t.ack(a.source);expect(t.input).toHaveBeenCalledOnce();t.gate.dispose();
  });
  it('driver handoff and malformed/nested payloads cannot bypass the scoped input allowlist',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.ack(a.source);
    for(const payload of [{t:'source-input',source:b.source,event:down},{t:'subscribe',source:b.source},{t:'term-input'},null])t.gate.send(a,encodeJson(payload));
    expect(t.input).not.toHaveBeenCalled();t.gate.setDriving(false);t.input.mockClear();t.gate.send(a,encodeJson(down));expect(t.input).not.toHaveBeenCalled();
    t.gate.dispose();
  });
  it('a ready-state callback switching sources cannot flush the old chord into the new one',()=>{
    const t=setup();t.capable();t.gate.activate(a);t.gate.send(a,encodeJson(down));
    t.state.mockImplementationOnce(()=>t.gate.activate(b));t.ack(a.source);
    expect(t.input.mock.calls.filter(([m])=>m.event.t!=='win-keys-release')).toEqual([]);t.gate.dispose();
  });

  it('reports an unsupported host after bounded negotiation without sending input',()=>{
    const t=setup();t.gate.activate(a);t.gate.send(a,encodeJson(down));vi.advanceTimersByTime(2001);
    expect(t.state.mock.lastCall?.[0]).toMatchObject({state:'unavailable',reason:'host-update-required'});
    expect(t.input).not.toHaveBeenCalled();t.gate.dispose();
  });

});
