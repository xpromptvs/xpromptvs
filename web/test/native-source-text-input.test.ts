import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {mountNativeSourceTextInput} from '../src/client/native-source/text-input';
import {createClientSurface} from '../src/client/instance/surface';
import {createClientContext} from '../src/client/instance/context';
import {createMemoryPreferences} from '../src/client/instance/preferences';
import {decodeJson} from '../src/lib/codec';
const cleanups:(()=>void)[]=[];
beforeEach(()=>vi.useFakeTimers());afterEach(()=>{for(const cleanup of cleanups.splice(0).reverse())cleanup();vi.useRealTimers();});
function setup(source='win:1') {
  const surface=createClientSurface(document.body),context=createClientContext('ime',surface.root,surface.ui,createMemoryPreferences(),{layout:'floating'});
  const window=context.get('windows').appendChild(document.createElement('section'));
  const body=window.appendChild(document.createElement('div'));body.tabIndex=0;
  const messages:Record<string,unknown>[]=[];let active=true;
  const channel=Object.assign(new EventTarget(),{readyState:'open',label:'input',binaryType:'arraybuffer',send:(data:Uint8Array)=>messages.push(decodeJson(data))});
  const input=mountNativeSourceTextInput(context,body,source,channel as never,()=>active);
  cleanups.push(()=>{input.dispose();context.scope.dispose();surface.destroy();});
  return{input,messages,body,deactivate:()=>{active=false;}};
}
describe('native source text input in its presenting document',()=>{
  it('forwards hardware key down/up once and redirects picture DOM focus to its own editor',()=>{
    const t=setup();t.body.focus();expect(t.input.element.getRootNode()).toBe(t.body.getRootNode());
    t.input.element.dispatchEvent(new KeyboardEvent('keydown',{code:'KeyA',key:'a',bubbles:true,cancelable:true}));
    t.input.element.dispatchEvent(new KeyboardEvent('keyup',{code:'KeyA',key:'a',bubbles:true,cancelable:true}));
    expect(t.messages.map(m=>m.down)).toEqual([true,false]);
  });
  it('commits composed text once, ignoring composing keys and the redundant final beforeinput',()=>{
    const t=setup();t.input.element.dispatchEvent(new CompositionEvent('compositionstart'));
    t.input.element.dispatchEvent(new KeyboardEvent('keydown',{code:'KeyA',key:'Process',isComposing:true,cancelable:true}));
    t.input.element.dispatchEvent(new InputEvent('beforeinput',{inputType:'insertCompositionText',data:'あ',isComposing:true,cancelable:false}));
    expect(t.messages).toEqual([]);
    t.input.element.dispatchEvent(new CompositionEvent('compositionend',{data:'あ'}));
    t.input.element.dispatchEvent(new InputEvent('beforeinput',{inputType:'insertText',data:'あ',cancelable:true}));
    expect(t.messages.map(m=>m.code)).toEqual(['Unidentified','Unidentified']);
    expect(t.messages.map(m=>m.key)).toEqual(['あ','あ']);expect(t.messages.map(m=>m.down)).toEqual([true,false]);
  });
  it('a blur/release prevents a previous composition committing after reactivation',()=>{
    const t=setup();t.input.element.dispatchEvent(new CompositionEvent('compositionstart'));t.input.release();
    t.input.element.dispatchEvent(new CompositionEvent('compositionend',{data:'old'}));
    expect(t.messages).toEqual([]);
    t.input.element.dispatchEvent(new CompositionEvent('compositionstart'));t.input.element.dispatchEvent(new CompositionEvent('compositionend',{data:'new'}));
    expect(t.messages.filter(m=>m.down===true).map(m=>m.key)).toEqual(['n','e','w']);
  });
  it('simulator commits use sim-text and retired documents cannot send a late commit',()=>{
    const t=setup('sim:abc');t.input.element.dispatchEvent(new CompositionEvent('compositionstart'));t.input.element.dispatchEvent(new CompositionEvent('compositionend',{data:'你好'}));
    expect(t.messages).toEqual([{t:'sim-text',text:'你好'}]);
    t.input.element.dispatchEvent(new CompositionEvent('compositionstart'));t.deactivate();t.input.element.dispatchEvent(new CompositionEvent('compositionend',{data:'stale'}));
    expect(t.messages).toHaveLength(1);
  });
});
