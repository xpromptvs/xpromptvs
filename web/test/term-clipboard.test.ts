import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {TermClipboardReceiver} from '../src/client/term-clipboard';
const chunk=(text:string,extra:Record<string,unknown>={})=>{const bytes=new TextEncoder().encode(text);return {t:'term-clipboard',term:'tmux:$0',epoch:'7',copy:'copy-1',seq:0,count:1,bytes:bytes.length,data:btoa(String.fromCharCode(...bytes)),...extra};};
beforeEach(()=>vi.useFakeTimers());afterEach(()=>vi.useRealTimers());
function fixture(){let active=true;const write=vi.fn().mockResolvedValue(undefined),offer=vi.fn();const receiver=new TermClipboardReceiver({current:(term,epoch)=>active&&term==='tmux:$0'&&epoch===7n,write,offer});return {receiver,write,offer,inactive:()=>{active=false;receiver.reset();}};}
describe('tmux clipboard receiver',()=>{
 it('accepts exactly the one MiB ceiling without partial writes',()=>{
  const t=fixture(),part='a'.repeat(8192),data=btoa(part);
  for(let seq=0;seq<128;seq++){
   t.receiver.receive(chunk('',{seq,count:128,bytes:1048576,data}));
   expect(t.write).toHaveBeenCalledTimes(seq===127?1:0);
  }
  expect(t.write).toHaveBeenCalledWith('a'.repeat(1048576));t.receiver.reset();
 });
 it('preserves a leading U+FEFF character',()=>{const t=fixture();t.receiver.receive(chunk('\uFEFFtext'));expect(t.write).toHaveBeenCalledWith('\uFEFFtext');t.receiver.reset();});
 it('writes once and preserves Unicode and trailing newlines',async()=>{const t=fixture(),m=chunk('é🙂\n\n');t.receiver.receive(m);await vi.runAllTicks();expect(t.write).toHaveBeenCalledTimes(1);expect(t.write).toHaveBeenCalledWith('é🙂\n\n');t.receiver.receive(m);expect(t.write).toHaveBeenCalledTimes(1);t.receiver.reset();});
 it('assembles bytes before decoding even when a Unicode character crosses chunks',()=>{
  const t=fixture(),bytes=new TextEncoder().encode('x'.repeat(8191)+'🙂\n');
  for(let seq=0;seq<2;seq++){const part=bytes.subarray(seq*8192,(seq+1)*8192);t.receiver.receive(chunk('',{seq,count:2,bytes:bytes.length,data:btoa(String.fromCharCode(...part))}));}
  expect(t.write).toHaveBeenCalledTimes(1);expect(t.write).toHaveBeenCalledWith('x'.repeat(8191)+'🙂\n');t.receiver.reset();
 });
 it('drops inactive, stale epoch, malformed, oversized and non-tmux requests',()=>{const t=fixture();for(const extra of [{epoch:'6'},{term:'pty:1'},{bytes:1048577},{count:0},{seq:true},{data:'!'},{epoch:'0007'}])t.receiver.receive(chunk('x',extra));expect(t.write).not.toHaveBeenCalled();t.inactive();t.receiver.receive(chunk('x'));expect(t.write).not.toHaveBeenCalled();});
 it('drops an unfinished copy after handoff and never applies partial text',()=>{const t=fixture();t.receiver.receive(chunk('',{bytes:8193,count:2,data:btoa('a'.repeat(8192))}));expect(t.write).not.toHaveBeenCalled();t.inactive();t.receiver.receive(chunk('b',{seq:1,count:2,bytes:8193}));expect(t.write).not.toHaveBeenCalled();});
 it('offers a gesture retry when permission fails and clears it after success',async()=>{const t=fixture();t.write.mockRejectedValueOnce(Error('gesture required'));t.receiver.receive(chunk('copied'));await Promise.resolve();await Promise.resolve();expect(t.offer).toHaveBeenLastCalledWith(true);await t.receiver.retry();expect(t.write).toHaveBeenLastCalledWith('copied');expect(t.offer).toHaveBeenLastCalledWith(false);t.receiver.reset();});
 it('a late rejected write cannot revive a copy after ownership changed',async()=>{const t=fixture();let reject!:(e:Error)=>void;t.write.mockImplementation(()=>new Promise((_,r)=>{reject=r;}));t.receiver.receive(chunk('old'));t.inactive();reject(Error('blocked'));await Promise.resolve();await Promise.resolve();expect(t.offer).not.toHaveBeenLastCalledWith(true);await t.receiver.retry();expect(t.write).toHaveBeenCalledTimes(1);});
 it('expires incomplete assemblies and rejects out-of-order chunks',()=>{const t=fixture();t.receiver.receive(chunk('',{bytes:8193,count:2,data:btoa('a'.repeat(8192))}));vi.advanceTimersByTime(5001);t.receiver.receive(chunk('b',{seq:1,count:2,bytes:8193}));expect(t.write).not.toHaveBeenCalled();t.receiver.reset();});
});
