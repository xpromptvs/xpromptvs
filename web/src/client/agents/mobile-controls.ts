import {element} from './dom';

/** The same model/effort/plan controls become a sheet on touch devices. No separate settings state. */
export class AgentMobileControls {
 private toggle=element('button','','Options');
 private panel=element('div','agent-compose-settings');
 private closeButton=element('button','','Close');
 private attach=element('button','agent-options-extra','Attach file');
 private stop=element('button','agent-options-extra','Stop current turn');
 private blocked=new Map<HTMLElement,boolean>();
 private resize?:ResizeObserver;
 private noticeObserver:MutationObserver;
 private opened=false;
 private $=(name:string)=>this.root.querySelector<HTMLElement>(`[data-agent="${name}"]`)!;
 constructor(private root:HTMLElement){
  const actions=root.querySelector<HTMLElement>('.agent-compose-actions')!,composer=this.$('composer');
  this.toggle.type=this.closeButton.type=this.attach.type=this.stop.type='button';
  this.toggle.dataset.agent='options';this.closeButton.dataset.agent='options-close';
  this.attach.dataset.agent='options-attach';this.stop.dataset.agent='options-stop';
  this.panel.dataset.agent='options-panel';this.panel.id='agent-options-'+crypto.randomUUID();
  this.panel.setAttribute('role','group');this.panel.setAttribute('aria-label','Session options');
  this.toggle.setAttribute('aria-controls',this.panel.id);this.toggle.setAttribute('aria-expanded','false');
  const heading=element('div','agent-options-heading');heading.append(element('strong','','Session options'),this.closeButton);
  const notice=element('p','agent-options-notice');
  this.panel.append(heading,notice);
  actions.insertBefore(this.toggle,this.$('model'));actions.insertBefore(this.panel,this.$('model'));
  for(const name of ['model','effort','plan','delivery','details']){
   const control=this.$(name);this.panel.append(name==='plan'?control.parentElement!:control);
  }
  this.panel.append(this.attach,this.stop);
  this.toggle.addEventListener('click',()=>this.open());this.closeButton.addEventListener('click',()=>this.close());
  this.attach.addEventListener('click',()=>{this.close(false);this.$('attach').click();});
  this.stop.addEventListener('click',()=>{this.close(false);this.$('stop').click();});
  this.$('details').addEventListener('click',()=>this.close(false));
  root.addEventListener('keydown',this.key);
  const updateNotice=()=>notice.textContent=this.$('notice').textContent;
  this.noticeObserver=new MutationObserver(updateNotice);this.noticeObserver.observe(this.$('notice'),{childList:true,characterData:true,subtree:true});updateNotice();
  if(typeof ResizeObserver==='function'){
   this.resize=new ResizeObserver(()=>{const height=composer.getBoundingClientRect().height;if(height>0)composer.parentElement!.style.setProperty('--agent-composer-height',`${Math.ceil(height)}px`);});
   this.resize.observe(composer);
  }
 }
 setEnabled(enabled:boolean,busy:boolean):void{
  this.toggle.disabled=!enabled;this.attach.disabled=!enabled||this.root.querySelector<HTMLButtonElement>('[data-agent="attach"]')!.disabled;this.stop.disabled=!enabled||!busy;
  if(!enabled)this.close(false);
 }
 get isOpen():boolean{return this.opened;}
 focusModel():void{
  if(this.root.ownerDocument.defaultView?.matchMedia?.('(any-pointer: coarse)').matches)this.open();
  this.$('model').focus({preventScroll:true});
 }
 private open():void{
  if(this.opened||this.toggle.disabled)return;this.opened=true;
  this.root.setAttribute('data-agent-options','');this.toggle.setAttribute('aria-expanded','true');
  this.panel.setAttribute('role','dialog');this.panel.setAttribute('aria-modal','true');
  const composer=this.$('composer'),actions=this.root.querySelector('.agent-compose-actions')!;
  const block=[...composer.parentElement!.children].filter(e=>e!==composer)
   .concat([...composer.children].filter(e=>e!==actions),[...actions.children].filter(e=>e!==this.panel));
  for(const element of block){const node=element as HTMLElement;this.blocked.set(node,Boolean(node.inert));node.inert=true;}
  this.closeButton.focus({preventScroll:true});
 }
 close(focus=true):void{
  if(!this.opened)return;this.opened=false;
  for(const[node,inert]of this.blocked)node.inert=inert;this.blocked.clear();
  this.root.removeAttribute('data-agent-options');this.toggle.setAttribute('aria-expanded','false');
  this.panel.setAttribute('role','group');this.panel.removeAttribute('aria-modal');
  if(focus)this.toggle.focus({preventScroll:true});
 }
 private key=(event:KeyboardEvent)=>{
  if(!this.opened)return;
  if(event.key==='Escape'){event.preventDefault();event.stopPropagation();this.close();return;}
  if(event.key!=='Tab')return;
  const controls=[...this.panel.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),a[href]')].filter(e=>e.getClientRects().length>0);
  const first=controls[0],last=controls.at(-1),active=(this.root.getRootNode() as Document|ShadowRoot).activeElement;
  if(event.shiftKey&&active===first){event.preventDefault();last?.focus();}
  else if(!event.shiftKey&&active===last){event.preventDefault();first?.focus();}
 };
 dispose():void{this.close(false);this.resize?.disconnect();this.noticeObserver.disconnect();this.root.removeEventListener('keydown',this.key);}
}
