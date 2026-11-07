import type {SessionAgentMsg} from "../source-picker";
export function agentWorking(row:SessionAgentMsg):boolean{return row.status==="active"&&!row.activeFlags?.some(f=>f==="waitingOnApproval"||f==="waitingOnUserInput");}
export function agentReady(row:SessionAgentMsg):boolean{return row.status==="idle"||(row.status==="active"&&!agentWorking(row));}

/** Regular tab-strip nodes; closing a view never controls its executor. */
export class AgentTabs {
  private nodes=new Map<string,{button:HTMLButtonElement;label:HTMLElement}>();
  constructor(private root:HTMLElement,private cb:{select:(id:string)=>void;close:(id:string)=>void;label?:(key:string,label:string)=>string;hold?:()=>boolean;rendered?:()=>void;bell?:(key:string)=>boolean}){}
  update(rows:readonly SessionAgentMsg[],selected:string|null,active:boolean):void {
    if(this.cb.hold?.())return;
    const keep=new Set<string>();
    for(const row of active?rows:[]){
      keep.add(row.id);let node=this.nodes.get(row.id);
      if(!node){
        const button=document.createElement("button");button.type="button";button.className="rl-tab";
        button.setAttribute("role","tab");button.dataset.tabKey=`agent:${row.id}`;button.dataset.navId=`tab:agent:${row.id}`;
        const label=document.createElement("span");label.className="rl-tab-label";
        const kind=document.createElement("span");kind.className="rl-tab-kind";kind.textContent="Codex";
        const close=document.createElement("span");close.className="rl-tab-close";close.textContent="×";close.setAttribute("role","button");close.setAttribute("aria-label","Close tab");
        close.addEventListener("click",e=>{e.stopPropagation();this.cb.close(row.id);});
        button.addEventListener("click",()=>this.cb.select(row.id));button.append(label,kind,close);
        node={button,label};this.nodes.set(row.id,node);this.root.append(button);
      }
      const title=row.name||row.title||"Codex session";
      // WebKit can move the shared bar when an unchanged label's text node is replaced.
      // Keep it in place, as terminal and window tabs do (docs/client-web.md, "Agent-tab redraws").
      const text=this.cb.label?.(`agent:${row.id}`,title)??title;
      if(node.label.textContent!==text)node.label.textContent=text;
      const status=agentWorking(row)?"Working":agentReady(row)?"Ready":row.status==="notLoaded"?"Saved":row.status==="systemError"?"Unavailable":"";
      node.button.title=[title,row.cwd,status].filter(Boolean).join("\n");
      node.button.toggleAttribute("data-agent-working",agentWorking(row));
      node.button.toggleAttribute("data-bell",this.cb.bell?.(`agent:${row.id}`)??false);
      if(agentWorking(row))node.button.setAttribute("aria-busy","true");else node.button.removeAttribute("aria-busy");
      if(status)node.button.dataset.agentStatus=status.toLowerCase();else delete node.button.dataset.agentStatus;
      node.button.classList.toggle("on",row.id===selected);node.button.setAttribute("aria-selected",String(row.id===selected));
    }
    for(const[id,node]of this.nodes)if(!keep.has(id)){node.button.remove();this.nodes.delete(id);}
    this.cb.rendered?.();
  }
}
