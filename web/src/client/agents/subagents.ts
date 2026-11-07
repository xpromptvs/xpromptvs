import type {AgentObject} from './protocol';
import {element} from './dom';
function parentID(thread:AgentObject):string|undefined{return thread.parentThreadId??thread.source?.subAgent?.thread_spawn?.parent_thread_id;}
function name(thread:AgentObject):string{return thread.agentNickname??thread.source?.subAgent?.thread_spawn?.agent_nickname??thread.name??`Agent ${String(thread.id).slice(0,8)}`;}

/** Visible-only runtime discovery. Looking at a child never joins or resumes it. */
export class LiveSubagents {
  private visible=false;
  private disposed=false;
  private generation=0;
  private current:AgentObject|null=null;
  private rows:AgentObject[]=[];
  private remembered=new Map<string,AgentObject>();
  private buttons=new Map<string,HTMLButtonElement>();
  private label=element('span','agent-subagents-label','Live subagents');
  private errorNode=element('span','agent-subagents-error');
  private error='';
  private loading=false;
  private hasSnapshot=false;
  private timer:ReturnType<typeof setTimeout>|undefined;
  private pending:{generation:number;promise:Promise<void>}|undefined;
  private visibilityChange=()=>{this.generation++;clearTimeout(this.timer);this.rows=[];this.hasSnapshot=false;this.loading=false;this.render();if(!this.root.ownerDocument.hidden)void this.refresh();};
  constructor(private root:HTMLElement,private load:(parent:string)=>Promise<AgentObject>,private select:(id:string)=>void ){root.hidden=true;root.ownerDocument.addEventListener('visibilitychange',this.visibilityChange);}
  setVisible(visible:boolean):void{
    if(this.visible===visible)return;this.visible=visible;
    if(!visible){this.generation++;clearTimeout(this.timer);this.rows=[];this.hasSnapshot=false;this.error='';this.loading=false;this.root.hidden=true;return;}
    this.render();void this.refresh();
  }
  show(thread:AgentObject):void{
    if(this.disposed)return;
    const changed=thread.id!==this.current?.id;
    this.current={...(changed?this.remembered.get(thread.id):this.current),...thread};this.remember(this.current);
    if(changed){this.generation++;clearTimeout(this.timer);this.rows=[];this.error='';this.hasSnapshot=false;this.loading=false;}
    this.render();if(this.visible&&changed)void this.refresh();
  }
  private remember(thread:AgentObject):void{
    this.remembered.delete(thread.id);this.remembered.set(thread.id,thread);
    while(this.remembered.size>128)this.remembered.delete(this.remembered.keys().next().value!);
  }
  async refresh():Promise<void>{
    if(!this.visible||!this.current||this.disposed||this.root.ownerDocument.hidden)return;
    const generation=this.generation,id=String(this.current.id);
    if(this.pending?.generation===generation)return this.pending.promise;
    clearTimeout(this.timer);this.loading=!this.hasSnapshot;this.render();
    const promise=(async()=>{
      try{
        const result=await this.load(id);
        if(generation!==this.generation||!this.visible||this.disposed)return;
        if(!Array.isArray(result.data))throw Error('Invalid live-subagent response');
        this.rows=result.data.filter((thread:AgentObject)=>thread.status?.type==='active'&&parentID(thread)===id);
        for(const row of this.rows)this.remember(row);this.error='';this.hasSnapshot=true;
      }catch(error){if(generation===this.generation&&this.visible&&!this.disposed){this.rows=[];this.error=String((error as Error).message??error);}}
      finally{
        if(this.pending?.generation===generation)this.pending=undefined;
        if(generation===this.generation&&this.visible&&!this.disposed&&!this.root.ownerDocument.hidden){this.loading=false;this.render();this.timer=setTimeout(()=>{void this.refresh();},3000);}
      }
    })();this.pending={generation,promise};return promise;
  }
  private render():void{
    if(!this.visible||!this.current||this.disposed||this.root.ownerDocument.hidden){this.root.hidden=true;return;}
    const nodes:HTMLElement[]=[],keep=new Set<string>();
    const button=(key:string,id:string,text:string):HTMLButtonElement=>{
      keep.add(key);let b=this.buttons.get(key);if(!b){b=element('button','agent-subagent');b.type='button';b.addEventListener('click',()=>this.select(id));this.buttons.set(key,b);}
      if(b.textContent!==text)b.textContent=text;return b;
    };
    const parent=parentID(this.current);
    if(parent){const p=this.remembered.get(parent),b=button(`parent:${parent}`,parent,`← ${p?name(p):'Parent session'}`);b.dataset.parent=parent;nodes.push(b);}
    if(this.rows.length){nodes.push(this.label);for(const row of this.rows){
      const spawn=row.source?.subAgent?.thread_spawn,role=row.agentRole??spawn?.agent_role;
      const flags:string[]=row.status?.activeFlags??[],state=flags.includes('waitingOnApproval')?'Waiting for approval':flags.includes('waitingOnUserInput')?'Waiting for input':'Running';
      const b=button(`child:${row.id}`,row.id,`${name(row)}${role?` [${role}]`:''} · ${state}`);b.dataset.subagent=row.id;b.title=spawn?.agent_path??row.cwd??name(row);nodes.push(b);
    }}else if(this.loading){this.errorNode.textContent='Loading live subagents…';nodes.push(this.errorNode);}
    if(this.error){this.errorNode.textContent=`Live subagents unavailable: ${this.error}`;nodes.push(this.errorNode);}
    let cursor:ChildNode|null=this.root.firstChild;for(const node of nodes){if(cursor!==node)this.root.insertBefore(node,cursor);cursor=node.nextSibling;}
    const wanted=new Set(nodes);for(const node of [...this.root.children])if(!wanted.has(node as HTMLElement))node.remove();
    for(const key of this.buttons.keys())if(!keep.has(key))this.buttons.delete(key);
    this.root.hidden=nodes.length===0;
  }
  reset():void{this.generation++;clearTimeout(this.timer);this.current=null;this.rows=[];this.remembered.clear();this.buttons.clear();this.root.replaceChildren();this.root.hidden=true;this.hasSnapshot=false;this.error='';}
  dispose():void{this.disposed=true;this.visible=false;this.root.ownerDocument.removeEventListener('visibilitychange',this.visibilityChange);this.reset();}
}
