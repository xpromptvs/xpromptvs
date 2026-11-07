import type {ClientContext} from '../instance/context';
import type {ChannelLike} from '../../lib/channel';
import {encodeJson} from '../../lib/codec';
import {attachWindowKeys} from '../keys';
import {charMessages} from '../window-keys';

/** A desktop text editor belongs to the presenting document. Physical keys keep the existing
 * down/up path; composition commits become text only once, never intermediate IME edits. */
export function mountNativeSourceTextInput(context:ClientContext,body:HTMLElement,source:string,channel:ChannelLike,isActive:()=>boolean) {
  const element=body.ownerDocument.createElement('textarea');
  element.className='native-source-text-input';element.tabIndex=-1;
  element.setAttribute('aria-label','Keyboard input for this window');element.autocomplete='off';element.spellcheck=false;
  element.setAttribute('autocorrect','off');element.setAttribute('autocapitalize','off');
  element.style.cssText='position:fixed;left:12px;bottom:12px;width:1px;height:1px;opacity:0;pointer-events:none;padding:0;border:0;resize:none;';
  // A sibling, never inside the picture: its key events must not bubble through the picture's
  // existing attachWindowKeys listener and produce a duplicate physical key.
  body.parentElement!.appendChild(element);
  const listeners=new AbortController(),{signal}=listeners;
  let disposed=false,epoch=0,composition:{epoch:number;committed:boolean}|undefined;
  let recent:string|undefined,recentTimer:ReturnType<typeof setTimeout>|undefined;
  const enabled=()=>!disposed&&!context.scope.disposed&&isActive();
  const send=(message:unknown)=>{if(enabled())channel.send(encodeJson(message) as Uint8Array<ArrayBuffer>);};
  const text=(value:string)=>{
    if(!value||!enabled())return;
    if(source.startsWith('sim:'))send({t:'sim-text',text:value});
    else for(const character of value)for(const message of charMessages(character,0)) {
      // Committed text may have no physical key. The wire requires a nonempty DOM code;
      // Unidentified lets the host's existing Unicode override supply the character.
      send({...message,code:message.code||'Unidentified'});
    }
  };
  const forgetRecent=()=>{recent=undefined;if(recentTimer)clearTimeout(recentTimer);recentTimer=undefined;};
  const release=()=>{epoch++;composition=undefined;element.value='';forgetRecent();};
  const focus=()=>{if(enabled())element.focus({preventScroll:true});};
  attachWindowKeys(element,channel,enabled);
  body.addEventListener('focus',focus,{signal});
  // The pointer capture handler already gave this picture's editor focus. WebKit's default
  // mousedown would focus the picture again after pointerdown, blur the editor, and release the
  // remote press/modifiers mid-gesture. Keep pointer events; suppress only that default action.
  body.addEventListener('mousedown',event=>event.preventDefault(),{signal});
  body.addEventListener('pointerdown',event=>{
    const e=event as PointerEvent;
    element.style.left=`${Math.max(0,e.clientX)}px`;element.style.top=`${Math.max(0,e.clientY)}px`;element.style.bottom='auto';
  },{signal,capture:true});
  element.addEventListener('keydown',event=>{if(!event.isComposing)forgetRecent();},{signal});
  element.addEventListener('compositionstart',()=>{
    forgetRecent();composition=enabled()?{epoch,committed:false}:undefined;
  },{signal});
  element.addEventListener('compositionend',event=>{
    const pending=composition;composition=undefined;
    if(pending&&pending.epoch===epoch&&enabled()){
      if(!pending.committed)text(event.data);
      recent=event.data;recentTimer=setTimeout(forgetRecent,0);
    }
    element.value='';
  },{signal});
  element.addEventListener('beforeinput',event=>{
    const e=event as InputEvent;
    if(e.isComposing)return; // Let WebKit keep its own marked text/candidate UI until commit.
    e.preventDefault();
    if(!enabled())return;
    if(e.inputType==='insertFromComposition'){
      if(composition&&composition.epoch===epoch&&!composition.committed){text(e.data??'');composition.committed=true;}
      element.value='';return;
    }
    if(composition)return;
    if(e.data&&e.data===recent){forgetRecent();return;}
    forgetRecent();
    const named:Record<string,string>={deleteContentBackward:'Backspace',deleteContentForward:'Delete',insertLineBreak:'Enter',insertParagraph:'Enter'};
    const key=named[e.inputType];
    if(key){for(const down of [true,false])send({t:'win-key',down,code:key,key,mods:0,repeat:false});}
    else text(e.data??'');
    element.value='';
  },{signal});
  element.addEventListener('input',event=>{if(!(event as InputEvent).isComposing)element.value='';},{signal});
  context.root.ownerDocument.defaultView!.addEventListener('blur',release,{signal});
  const dispose=()=>{if(disposed)return;disposed=true;release();listeners.abort();element.remove();};
  context.scope.defer(dispose,'native-source-text-input');
  return{element,focus,release,dispose};
}
