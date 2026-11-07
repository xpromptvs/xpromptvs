import type {AgentObject} from './protocol';
import {element} from './dom';
const statuses:Record<string,string>={active:'Active',paused:'Paused',blocked:'Blocked',usageLimited:'Usage limited',budgetLimited:'Budget limited',complete:'Complete'};
function text(node:HTMLElement,value:string):void{if(node.textContent!==value)node.textContent=value;}
function tokens(value:number):string{return value>=1e6?(value/1e6).toFixed(1).replace(/\.0$/,'')+'M':value>=1000?(value/1000).toFixed(1).replace(/\.0$/,'')+'K':String(Math.floor(value));}
function elapsed(value:number):string{const seconds=Math.floor(value);return seconds>=3600?`${Math.floor(seconds/3600)}h ${Math.floor(seconds%3600/60)}m`:seconds>=60?`${Math.floor(seconds/60)}m${seconds%60?' '+seconds%60+'s':''}`:`${seconds}s`;}
function objective(value:string):string{const text=value.trim();if(!text)throw Error('Enter a goal objective');if(new TextEncoder().encode(text).length>128*1024)throw Error('Goal objective must be within 128 KiB');return text;}
/** Retained goal controls; every mutation is an explicit user action, never a paint effect. */
export class AgentGoal{
 private goal:AgentObject|null=null;
 private enabled=false;
 private supported=true;
 private busy=false;
 private opened=false;
 private editing=false;
 private generation=0;
 private key='';
 private details=element('details');
 private title=element('span','agent-goal-objective');
 private status=element('span','agent-goal-status');
 private usage=element('span','agent-goal-usage');
 private full=element('div','agent-goal-full');
 private actions=element('div','agent-goal-actions');
 private form=element('form','agent-goal-editor');
 private input=element('textarea');
 private budget=element('input');
 private pause=element('button','','Pause');
 constructor(private root:HTMLElement,private options:{change:(fn:()=>void)=>void;mutate:(op:'goal-set'|'goal-clear',args:AgentObject)=>Promise<void>;error?:(error:unknown)=>void}){
  root.className='agent-goal';root.dataset.agent='goal';root.setAttribute('aria-label','Session goal');root.hidden=true;
  const summary=element('summary');summary.append(element('strong','','Goal'),this.status,this.title,this.usage);
  summary.addEventListener('click',event=>{event.preventDefault();this.options.change(()=>{this.details.open=!this.details.open;});});
  const body=element('div','agent-goal-body');
  const edit=element('button','','Edit'),clear=element('button','','Clear');edit.type=this.pause.type=clear.type='button';
  edit.addEventListener('click',()=>this.openEditor());this.pause.addEventListener('click',()=>this.run(()=>this.command(this.goal?.status==='active'?'pause':'resume')));clear.addEventListener('click',()=>this.run(()=>this.command('clear')));
  this.actions.append(edit,this.pause,clear);
  const objectiveLabel=element('label','','Objective');this.input.dataset.goal='objective';this.input.setAttribute('aria-label','Goal objective');this.input.rows=3;objectiveLabel.append(this.input);
  const budgetLabel=element('label','','Token budget (optional)');this.budget.type='number';this.budget.min='1';this.budget.step='1';this.budget.dataset.goal='budget';this.budget.setAttribute('aria-label','Goal token budget');budgetLabel.append(this.budget);
  const save=element('button','','Save goal'),cancel=element('button','','Cancel');save.type='submit';cancel.type='button';cancel.addEventListener('click',()=>{this.editing=false;this.opened=false;this.key='';this.paint();});
  this.form.append(objectiveLabel,budgetLabel,save,cancel);this.form.addEventListener('submit',event=>{event.preventDefault();this.run(async()=>{
   const args:AgentObject={objective:objective(this.input.value),status:['paused','blocked','usageLimited'].includes(this.goal?.status)?this.goal!.status:'active'};
   if(this.budget.value){const value=Number(this.budget.value);if(!Number.isSafeInteger(value)||value<=0)throw Error('Token budget must be a positive whole number');args.tokenBudget=value;}
   else if(this.goal?.tokenBudget!=null)args.tokenBudget=null;
   await this.perform('goal-set',args);
  });});
  body.append(this.full,this.actions,this.form);this.details.append(summary,body);root.append(this.details);this.paint();
 }
 update(goal:AgentObject|null|undefined,enabled:boolean,supported:boolean):void{
  this.goal=goal??null;this.enabled=enabled;this.supported=supported;this.paint();
 }
 reset():void{this.generation++;this.goal=null;this.busy=false;this.opened=false;this.editing=false;this.key='';this.paint(false);}
 private paint(open?:boolean):void{
  const key=JSON.stringify([this.goal,this.enabled,this.supported,this.busy,this.opened,this.editing]);if(key===this.key&&open===undefined)return;this.key=key;
  this.options.change(()=>{
   if(open!==undefined)this.details.open=open;
   const goal=this.goal;this.root.hidden=!this.supported||!goal&&!this.opened&&!this.editing;this.root.dataset.status=goal?.status??'';
   text(this.title,goal?.objective??'Set a goal');this.title.title=goal?.objective??'';text(this.status,goal?statuses[goal.status]??'Unknown':'');
   const used=Number.isFinite(goal?.tokensUsed)&&goal!.tokensUsed>=0?tokens(goal!.tokensUsed):null;
   const budget=Number.isFinite(goal?.tokenBudget)&&goal!.tokenBudget>0?tokens(goal!.tokenBudget):null;
   const time=Number.isFinite(goal?.timeUsedSeconds)&&goal!.timeUsedSeconds>=0?elapsed(goal!.timeUsedSeconds):null;
   text(this.usage,[used!==null?(budget?`${used} / ${budget} tokens`:`${used} tokens`):null,time].filter(value=>value!==null).join(' · '));
   text(this.full,goal?.objective??'');this.full.hidden=this.editing;this.actions.hidden=!goal||this.editing;this.form.hidden=!this.editing;
   text(this.pause,goal?.status==='active'?'Pause':'Resume');this.pause.hidden=!['active','paused','blocked','usageLimited'].includes(goal?.status);
   for(const control of this.root.querySelectorAll<HTMLButtonElement|HTMLInputElement|HTMLTextAreaElement>('button,input,textarea'))control.disabled=!this.enabled||this.busy;
  });
 }
 private openEditor():void{
  if(!this.enabled||this.busy)return;
  this.input.value=this.goal?.objective??'';this.budget.value=this.goal?.tokenBudget==null?'':String(this.goal.tokenBudget);
  this.editing=true;this.opened=true;this.paint(true);this.input.focus({preventScroll:true});
 }
 async command(argument:string):Promise<void>{
  if(!this.supported)throw Error('Goals are not supported by this provider');
  const text=argument.trim();
  const control=text.toLowerCase();
  if(!text||control==='edit'){
   if(control==='edit'||!this.goal){this.openEditor();return;}
   this.opened=true;this.paint(true);return;
  }
  if(['pause','resume','clear'].includes(control)){
   if(!this.goal)throw Error('No goal is set for this session');
   await this.perform(control==='clear'?'goal-clear':'goal-set',control==='clear'?{}:{status:control==='pause'?'paused':'active'});return;
  }
  await this.perform('goal-set',{objective:objective(text),status:'active'});
 }
 private async perform(op:'goal-set'|'goal-clear',args:AgentObject):Promise<void>{
  if(!this.enabled)throw Error('Take over or resume this session before changing its goal');
  if(this.busy)throw Error('Wait for the goal update to finish');
  const generation=this.generation;this.busy=true;this.paint();
  try{await this.options.mutate(op,args);if(generation===this.generation){this.editing=false;this.opened=false;}}
  finally{if(generation===this.generation){this.busy=false;this.paint();}}
 }
 private run(work:()=>Promise<void>):void{void work().catch(error=>this.options.error?.(error));}
}
