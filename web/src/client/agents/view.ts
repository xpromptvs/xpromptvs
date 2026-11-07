import {AgentScrollInset} from './scroll-inset';
import {ComposerSize} from './composer-size';
import { AgentProtocol, type AgentObject } from "./protocol";
import {ComposerCommands,composerCommands} from './composer-commands';
import {AgentMobileControls} from './mobile-controls';
import { AgentStore } from "./store";
import {LiveSubagents} from "./subagents";
import {VirtualList} from "./virtual-list";
import {AgentImages} from './images';
import {AgentAttachments,pasteAttachments} from './attachments';
import {contextFor} from '../instance/context';
import {AgentGoal} from './goal';
import {projectTranscript,samePresentation} from "./presentation";
import { element, renderAgentItem, safeLink } from "./render";

type Options = { root: HTMLElement; button?: HTMLButtonElement; send: (m: AgentObject) => void; onOpen?: () => void; onHide?: () => void; onSession?: (id:string) => void; onCloseTab?: (id:string) => void; hostSelectedTab?:()=>string|null; wire?:AgentProtocol; persistent?:boolean };
export class AgentsView {
  private wire: AgentProtocol;
  private subagents: LiveSubagents;
  private store = new AgentStore();
  private active = false;
  private disposed = false;
  private shown = false;
  private attached = new Set<string>();
  private rows: AgentObject[] = [];
  private next: string | null = null;
  private historyCursor: string | null = null;
  private historyPage: object | null = null;
  private historyAutoPaused = false;
  private selection = 0;
  private refreshGeneration = 0;
  private drafts = new Map<string, string>();
  private attachments=new AgentAttachments();
  private sending=new Set<string>();
  private preparingAttachments=new Map<string,number>();
  private attachmentRenderKey='';
  private goal:AgentGoal;
  private goalVersion=0;
  private goalRead:{selection:number;promise:Promise<void>}|null=null;
  private paintTimer: ReturnType<typeof setTimeout> | null = null;
  private virtual:VirtualList<AgentObject>;
  private images:AgentImages;
  private disclosures=new Map<string,boolean>();
  private rowState=new Map<string,{fields:{label:string|null;value:string;checked:boolean}[];images:Map<string,{src:string;alt:string}>;replied:Set<number>}>();
  private requestNodes = new Map<string, HTMLElement>();
  private models: AgentObject[] = [];
  private settings = new Map<string,AgentObject>();
  private settingsWrites = new Map<string,Promise<unknown>>();
  private clickOpen = () => this.open();
  private agentMetadata = new Map<string,AgentObject>();
  private metadataRequested = new Set<string>();
  private metadataInFlight = 0;
  private tabThread: string | null = null;
  private helloPending: Promise<AgentObject> | null = null;
  private loaded=false;
  private loading=false;
  private commands:ComposerCommands;
  private mobileControls:AgentMobileControls;
  private scrollInset:AgentScrollInset;
  private composerSize:ComposerSize;
  private savedScroll:{top:number;follow:boolean}|null=null;
  private $<T extends HTMLElement = HTMLElement>(id: string): T { return this.options.root.querySelector(`[data-agent="${id}"]`)!; }
  constructor(private options: Options) {
    options.root.classList.add("agent-surface"); options.root.hidden = true;
    // Static application markup; all session/tool content below is created as text/DOM nodes.
    options.root.innerHTML = `<aside class="agent-sidebar"><header><strong>Codex</strong><button type="button" data-agent="refresh">Refresh</button></header><input data-agent="search" type="search" placeholder="Search sessions" aria-label="Search Codex sessions"><form data-agent="new-form" class="agent-new"><input data-agent="directory" placeholder="/path/to/project" aria-label="New session project directory"><button type="submit">New session</button></form><div data-agent="list" class="agent-list"></div><button type="button" data-agent="more" hidden>Load more sessions</button></aside><section class="agent-conversation"><header class="agent-heading"><button type="button" data-agent="back" class="agent-back">Sessions</button><div><strong data-agent="title">Codex sessions</strong><small data-agent="subtitle">Choose a session on the host</small></div><button type="button" data-agent="join" data-action="join" hidden>Take over</button><button type="button" data-agent="close" aria-label="Close Agents">Close</button></header><nav data-agent="subagents" class="agent-subagents" aria-label="Live subagents" hidden></nav><div data-agent="notice" class="agent-notice" role="status"></div><button type="button" data-agent="start-service" hidden>Start Codex service on host</button><div data-agent="scroll" class="agent-scroll"><div data-agent="older" class="agent-history-loading" role="status" aria-hidden="true" hidden><span class="agent-history-spinner" aria-hidden="true"></span><span class="agent-history-label">Loading earlier messages…</span></div><div data-agent="transcript" class="agent-transcript"></div></div><button type="button" data-agent="latest" class="agent-latest" aria-label="Jump to latest" title="Jump to latest" hidden><svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="m2 7.5 10 10 10-10"/></svg></button><div data-agent="requests" class="agent-requests"></div><form data-agent="composer" class="agent-composer"><div data-agent="attachments" class="agent-attachments"></div><textarea data-agent="message" rows="1" aria-label="Message Codex" placeholder="Take over a session to continue"></textarea><div class="agent-compose-actions"><input data-agent="file" type="file" multiple hidden><button type="button" data-agent="attach">Attach</button><select data-agent="model" aria-label="Codex model"><option value="">Current model</option></select><select data-agent="effort" aria-label="Reasoning effort"><option value="">Current effort</option></select><label><input data-agent="plan" type="checkbox">Plan</label><select data-agent="delivery" aria-label="Message delivery"><option value="steer">Steer now</option><option value="queue">Queue</option></select><button type="button" data-agent="details">Session details</button><button type="button" data-agent="stop">Stop</button><button type="submit" data-agent="send">Send</button></div></form><section data-agent="details-panel" class="agent-details-panel" hidden></section></section>`;
    const working=element("div","agent-working");working.dataset.agent="working";working.hidden=true;
    working.setAttribute("role","status");working.setAttribute("aria-live","polite");
    const dot=element("span","agent-working-dot","•");dot.setAttribute("aria-hidden","true");
    working.append(dot,element("span","agent-working-label","Working…"));this.$("composer").before(working);
    this.wire = options.wire??new AgentProtocol(options.send,e=>this.event(e));
    this.subagents=new LiveSubagents(this.$("subagents"),id=>this.wire.call("children",id),id=>this.choose(id));
    options.button?.addEventListener("click",this.clickOpen);
    this.$("close").addEventListener("click",()=>{if(this.tabThread&&options.onCloseTab)options.onCloseTab(this.tabThread);else this.hide();});
    this.$("back").addEventListener("click",()=>{this.refreshGeneration++;this.subagents.setVisible(false);options.root.classList.remove("agent-selected");});
    this.$("refresh").addEventListener("click",()=>this.run(()=>this.refresh()));
    if(options.persistent){
      const refresh=element("button","","Refresh");refresh.type="button";refresh.dataset.agent="refresh-tab";
      refresh.addEventListener("click",()=>this.run(()=>this.refresh()));
      this.$("close").before(refresh);
    }
    this.$("more").addEventListener("click",()=>this.run(()=>this.list(true)));
    this.$("join").addEventListener("click",()=>this.run(()=>this.join()));
    this.$("start-service").addEventListener("click",()=>this.run(async()=>{await this.wire.call("start-service");await this.refresh();}));
    let searchTimer: ReturnType<typeof setTimeout> | undefined;
    this.$("search").addEventListener("input",()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>this.run(()=>this.list()),200);});
    this.$("new-form").addEventListener("submit",e=>{e.preventDefault();this.run(async()=>{
      const cwd=this.$<HTMLInputElement>("directory").value.trim(); if(!cwd.startsWith("/"))throw Error("Enter an absolute project directory on the host");
      const result=await this.wire.call("new-thread",undefined,{cwd});
      this.adopt(result); await this.list(); if(result.thread?.id)this.choose(result.thread.id);
    });});
    this.commands=new ComposerCommands(this.$<HTMLTextAreaElement>("message"));
    this.$("message").setAttribute("enterkeyhint","send");
    this.mobileControls=new AgentMobileControls(options.root);
    this.$("message").addEventListener("input",()=>{if(this.store.thread)this.drafts.set(this.store.thread,this.$<HTMLTextAreaElement>("message").value);this.commands.update();});
    this.$("message").addEventListener("keydown",e=>{const key=e as KeyboardEvent;if(this.commands.key(key))return;if(key.key==="Enter"&&!key.shiftKey&&!key.isComposing&&key.keyCode!==229){e.preventDefault();this.$<HTMLFormElement>("composer").requestSubmit();}});
    this.$("composer").addEventListener("submit",e=>{e.preventDefault();this.run(()=>this.send());});
    this.$("stop").addEventListener("click",()=>this.run(async()=>{if(this.store.thread&&this.store.activeTurn)await this.wire.call("interrupt",this.store.thread,{turnId:this.store.activeTurn});}));
    this.$("attach").addEventListener("click",()=>this.$<HTMLInputElement>("file").click());
    this.$("file").addEventListener("change",()=>{
      const input=this.$<HTMLInputElement>('file'),thread=this.store.thread;
      try{if(thread)this.stageAttachments(thread,[...input.files??[]]);}catch(error){this.reportError(error);}finally{input.value='';}
    });
    this.$('message').addEventListener('paste',event=>{
      const thread=this.store.thread,epoch=this.wire.epoch,canAttach=this.store.metadata.capabilities?.attachments!==false;if(!thread||this.$<HTMLTextAreaElement>('message').disabled)return;
      pasteAttachments(event as ClipboardEvent,{
        stage:files=>{if(!canAttach)throw Error('This host does not support attachments');this.stageAttachments(thread,files);},
        valid:()=>this.active&&!this.disposed&&this.wire.epoch===epoch,
        pending:on=>{const count=(this.preparingAttachments.get(thread)??0)+(on?1:-1);if(count>0)this.preparingAttachments.set(thread,count);else this.preparingAttachments.delete(thread);if(!this.disposed)this.updateControls();},
        local:contextFor(this.options.root)?.platform.localPaste,error:error=>this.reportError(error),
      });
    });
    this.$("model").addEventListener("change",()=>{this.updateEfforts();this.run(()=>this.saveSettings("model"));});
    this.$("effort").addEventListener("change",()=>this.run(()=>this.saveSettings("effort")));
    this.$("plan").addEventListener("change",()=>this.run(()=>this.saveSettings("plan")));
    this.$("details").addEventListener("click",()=>this.run(()=>this.details()));
    this.$("transcript").setAttribute("role","feed");this.$("transcript").setAttribute("aria-label","Conversation");
    this.images=new AgentImages(this.$("scroll"),(op,thread,args)=>this.wire.call(op,thread,args));
    this.virtual=new VirtualList(this.$("scroll"),this.$("transcript"),{
      bottomInset:()=>this.scrollInset?.height??0,
      key:item=>`${item._turn}:${item.id}`,same:samePresentation,
      render:item=>this.renderRow(item),capture:(item,node)=>this.captureRow(item,node),
      release:(_item,node)=>this.images.release(node),
      estimate:item=>item.type==='agentMessage'||item.type==='userMessage'?Math.min(1600,64+Math.ceil(String(item.text??item.content?.[0]?.text??'').length/80)*24):112,
    });
    this.scrollInset=new AgentScrollInset(this.$("scroll"),this.$("requests"),(change,height)=>this.virtual.resizeViewport(change,height));
    this.composerSize=new ComposerSize(this.$<HTMLTextAreaElement>("message"),change=>this.scrollInset.resizeViewport(change));
    const goal=document.createElement('section');this.$('composer').before(goal);
    this.goal=new AgentGoal(goal,{change:fn=>this.scrollInset.resizeViewport(fn),mutate:(op,args)=>this.changeGoal(op,args),error:error=>this.reportError(error)});
    this.scrollInset.observe(goal);
    this.$("scroll").addEventListener("scroll",()=>{this.$("latest").hidden=this.virtual.followsLatest;if(this.$("scroll").scrollTop>400)this.historyAutoPaused=false;this.maybeLoadEarlier();});
    this.$("scroll").addEventListener("scrollend",()=>this.maybeLoadEarlier());
    this.$("latest").addEventListener("click",()=>{this.virtual.scrollToEnd();this.$("latest").hidden=true;});
  }
  get visible(): boolean { return this.shown; }
  reportError(error:unknown):void { this.notice(String((error as Error)?.message??error)); }
  get selectedTab(): string | null { return this.shown ? this.tabThread : null; }
  private choose(id:string):void { if(this.options.onSession)this.options.onSession(id);else this.run(()=>this.select(id)); }
  private async hello():Promise<AgentObject> {
    if(!this.helloPending)this.helloPending=this.wire.call("hello").finally(()=>{this.helloPending=null;});
    const hello=await this.helloPending;
    this.attached=new Set(hello.joined??[]);
    for(const[id,value]of Object.entries(hello.settings??{}))this.settings.set(id,value as AgentObject);
    return hello;
  }
  async search(query:string):Promise<AgentObject[]> {
    if(!this.active||this.disposed)return [];
    if(!this.wire.epoch)await this.hello();
    return (await this.wire.call("list",undefined,query.trim()?{searchTerm:query.trim()}:{})).data??[];
  }
  async openSession(id:string):Promise<void> {
    if(!this.active||this.disposed)return;
    if(!this.wire.epoch)await this.hello();
    await this.wire.call("open-tab",id);
    if(!this.options.hostSelectedTab||this.options.hostSelectedTab()===id)this.showSession(id);
  }
  async tabAction(op:"select-tab"|"close-tab",id:string):Promise<void> {
    if(!this.active||this.disposed)return;
    if(!this.wire.epoch)await this.hello();
    await this.wire.call(op,id);
    if(op==="select-tab"&&(!this.options.hostSelectedTab||this.options.hostSelectedTab()===id))this.showSession(id);
  }
  showSession(id:string):void {
    if(!this.active||this.disposed||(this.shown&&this.tabThread===id&&this.wire.epoch))return;
    if(this.options.persistent&&this.tabThread===id&&this.wire.epoch&&(this.loaded||this.loading)){
      this.shown=true;this.options.root.hidden=false;this.subagents.setVisible(true);this.options.onOpen?.();
      this.composerSize.update();this.paint();this.restoreScroll();return;
    }
    const generation=++this.refreshGeneration;this.tabThread=id;this.shown=true;
    this.loading=true;
    const current=()=>generation===this.refreshGeneration&&this.tabThread===id&&(this.shown||!!this.options.persistent)&&this.active&&!this.disposed;
    this.options.root.classList.add("agent-tab-mode");this.options.root.hidden=false;
    this.options.onOpen?.();
    this.run(async()=>{try{
      const hello=await this.hello();if(!current())return;
      this.pending(hello.pending??[]);
      await this.select(id);if(!current())return;
      if(this.store.metadata.canAcceptDirectInput!==false&&["active","idle"].includes(this.store.metadata.status?.type)&&!this.attached.has(id))await this.join();
      if(!current())return;
      const models=await this.wire.call("models",id);if(!current())return;
      this.models=models.data??[];this.renderModels();
      this.loaded=true;
    }finally{if(generation===this.refreshGeneration)this.loading=false;}});
  }
  notify(event:AgentObject):void {this.event(event);}
  private restoreScroll():void {
    if(this.savedScroll){
      if(this.savedScroll.follow)this.virtual.scrollToEnd();
      else if(!this.$("transcript").getBoundingClientRect().width)this.virtual.restorePosition(this.savedScroll.top,false);
      else this.virtual.refresh();
    }
  }
  receive(message: AgentObject): boolean { return this.wire.receive(message); }
  setActive(active: boolean): void {
    if(this.options.button)this.options.button.disabled=!active; if(this.active===active)return;this.active=active;
    if(!active){this.reset();this.hide();this.store=new AgentStore();this.virtual.clear();this.disclosures.clear();this.rowState.clear();this.$("requests").replaceChildren();this.rows=[];this.$("list").replaceChildren();}
  }
  open(): void {
    if(!this.active||this.disposed)return;
    this.tabThread=null;this.options.root.classList.remove("agent-tab-mode");
    this.shown=true;this.options.root.hidden=false;this.options.button?.setAttribute("aria-pressed","true");this.options.onOpen?.();
    this.paint();
    this.run(()=>this.refresh());
  }
  hide(): void {this.mobileControls.close(false);if(this.shown){const s=this.$("scroll");this.savedScroll={top:s.scrollTop,follow:this.virtual.followsLatest};}if(!this.options.persistent)this.refreshGeneration++;this.subagents.setVisible(false);this.shown=false;this.images.setVisible(false);this.virtual.setVisible(false);this.options.root.hidden=true;this.options.button?.setAttribute("aria-pressed","false");this.options.onHide?.();}
  reset(): void {this.goalVersion++;this.goalRead=null;this.goal?.reset();this.images.reset();this.loaded=false;this.loading=false;this.helloPending=null;this.refreshGeneration++;this.subagents.reset();this.selection++;this.historyPage=null;this.historyCursor=null;this.historyAutoPaused=false;this.setHistoryLoading(false);if(!this.options.wire)this.wire.reset();this.attached.clear();this.requestNodes.clear();this.store.requests.clear();this.$("requests").replaceChildren();this.updateControls();}
  connectionReset(): void {const tab=this.tabThread;this.reset();this.helloPending=null;if(this.shown&&this.active){if(tab)this.showSession(tab);else this.run(()=>this.refresh());}}
  dispose(): void {this.scrollInset.dispose();this.composerSize.dispose();this.mobileControls.dispose();this.subagents.dispose();this.attachments.dispose();this.images.dispose();this.virtual.dispose();this.disposed=true;this.reset();if(this.paintTimer)clearTimeout(this.paintTimer);this.options.button?.removeEventListener("click",this.clickOpen);this.options.root.replaceChildren();}
  private run(work:()=>Promise<unknown>): void {void work().catch(e=>{if(!this.disposed)this.notice(String(e?.message??e));});}
  private notice(text:string):void {this.$("notice").textContent=text;}
  private async refresh():Promise<void> {
    const generation=++this.refreshGeneration,current=()=>generation===this.refreshGeneration&&this.shown&&this.active&&!this.disposed;
    this.notice("Connecting to Codex on the host…");
    try {
      const hello=await this.wire.call("hello");if(!current())return;
      this.subagents.setVisible(true);
      this.attached=new Set(hello.joined??[]);for(const[id,value]of Object.entries(hello.settings??{}))this.settings.set(id,value as AgentObject);this.$("start-service").hidden=true;
      this.notice(this.tabThread?"Synchronizing Codex session…":"Loading Codex sessions…");
      if(!this.tabThread)await this.list(false,current);if(!current())return;
      this.notice("");
      const selected=this.tabThread??hello.selected??this.store.thread;if(selected)await this.select(selected);if(!current())return;
      this.pending(hello.pending??[]);
      void this.subagents.refresh();
      this.run(async()=>{const result=await this.wire.call("models",this.store.thread??undefined);if(!current())return;this.models=result.data??[];this.renderModels();});
      this.updateControls();
    } catch(error){if(!current())return;this.$("start-service").hidden=(error as Error).name==="AgentHelloTimeout";throw error;}
  }
  private async list(more=false,current:()=>boolean=()=>true):Promise<void> {
    const args:AgentObject={};if(more&&this.next)args.cursor=this.next;
    const search=this.$<HTMLInputElement>("search").value;if(search)args.searchTerm=search;
    const result=await this.wire.call("list",undefined,args);if(!this.active||this.disposed||!current())return;
    this.rows=more?[...this.rows,...(result.data??[])]:result.data??[];this.next=result.nextCursor??null;
    this.$("more").hidden=!this.next;this.renderList();
  }
  private renderList():void {
    const fragment=document.createDocumentFragment();
    for(const row of this.rows){
      const button=element("button","agent-session");button.type="button";button.dataset.thread=row.id;button.classList.toggle("selected",row.id===this.store.thread);
      button.append(element("strong","",row.name??row.preview??"Untitled session"),element("span","agent-path",row.cwd??""),element("small","",[row.status?.type??"saved",...(row.status?.activeFlags??[])].join(" · ")));
      button.addEventListener("click",()=>this.choose(row.id));fragment.append(button);
    }
    if(!this.rows.length)fragment.append(element("p","agent-notice","No Codex sessions found on this host."));this.$("list").replaceChildren(fragment);
  }
  private async select(id:string):Promise<void> {
    if(this.store.thread)this.drafts.set(this.store.thread,this.$<HTMLTextAreaElement>("message").value);
    this.subagents.show({id});this.subagents.setVisible(this.shown&&!!this.wire.epoch);
    const generation=++this.selection;this.historyPage=null;this.historyCursor=null;this.historyAutoPaused=false;this.setHistoryLoading(false);this.agentMetadata.clear();this.metadataRequested.clear();this.images.reset();this.virtual.clear();this.disclosures.clear();this.rowState.clear();this.store.select(id);this.goalVersion++;this.goalRead=null;this.goal.reset();this.requestNodes.clear();this.$("requests").replaceChildren();
    this.$("details-panel").hidden=true;this.$("details-panel").replaceChildren();this.syncControls();
    this.$<HTMLTextAreaElement>("message").value=this.drafts.get(id)??"";this.commands.hide();this.options.root.classList.add("agent-selected");this.composerSize.update();this.renderList();this.updateControls();
    this.store.beginHydration();
    try {
      const [read,history]=await Promise.all([this.wire.call("read",id),this.wire.call("history",id)]);
      if(generation!==this.selection)return;this.store.metadata={...(read.thread??{}),...(this.settings.get(id)??{})};this.subagents.show(this.store.metadata);this.store.hydrate(history.data??[]);this.historyCursor=history.nextCursor??null;this.syncControls();
      this.$("title").textContent=this.store.metadata.name??this.store.metadata.preview??"Codex session";
      this.$("subtitle").textContent=this.store.metadata.cwd??"";
      this.$("older").hidden=!this.historyCursor;this.paint();this.updateControls();void this.refreshGoal().catch(()=>{});
      if(this.attached.has(id)){const hello=await this.wire.call("hello");if(generation===this.selection)this.pending(hello.pending??[]);}
    } catch(error){if(generation===this.selection){this.store.abortHydration();this.paint();}throw error;}
  }
  private setHistoryLoading(loading:boolean):void {
    this.$("older").classList.toggle("is-loading",loading);this.$("older").setAttribute("aria-hidden",String(!loading));
    if(loading)this.$("scroll").setAttribute("aria-busy","true");else this.$("scroll").removeAttribute("aria-busy");
  }
  private maybeLoadEarlier():void {
    const scroll=this.$("scroll");
    if(!this.shown||!this.active||this.disposed||!this.historyCursor||this.historyPage||this.historyAutoPaused||this.virtual.isOverscrolling||!scroll.clientHeight||scroll.scrollTop>400)return;
    // Start at latest; only prefill a short first page, or page where the person is reading.
    if(this.virtual.followsLatest&&scroll.scrollHeight>scroll.clientHeight+1)return;
    this.run(()=>this.history(true));
  }
  private async history(older=false):Promise<void> {
    const id=this.store.thread;if(!id||older&&(!this.historyCursor||this.historyPage))return;
    const generation=this.selection,cursor=older?this.historyCursor:null,page=older?{}:null;
    if(older){this.historyPage=page;this.historyAutoPaused=false;this.setHistoryLoading(true);}
    let succeeded=false;
    try{
      const result=await this.wire.call("history",id,cursor?{cursor}:{});
      if(generation!==this.selection)return;if(older&&this.shown&&!this.virtual.followsLatest)this.virtual.preservePosition();
      this.store.hydrate(result.data??[]);
      // A repeated cursor cannot make progress; don't loop on a faulty provider page.
      this.historyCursor=result.nextCursor&&result.nextCursor!==cursor?result.nextCursor:null;
      this.$("older").hidden=!this.historyCursor;this.paint();succeeded=true;
    }catch(error){
      if(generation===this.selection){if(older)this.historyAutoPaused=true;else this.store.abortHydration();this.paint();}
      throw error;
    }finally{
      if(older&&this.historyPage===page){this.historyPage=null;this.setHistoryLoading(false);if(succeeded)this.maybeLoadEarlier();}
    }
  }
  private adopt(result:AgentObject):void {if(result.thread?.id){this.attached.add(result.thread.id);const settings:AgentObject={};for(const key of["model","reasoningEffort","approvalPolicy","approvalsReviewer","sandbox","activePermissionProfile","instructionSources","collaborationMode"])if(result[key]!=null)settings[key]=result[key];this.settings.set(result.thread.id,settings);Object.assign(this.store.metadata,result.thread,settings);this.syncControls();}}
  private async join():Promise<void> {
    const id=this.store.thread;if(!id)return;const generation=this.selection;
    this.store.beginHydration();const op=this.store.metadata.status?.type==="notLoaded"?"resume":"join";
    let result:AgentObject;
    try{result=await this.wire.call(op,id);}catch(error){if(generation===this.selection){this.store.abortHydration();this.paint();}throw error;}
    if(generation!==this.selection)return;this.adopt(result);this.notice(this.isClaude?"Connected to the host’s persistent Claude session.":op==="resume"?"Saved history resumed in the shared Codex service.":"Connected to the same Codex session. The host terminal can still interact with it.");
    await this.history();if(this.isClaude){const models=await this.wire.call("models",id);if(generation!==this.selection)return;this.models=models.data??[];this.renderModels();}const hello=await this.wire.call("hello");if(generation!==this.selection)return;this.pending(hello.pending??[]);this.updateControls();
  }
  private get isClaude():boolean{return this.store.thread?.startsWith("claude:")??false;}
  private refreshGoal():Promise<void>{
    const id=this.store.thread,selection=this.selection,version=this.goalVersion;
    if(!id||this.isClaude||!this.active||!this.wire.epoch)return Promise.resolve();
    if(this.goalRead?.selection===selection)return this.goalRead.promise;
    const entry={selection,promise:Promise.resolve()};this.goalRead=entry;
    entry.promise=this.wire.call('goal',id).then(result=>{
      if(!this.disposed&&this.active&&this.store.thread===id&&this.selection===selection&&this.goalVersion===version){this.store.metadata.goal=result.goal??null;this.updateControls();}
    }).finally(()=>{if(this.goalRead===entry)this.goalRead=null;});return entry.promise;
  }
  private async changeGoal(op:'goal-set'|'goal-clear',args:AgentObject):Promise<void>{
    const id=this.store.thread,selection=this.selection;if(!id||this.isClaude||!this.active||!this.attached.has(id))throw Error('Take over or resume this Codex session first');
    const version=++this.goalVersion;this.goalRead=null;
    const result=await this.wire.call(op,id,args);
    if(this.disposed||!this.active||this.store.thread!==id||this.selection!==selection||this.goalVersion!==version)return;
    if(op==='goal-clear'&&result.cleared!==false)this.store.metadata.goal=null;
    else if('goal'in result)this.store.metadata.goal=result.goal;
    else await this.refreshGoal();
    this.updateControls();
  }
  private resizeTranscript(change:()=>void):void{if(this.scrollInset)this.scrollInset.resizeViewport(change);else change();}
  private updateControls():void {this.resizeTranscript(()=>this.applyControls());}
  private applyControls():void {
    const id=this.store.thread,enabled=!!id&&this.store.metadata.id===id&&this.active&&this.attached.has(id)&&!!this.wire.epoch;
    const status=this.store.metadata.status;
    this.$("working").hidden=!(enabled&&this.store.activeTurn&&status?.type==="active"&&
      !status.activeFlags?.some((flag:string)=>flag==="waitingOnApproval"||flag==="waitingOnUserInput"));
    for(const name of ["message","send","attach","model","effort","plan","details"])(this.$(name) as HTMLButtonElement).disabled=!enabled;
    this.$<HTMLButtonElement>("stop").disabled=!enabled||!this.store.activeTurn;
    const caps=this.store.metadata.capabilities??{};
    this.$<HTMLButtonElement>("attach").disabled=!enabled||caps.attachments===false;
    const delivery=this.$<HTMLSelectElement>("delivery");delivery.querySelector<HTMLOptionElement>('option[value="steer"]')!.disabled=caps.steer===false;if(caps.steer===false)delivery.value="queue";
    this.$<HTMLTextAreaElement>("message").setAttribute("aria-label",this.isClaude?"Message Claude":"Message Codex");
    this.mobileControls.setEnabled(enabled,!!this.store.activeTurn);
    this.commands.setGoals(!this.isClaude);
    this.goal?.update(this.store.metadata.goal,enabled,!this.isClaude);
    this.$("join").hidden=!id||enabled||this.store.metadata.canAcceptDirectInput===false;this.$("join").textContent=this.store.metadata.status?.type==="notLoaded"?"Resume":"Take over";
    this.$("delivery").hidden=!this.store.activeTurn;
    this.$<HTMLTextAreaElement>("message").placeholder=enabled?(this.isClaude?"Message Claude on the host…":"Message Codex on the host…"):"Take over or resume this session to continue";
    this.$<HTMLButtonElement>('send').disabled=!enabled||!!id&&(this.sending.has(id)||this.preparingAttachments.has(id));
    this.$('send').textContent=id&&this.sending.has(id)?'Sending…':id&&this.preparingAttachments.has(id)?'Preparing…':'Send';
    this.renderAttachments();
  }
  private stageAttachments(thread:string,files:File[]):void{this.attachments.add(thread,files);this.updateControls();}
  private renderAttachments():void{
    const thread=this.store.thread,rows=thread?this.attachments.list(thread):[],locked=!!thread&&this.sending.has(thread);
    const preparing=!!thread&&this.preparingAttachments.has(thread);
    const key=JSON.stringify([thread,locked,preparing,rows.map(row=>row.id)]);if(key===this.attachmentRenderKey)return;this.attachmentRenderKey=key;
    const render=()=>{
      const root=this.$('attachments');root.replaceChildren();root.hidden=!rows.length&&!preparing;
      if(preparing)root.append(element('span','agent-draft-pending','Preparing attachment…'));
      for(const row of rows){
        const chip=element('div','agent-draft-attachment');
        if(row.preview){const image=element('img','agent-draft-image');image.src=row.preview;image.alt=row.name;chip.append(image);}
        chip.append(element('span','agent-draft-name',row.name));
        const remove=element('button','agent-attachment-remove','×');remove.type='button';remove.disabled=locked;remove.setAttribute('aria-label',`Remove ${row.name}`);
        remove.addEventListener('click',()=>{if(thread){this.attachments.remove(thread,row.id);this.updateControls();}});chip.append(remove);root.append(chip);
      }
    };
    this.resizeTranscript(render);
  }
  private async send():Promise<void> {
    if(this.mobileControls.isOpen)return;
    const id=this.store.thread;if(!id||!this.attached.has(id))return;
    if(this.sending.has(id)||this.preparingAttachments.has(id))return;
    const text=this.$<HTMLTextAreaElement>("message").value, generation=this.selection;
    if(text.trim().startsWith('/')&&(!text.trim().includes('\n')||/^\/goal(?:\s|$)/.test(text.trim()))){
      if(this.attachments.list(id).length)throw Error('Remove attachments before running a slash command');
      const match=/^\/(\S+)(?:\s+([\s\S]*))?$/.exec(text.trim())!,name=match[1],argument=match[2]??'';
      if(!composerCommands.some(command=>command.name===name))throw Error('Unknown command. Use /help to see available commands.');
      if(argument&&name!=='goal')throw Error(`/${name} does not accept arguments. Use the existing session controls.`);
      if(name==='compact'){
        if(this.store.activeTurn||this.store.metadata.status?.type==='active')throw Error('Wait for the current turn to finish before compacting');
        await this.wire.call('compact',id);if(generation===this.selection)this.notice('Compaction requested');
      }else if(name==='goal'){
        if(this.isClaude)throw Error('Goals are not supported by Claude');
        const epoch=this.wire.epoch;await this.refreshGoal();
        if(!epoch||this.disposed||!this.active||this.wire.epoch!==epoch||this.selection!==generation||this.store.thread!==id)throw Error('The selected session changed; goal command was not applied');
        await this.goal.command(argument);
      }else if(name==='help')this.notice(composerCommands.filter(command=>!this.isClaude||command.name!=='goal').map(command=>`/${command.name} — ${command.description}`).join('\n'));
      else if(name==='status'){this.$('details-panel').hidden=true;await this.details();}
      else if(name==='model')this.mobileControls.focusModel();
      else if(name==='plan'){
        const plan=this.$<HTMLInputElement>('plan'),previous=plan.checked;plan.checked=!previous;
        try{await this.saveSettings('plan');}catch(error){if(generation===this.selection)plan.checked=previous;throw error;}
      }
      if(this.drafts.get(id)===text)this.drafts.delete(id);
      if(generation===this.selection&&this.$<HTMLTextAreaElement>('message').value===text){this.$<HTMLTextAreaElement>('message').value='';this.composerSize.update();this.commands.hide();}
      return;
    }
    const op=this.store.activeTurn?this.$<HTMLSelectElement>("delivery").value:"send";
    const staged=[...this.attachments.list(id)],epoch=this.wire.epoch;if(!epoch||!this.active||!text.trim()&&!staged.length)return;
    const turn=this.store.activeTurn,valid=()=>this.active&&!this.disposed&&this.wire.epoch===epoch;
    this.sending.add(id);this.notice('');this.updateControls();
    this.virtual.scrollToEnd();this.$('latest').hidden=true;
    try{
      const attachmentIds=await this.attachments.upload(id,staged,epoch,(thread,args)=>this.wire.call('upload',thread,args),valid);
      const args:AgentObject={text,attachments:attachmentIds};if(op==='steer')args.turnId=turn;
      await this.settingsWrites.get(id);if(!valid())throw Error('Connection changed; message remains in the draft');
      await this.wire.call(op,id,args);if(this.drafts.get(id)===text)this.drafts.delete(id);
      this.attachments.consume(id,staged);
      if(generation===this.selection){if(this.$<HTMLTextAreaElement>('message').value===text)this.$<HTMLTextAreaElement>('message').value='';this.composerSize.update();this.commands.hide();}
    }finally{this.sending.delete(id);if(!this.disposed)this.updateControls();}
  }
  private event(event:AgentObject):void {
    if(event.method==="xpromptvs/provider-disconnected"){
      if(event.params?.provider!==(this.isClaude?"claude":"codex"))return;
      event={method:"xpromptvs/disconnected",params:{}};
    }
    if(event.method==="xpromptvs/detached"){const thread=event.params?.threadId;this.attached.delete(thread);if(thread===this.store.thread){this.store.requests.clear();this.renderRequests();this.notice("Approval delivery is uncertain. Take over again to recover current requests.");this.updateControls();}return;}
    if(event.method==="xpromptvs/disconnected"){this.attached.clear();this.store.requests.clear();this.resizeTranscript(()=>{this.requestNodes.clear();this.$("requests").replaceChildren();});this.notice(`${this.isClaude?"Claude":"Codex"} service disconnected. Refresh to reconnect; the agent may still be working.`);this.updateControls();return;}
    if(event.method==="xpromptvs/resnapshot"){this.notice(event.params?.error??"Agent state changed. Refresh to synchronize.");return;}
    if(event.method==="thread/settings/updated"&&event.params?.threadSettings){const runtime={...event.params.threadSettings,reasoningEffort:event.params.threadSettings.effort};this.settings.set(event.params.threadId,{...(this.settings.get(event.params.threadId)??{}),...runtime});}
    if(event.method==="thread/status/changed"){const row=this.rows.find(r=>r.id===event.params?.threadId);if(row){row.status=event.params.status;this.renderList();}}
    if(event.method==="thread/status/changed"&&event.params?.threadId===this.store.thread&&event.params?.status?.type==="notLoaded")this.attached.delete(this.store.thread!);
    if(['thread/goal/updated','thread/goal/cleared'].includes(event.method)&&event.params?.threadId===this.store.thread){this.goalVersion++;this.goalRead=null;}
    this.store.event(event);if(["thread/status/changed","thread/goal/updated","thread/goal/cleared"].includes(event.method)&&event.params?.threadId===this.store.thread)this.updateControls();if(!this.paintTimer)this.paintTimer=setTimeout(()=>{this.paintTimer=null;if(this.shown)this.paint();},16);
    if(event.method==="thread/settings/updated"&&event.params?.threadId===this.store.thread)this.syncControls();
  }
  private pending(requests:AgentObject[]):void {
    this.store.requests.clear();for(const request of requests)if(request.params?.threadId===this.store.thread)this.store.requests.set(typeof request.id==="string"?`s:${request.id}`:String(request.id),request);
    this.renderRequests();
  }
  private paint():void {
    const canonical=this.store.items();this.loadAgentMetadata(canonical);
    const items=projectTranscript(canonical,this.agentMetadata);
    this.images.setVisible(this.shown&&this.active);
    this.virtual.setVisible(this.shown&&this.active);
    this.virtual.setItems(items);
    this.$("latest").hidden=this.virtual.followsLatest;
    const keep=new Set(items.map(item=>`${item._turn}:${item.id}`));
    for(const key of this.rowState.keys())if(!keep.has(key))this.rowState.delete(key);
    const detailKeys=new Set(canonical.flatMap(item=>[`${item._turn}:${item.id}:`,`${item._turn}:explore:${item.id}:`]));
    for(const key of this.disclosures.keys())if(![...detailKeys].some(prefix=>key.startsWith(prefix)))this.disclosures.delete(key);
    this.renderRequests();this.updateControls();this.maybeLoadEarlier();if(this.store.needsResnapshot)this.notice("History synchronization was interrupted. Refresh to synchronize with the host.");
  }
  private stateFor(item:AgentObject){
    const key=`${item._turn}:${item.id}`;let state=this.rowState.get(key);
    if(!state){state={fields:[],images:new Map(),replied:new Set()};this.rowState.set(key,state);}return state;
  }
  private captureRow(item:AgentObject,node:HTMLElement):void{
    for(const detail of node.querySelectorAll<HTMLDetailsElement>("details[data-disclosure]"))this.disclosures.set(`${item._turn}:${detail.dataset.disclosure}`,detail.open);
    if(item.type==='exploration'){
      const detail=[...node.children].find(c=>(c as HTMLElement).dataset.disclosure===`${item.id}:activity`)as HTMLDetailsElement|undefined;
      if(detail)for(const member of item.members)this.disclosures.set(`${item._turn}:${member.id}:activity`,detail.open);
    }
    const state=this.stateFor(item);
    state.fields=[...node.querySelectorAll<HTMLInputElement|HTMLTextAreaElement|HTMLSelectElement>('input,textarea,select')].map(e=>({label:e.getAttribute('aria-label'),value:e.value,checked:e instanceof HTMLInputElement&&e.checked}));
    for(const image of node.querySelectorAll<HTMLImageElement>('.agent-image[data-focus]'))state.images.set(image.dataset.focus!,{src:image.src,alt:image.alt});
    this.trimImageCache();
  }
  private trimImageCache():void{
    let bytes=0;for(const state of this.rowState.values())for(const image of state.images.values())bytes+=image.src.length;
    if(bytes<=32*1024*1024)return;
    for(const state of this.rowState.values())for(const[key,image]of state.images){state.images.delete(key);bytes-=image.src.length;if(bytes<=32*1024*1024)return;}
  }
  private renderRow(item:AgentObject):HTMLElement{
    const node=renderAgentItem(item,id=>this.choose(id));this.addImages(node,item);
    for(const detail of node.querySelectorAll<HTMLDetailsElement>("details[data-disclosure]"))detail.open=this.disclosures.get(`${item._turn}:${detail.dataset.disclosure}`)??false;
    if(item.type==='exploration'&&item.members.some((m:AgentObject)=>this.disclosures.get(`${item._turn}:${m.id}:activity`))){const detail=[...node.children].find(c=>(c as HTMLElement).dataset.disclosure===`${item.id}:activity`)as HTMLDetailsElement|undefined;if(detail)detail.open=true;}
    const state=this.stateFor(item);
    [...node.querySelectorAll<HTMLInputElement|HTMLTextAreaElement|HTMLSelectElement>('input,textarea,select')].forEach((e,i)=>{const saved=state.fields[i];if(saved&&saved.label===e.getAttribute('aria-label')){e.value=saved.value;if(e instanceof HTMLInputElement)e.checked=saved.checked;}});
    for(const button of node.querySelectorAll<HTMLElement>('[data-focus]')){const saved=state.images.get(button.dataset.focus!);if(saved){const image=element('img','agent-image');image.src=saved.src;image.alt=saved.alt;image.dataset.focus=button.dataset.focus;button.replaceWith(image);}}
    return node;
  }

  private loadAgentMetadata(items:AgentObject[]):void {
    const generation=this.selection;
    const referenced=new Set<string>();
    for(const item of items)if(item.type==="collabAgentToolCall"||item.type==="subAgentActivity")for(const id of item.receiverThreadIds??(item.agentThreadId?[item.agentThreadId]:[]))referenced.add(id);
    for(const id of this.agentMetadata.keys())if(!referenced.has(id))this.agentMetadata.delete(id);
    for(const id of this.metadataRequested)if(!referenced.has(id))this.metadataRequested.delete(id);
    for(const item of items){
      if(item.type!=="collabAgentToolCall"&&item.type!=="subAgentActivity")continue;
      const ids:string[]=item.receiverThreadIds??(item.agentThreadId?[item.agentThreadId]:[]);
      for(const id of ids){
        if(this.metadataInFlight>=4||this.metadataRequested.size>=128)return;
        if(this.metadataRequested.has(id))continue;
        this.metadataRequested.add(id);this.metadataInFlight++;
        void this.wire.call("read",id,{background:true}).then(result=>{
          if(generation===this.selection&&result.thread?.id===id)this.agentMetadata.set(id,result.thread);
        },()=>{}).finally(()=>{this.metadataInFlight--;if(this.shown&&this.active&&!this.disposed)this.paint();});
      }
    }
  }
  private renderRequests():void {this.resizeTranscript(()=>{
    if(this.store.requests.size)this.mobileControls.close(false);
    const root=this.$("requests");
    for(const[key,node]of this.requestNodes)if(!this.store.requests.has(key)){node.remove();this.requestNodes.delete(key);}
    for(const[key,request]of this.store.requests){if(this.requestNodes.has(key))continue;const form=this.requestForm(key,request);root.append(form);this.requestNodes.set(key,form);}
  });}
  private requestForm(key:string,request:AgentObject):HTMLElement {
    const p=request.params??{},form=element("form","agent-request"),title=element("strong","",p.reason??p.message??`${this.isClaude?"Claude":"Codex"} needs your response`);form.append(title);
    if(p.command)form.append(element("pre","agent-command",p.command));if(p.cwd)form.append(element("small","agent-path",p.cwd));
    const method=request.method,thread=p.threadId;
    const respond=(result:AgentObject)=>this.run(async()=>{await this.wire.call("answer",thread,{request:key,result});this.store.requests.delete(key);this.renderRequests();});
    const button=(label:string,result:AgentObject)=>{const b=element("button","",label);b.type="button";b.addEventListener("click",()=>respond(result));form.append(b);};
    if(method==="item/commandExecution/requestApproval"||method==="item/fileChange/requestApproval"){
      const labels:Record<string,string>={accept:"Allow once",acceptForSession:"Allow for session",decline:"Decline",cancel:"Cancel"};
      for(const decision of p.availableDecisions??["accept","acceptForSession","decline","cancel"]){
        if(typeof decision==="string"&&labels[decision])button(labels[decision],{decision});
        else if(decision?.acceptWithExecpolicyAmendment||decision?.applyNetworkPolicyAmendment){const rule=element("pre","agent-permissions",JSON.stringify(decision,null,2));form.append(rule);button(decision.acceptWithExecpolicyAmendment?"Allow and save command rule":"Apply network rule",{decision});}
        else form.append(element("p","agent-notice","This approval choice requires the host client. See the request details."));
      }
    }else if(method==="item/tool/requestUserInput"){
      const fields=new Map<string,HTMLInputElement>();
      for(const question of p.questions??[]){form.append(element("p","",question.question??question.header??question.id));const input=element("input");input.type=question.isSecret?"password":"text";input.setAttribute("aria-label",question.question??question.id);
        if(question.options?.length){const choices=element("div","agent-question-options");for(const option of question.options){const b=element("button","",option.label);b.type="button";b.title=option.description??"";b.addEventListener("click",()=>input.value=option.label);choices.append(b);}form.append(choices);}form.append(input);fields.set(question.id,input);}
      const send=element("button","","Send answers");send.type="submit";form.append(send);
      form.addEventListener("submit",e=>{e.preventDefault();respond({answers:Object.fromEntries([...fields].map(([id,input])=>[id,{answers:[input.value]}]))});});
    }else if(method==="item/permissions/requestApproval"){
      form.append(element("pre","agent-permissions",JSON.stringify(p.permissions,null,2)));button("Allow this turn",{permissions:p.permissions??{},scope:"turn"});button("Decline",{permissions:{},scope:"turn"});
    }else if(method==="mcpServer/elicitation/request"){
      if(p.mode==="url"){const href=safeLink(p.url??"");if(href){const a=element("a","","Open requested page");a.href=href;a.target="_blank";a.rel="noopener noreferrer";form.append(a);}}
      const properties=p.requestedSchema?.properties??{},fields=new Map<string,HTMLInputElement|HTMLSelectElement>();
      for(const[name,schema]of Object.entries(properties)as[string,AgentObject][]){const label=element("label","",schema.title??name);let input:HTMLInputElement|HTMLSelectElement;
        if(schema.enum){const select=element("select");for(const value of schema.enum){const option=element("option","",String(value));option.value=String(value);select.append(option);}input=select;}else{input=element("input");input.type=schema.type==="boolean"?"checkbox":schema.type==="number"||schema.type==="integer"?"number":"text";}input.dataset.schemaType=schema.type;label.append(input);form.append(label);fields.set(name,input);}
      const accept=element("button","","Accept");accept.type="submit";form.append(accept);form.addEventListener("submit",e=>{e.preventDefault();const content:AgentObject={};for(const[name,input]of fields){content[name]=input.dataset.schemaType==="boolean"?(input as HTMLInputElement).checked:["integer","number"].includes(input.dataset.schemaType??"")?Number(input.value):input.value;}respond({action:"accept",content:p.mode==="url"?null:content,_meta:null});});button("Decline",{action:"decline",content:null,_meta:null});button("Cancel",{action:"cancel",content:null,_meta:null});
    }else form.append(element("p","agent-notice","This request must be handled by its host client. Its details are available below."));
    const details=element("details");details.append(element("summary","","Request details"),element("pre","",JSON.stringify(request,null,2)));form.append(details);return form;
  }
  private renderModels():void {
    const select=this.$<HTMLSelectElement>("model"),current=select.value;select.replaceChildren(new Option("Current model",""));
    for(const model of this.models)select.add(new Option(model.displayName??model.model,model.model));select.value=current;this.syncControls();
  }
  private updateEfforts():void {
    const selected=this.models.find(m=>m.model===this.$<HTMLSelectElement>("model").value),select=this.$<HTMLSelectElement>("effort");select.replaceChildren(new Option("Current effort",""));
    for(const effort of selected?.supportedReasoningEfforts??[])select.add(new Option(effort.reasoningEffort,effort.reasoningEffort));
  }
  private syncControls():void{const metadata=this.store.metadata;const model=this.$<HTMLSelectElement>("model");model.value=this.models.some(m=>m.model===metadata.model)?metadata.model:"";this.updateEfforts();this.$<HTMLSelectElement>("effort").value=metadata.reasoningEffort??"";this.$<HTMLInputElement>("plan").checked=metadata.collaborationMode?.mode==="plan";}
  private async saveSettings(kind:"model"|"effort"|"plan"):Promise<void>{const thread=this.store.thread;if(!thread||!this.attached.has(thread))return;const args:AgentObject={};if(kind==="model"){const model=this.$<HTMLSelectElement>("model").value;if(!model)return;args.model=model;}else if(kind==="effort"){const effort=this.$<HTMLSelectElement>("effort").value;if(!effort)return;args.reasoningEffort=effort;}else args.plan=this.$<HTMLInputElement>("plan").checked;const previous=this.settingsWrites.get(thread)??Promise.resolve();const write=previous.then(()=>this.wire.call("settings",thread,args));this.settingsWrites.set(thread,write);try{await write;const settings=this.settings.get(thread)??{};Object.assign(settings,args);if(kind==="plan")settings.collaborationMode={mode:args.plan?"plan":"default"};this.settings.set(thread,settings);if(this.store.thread===thread){Object.assign(this.store.metadata,settings);this.syncControls();}}finally{if(this.settingsWrites.get(thread)===write)this.settingsWrites.delete(thread);}}
  private addImages(node:HTMLElement,item:AgentObject):void {
    if(item.questions?.length){for(const [questionIndex,question]of item.questions.entries()){const form=element("form","agent-request"),state=this.stateFor(item);if(state.replied.has(questionIndex)){form.append(element("p","","Reply sent"));node.append(form);continue;}form.append(element("strong","",question.title));const input=element("input");input.setAttribute("aria-label",question.title);for(const option of question.options??[]){const button=element("button","",option);button.type="button";button.addEventListener("click",()=>input.value=option);form.append(button);}const submit=element("button","","Reply");submit.type="submit";form.append(input,submit);const thread=this.store.thread!;form.addEventListener("submit",e=>{e.preventDefault();this.run(async()=>{const args:AgentObject={text:`Reply to “${question.title}”: ${input.value}`};const op=this.store.activeTurn?"steer":"send";if(op==="steer")args.turnId=this.store.activeTurn;await this.wire.call(op,thread,args);state.replied.add(questionIndex);form.replaceChildren(element("p","","Reply sent"));});});node.append(form);}}
    if(item._truncated){const full=element("button","agent-link","Download full record");full.type="button";full.dataset.focus=`${item.id}:full-record`;const thread=this.store.thread!;
      full.addEventListener("click",()=>this.run(async()=>{const result=await this.wire.call("record",thread,{turnId:item._turn,itemId:item.id});const url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:"application/json"}));const link=element("a","","Save full record");link.href=url;link.download=`codex-${item.id}.json`;full.replaceWith(link);setTimeout(()=>URL.revokeObjectURL(url),60000);}));node.append(full);}
    const paths:string[]=[];if(item.type==="imageView"&&item.path)paths.push(item.path);if(item.type==="imageGeneration"&&item.savedPath)paths.push(item.savedPath);
    if(item.type==="userMessage")for(const input of item.content??[]){
      if(input.type==="localImage"&&input.path)paths.push(input.path);
      if(input.type==="image"&&typeof input._assetPath==='string'&&/^input:\d+$/.test(input._assetPath))paths.push(input._assetPath);
    }
    const thread=this.store.thread!;
    for(const path of new Set(paths))node.append(this.images.slot(thread,item,path));
  }
  private async details():Promise<void> {
    const panel=this.$("details-panel");if(!panel.hidden){panel.hidden=true;return;}const thread=this.store.thread;if(!thread)return;panel.hidden=false;
    const generation=this.selection,epoch=this.wire.epoch,current=()=>generation===this.selection&&thread===this.store.thread&&this.active&&!this.disposed&&this.wire.epoch===epoch;
    const act=(op:string,args:AgentObject={})=>current()?this.wire.call(op,thread,args):Promise.reject(Error("The selected session changed"));
    const close=element("button","","Close details");close.type="button";close.addEventListener("click",()=>panel.hidden=true);
    panel.replaceChildren(close,element("h3","","Session details"),element("pre","",JSON.stringify(this.store.metadata,null,2)));
    for(const[op,label]of[["goal","Goal"],["queue-list","Queued messages"],["limits","Rate limits"]] as const){if(this.isClaude&&op!=="queue-list")continue;try{const result=await act(op);if(!current())return;panel.append(element("h3","",label),element("pre","",JSON.stringify(result,null,2)));if(op==="queue-list")for(const row of result.data??[]){const remove=element("button","","Remove queued message");remove.type="button";remove.addEventListener("click",()=>this.run(async()=>{await act("queue-delete",{id:row.id});remove.textContent="Removed";remove.disabled=true;}));panel.append(remove);}}catch(error){if(!current())return;panel.append(element("p","agent-notice",`${label}: ${String((error as Error).message)}`));}}
    if(!current())return;
    if(this.isClaude)return;
    const editGoal=element('button','','Edit goal');editGoal.type='button';editGoal.addEventListener('click',()=>{panel.hidden=true;this.run(async()=>{await this.refreshGoal();if(current())await this.goal.command('edit');});});panel.append(editGoal);
  }
}
