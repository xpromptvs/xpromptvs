import {AgentProtocol,type AgentObject} from "./protocol";
import {AgentsView} from "./view";

type Options={root:HTMLElement;send:(message:AgentObject)=>void;onOpen?:()=>void;onHide?:()=>void;onSession?:(id:string)=>void;onCloseTab?:(id:string)=>void;hostSelectedTab?:()=>string|null};
/** Host-owned tabs keep their live view until the host removes the tab. One wire/authority epoch. */
export class AgentWorkspace {
 private wire:AgentProtocol;
 private panes=new Map<string,{root:HTMLElement;view:AgentsView}>();
 private members=new Set<string>();
 private selected:string|null=null;
 private active=false;
 private ended=false;
 private supportedProviders:string[]=[];
 get providers():readonly string[]{return this.supportedProviders;}
 private helloPending:Promise<AgentObject>|null=null;
 constructor(private options:Options){
  options.root.classList.add("agent-workspace");options.root.hidden=true;
  this.wire=new AgentProtocol(options.send,event=>{for(const pane of this.panes.values())pane.view.notify(event);});
 }
 get visible():boolean{return !this.options.root.hidden;}
 get selectedTab():string|null{return this.visible?this.selected:null;}
 receive(message:AgentObject):boolean{return this.wire.receive(message);}
 reportError(error:unknown):void{if(this.selected)this.panes.get(this.selected)?.view.reportError(error);}
 syncTabs(ids:readonly string[]):void{
  this.members=new Set(ids);
  for(const[id,pane]of this.panes)if(!this.members.has(id)){pane.view.dispose();pane.root.remove();this.panes.delete(id);}
 }
 private hello():Promise<AgentObject>{
  if(!this.helloPending)this.helloPending=this.wire.call("hello").then(hello=>{this.supportedProviders=Array.isArray(hello.providers)?hello.providers:["codex"];return hello;}).finally(()=>{this.helloPending=null;});
  return this.helloPending;
 }
 async search(query:string):Promise<AgentObject[]>{
  if(!this.active||this.ended)return[];
  if(!this.wire.epoch||!this.supportedProviders.length)await this.hello();
  return(await this.wire.call("list",undefined,query.trim()?{searchTerm:query.trim()}:{})).data??[];
 }
 async createClaudeSession(cwd:string):Promise<void>{
  if(!this.active||this.ended)throw Error("Connect to the host and take control first");
  if(!this.wire.epoch||!this.supportedProviders.length)await this.hello();
  if(!this.supportedProviders.includes("claude"))throw Error("Update Xpromptvs on the host and install Claude Code with Node.js to create Claude sessions");
  const result=await this.wire.call("new-thread",undefined,{cwd,provider:"claude"});
  if(typeof result.thread?.id!=="string")throw Error("The host did not return the Claude session");
  await this.openSession(result.thread.id);
 }
 async openSession(id:string):Promise<void>{
  if(!this.active||this.ended)return;
  if(!this.wire.epoch||!this.supportedProviders.length)await this.hello();
  await this.wire.call("open-tab",id);
  if(!this.options.hostSelectedTab||this.options.hostSelectedTab()===id)this.showSession(id);
 }
 async tabAction(op:"select-tab"|"close-tab",id:string):Promise<void>{
  if(!this.active||this.ended)return;
  if(!this.wire.epoch||!this.supportedProviders.length)await this.hello();
  await this.wire.call(op,id);
  if(op==="select-tab"&&(!this.options.hostSelectedTab||this.options.hostSelectedTab()===id))this.showSession(id);
 }
 showSession(id:string):void{
  if(!this.active||this.ended||!this.members.has(id))return;
  if(this.visible&&this.selected===id)return;
  if(this.selected!==id&&this.selected)this.panes.get(this.selected)?.view.hide();
  this.selected=id;let pane=this.panes.get(id);
  if(!pane){
   const root=document.createElement("section");root.dataset.agentThread=id;this.options.root.append(root);
   const view=new AgentsView({root,send:this.options.send,wire:this.wire,persistent:true,onSession:this.options.onSession,onCloseTab:this.options.onCloseTab});
   pane={root,view};this.panes.set(id,pane);view.setActive(this.active);
  }
  this.options.root.hidden=false;pane.view.showSession(id);this.options.onOpen?.();
 }
 hide():void{if(this.selected)this.panes.get(this.selected)?.view.hide();this.options.root.hidden=true;this.options.onHide?.();}
 setActive(active:boolean):void{
  if(this.active===active)return;this.active=active;
  if(!active){this.wire.reset();this.helloPending=null;this.supportedProviders=[];this.hide();}
  for(const pane of this.panes.values())pane.view.setActive(active);
 }
 connectionReset():void{
  this.wire.reset();this.helloPending=null;this.supportedProviders=[];
  for(const pane of this.panes.values())pane.view.connectionReset();
 }
 dispose():void{
  this.ended=true;this.wire.reset();for(const pane of this.panes.values())pane.view.dispose();this.panes.clear();this.options.root.replaceChildren();
 }
}
