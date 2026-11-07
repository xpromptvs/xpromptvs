import {element} from './render';

export const composerCommands=[
 {name:'compact',description:'Summarize conversation to free context'},
 {name:'status',description:'Show session configuration and usage'},
 {name:'model',description:'Choose the Codex model'},
 {name:'plan',description:'Toggle plan mode'},
 {name:'goal',description:'View or set a goal; edit, pause, resume or clear'},
 {name:'help',description:'Show available commands'},
] as const;

/** UI hints only. Execution still goes through the form's submit path. */
export class ComposerCommands {
 private menu=element('div','agent-command-menu');
 private selected=0;
 private goals=true;
 private matches:typeof composerCommands[number][]=[];
 constructor(private input:HTMLTextAreaElement){
  this.menu.dataset.agent='commands';this.menu.hidden=true;this.menu.setAttribute('role','group');
  this.menu.setAttribute('aria-label','Codex commands');input.before(this.menu);
 }
 update():void {
  const match=this.input.value.match(/^\/(\w*)$/);
  this.matches=match?composerCommands.filter(command=>(this.goals||command.name!=='goal')&&command.name.startsWith(match[1]??'')):[];
  this.selected=0;this.paint();
 }
 private paint():void {
  this.menu.hidden=!this.matches.length;this.menu.replaceChildren();
  this.matches.forEach((command,index)=>{
   const button=element('button',index===this.selected?'agent-command-selected':'',`/${command.name} · ${command.description}`);
   button.type='button';button.addEventListener('click',()=>this.complete(index));this.menu.append(button);
  });
 }
 private complete(index=this.selected):void {
  const command=this.matches[index];if(!command)return;
  this.input.value='/'+command.name;this.menu.hidden=true;this.input.focus();
  this.input.dispatchEvent(new Event('input'));
  this.menu.hidden=true;
 }
 key(event:KeyboardEvent):boolean {
  if(this.menu.hidden||event.isComposing||event.keyCode===229||event.shiftKey)return false;
  if(event.key==='Escape'){event.preventDefault();this.menu.hidden=true;return true;}
  if(event.key==='ArrowDown'||event.key==='ArrowUp'){
   event.preventDefault();this.selected=(this.selected+(event.key==='ArrowDown'?1:this.matches.length-1))%this.matches.length;this.paint();return true;
  }
  if(event.key==='Tab'){event.preventDefault();this.complete();return true;}
  if(event.key==='Enter')this.complete();
  return false;
 }
 hide():void {this.menu.hidden=true;}
 setGoals(supported:boolean):void{if(this.goals!==supported){this.goals=supported;this.update();}}
}
