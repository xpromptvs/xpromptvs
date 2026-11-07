import {expect,it} from 'vitest';
import {projectTranscript} from '../src/client/agents/presentation';
import {AgentStore} from '../src/client/agents/store';
const read=(id:string,turn='t',exit=0)=>({id,_turn:turn,type:'commandExecution',command:'cat '+id,commandActions:[{type:'read',name:id,path:'/repo/'+id}],status:'completed',exitCode:exit});
it('groups semantic exploration, retains reasoning, and stops at failures and turn boundaries',()=>{
 const items=[read('one'),{id:'r',_turn:'t',type:'reasoning',summary:['Check it']},read('missing','t',1),read('two'),read('three','other')];
 const cells=projectTranscript(items);
 expect(cells.map(c=>c.type)).toEqual(['exploration','exploration','exploration']);
 expect(cells[0]!.members.map((m:any)=>m.id)).toEqual(['one','r','missing']);
 expect(cells[1]!.members.map((m:any)=>m.id)).toEqual(['two']);
 expect(cells[2]!._turn).toBe('other');
});
it('never guesses exploration from shell text or hides user-shell commands',()=>{
 const items=[{...read('one'),commandActions:[]},{...read('two'),source:'userShell'},{id:'u',_turn:'t',type:'userMessage',content:[]},read('three')];
 expect(projectTranscript(items).map(c=>c.type)).toEqual(['commandExecution','commandExecution','userMessage','exploration']);
});
it('retains cumulative diff as detail on the last actual change instead of duplicating it',()=>{
 const change={id:'patch',_turn:'t',type:'fileChange',changes:[{path:'a.ts',diff:'-a\n+b'}]};
 const aggregate={id:'t-diff',_turn:'t',type:'fileChange',diff:'combined'};
 const cells=projectTranscript([change,aggregate]);
 expect(cells).toHaveLength(1);expect(cells[0]!.turnDiff).toBe('combined');expect(cells[0]!._sources).toEqual([change,aggregate]);
});
it('preserves one completion footer and converges live and restored turn timing',()=>{
 const turn={id:'t',status:'completed',items:[{id:'a',type:'agentMessage',text:'Done',phase:'final_answer'}],startedAt:100,completedAt:162,durationMs:62000};
 const restored=new AgentStore();restored.select('s');restored.hydrate([turn]);
 const live=new AgentStore();live.select('s');live.event({method:'turn/started',params:{threadId:'s',turn:{...turn,status:'inProgress',completedAt:null,durationMs:null,items:[]}}});
 live.event({method:'item/completed',params:{threadId:'s',turnId:'t',item:turn.items[0]}});
 live.event({method:'turn/completed',params:{threadId:'s',turn}});live.event({method:'turn/completed',params:{threadId:'s',turn}});
 for(const store of[restored,live]){const footer=projectTranscript(store.items()).filter(c=>c.type==='turnCompletion');expect(footer).toHaveLength(1);expect(footer[0]!.durationMs).toBe(62000);expect(footer[0]!.completedAt).toBe(162);}
});
it('uses supplied child-thread metadata for agent names without inventing state fields',()=>{
 const item={id:'spawn',_turn:'t',type:'collabAgentToolCall',receiverThreadIds:['child'],agentsStates:{child:{status:'completed',message:'Done'}}};
 const metadata={id:'child',agentNickname:'Robie',agentRole:'explorer'};
 const cells=projectTranscript([item],new Map([['child',metadata]]));
 expect(cells[0]!.agentMetadata.child.agentNickname).toBe('Robie');expect(cells[0]!._sources).toEqual([item,metadata]);
});
it('hides empty reasoning placeholders without losing a later live summary',()=>{
 const store=new AgentStore();store.select('s');
 store.hydrate([{id:'t',status:'inProgress',items:[{id:'empty',type:'reasoning',summary:[],content:[]},{id:'full',type:'reasoning',summary:['Keep this'],content:[]}]}]);
 expect(projectTranscript(store.items()).filter(i=>i.type==='reasoning').map(i=>i.id)).toEqual(['full']);
 store.event({method:'item/reasoning/summaryTextDelta',params:{threadId:'s',turnId:'t',itemId:'empty',delta:'Now visible'}});
 expect(projectTranscript(store.items()).filter(i=>i.type==='reasoning').map(i=>i.id)).toEqual(['empty','full']);
 expect(projectTranscript([{id:'partial',type:'reasoning',summary:[],content:[],_truncated:true}])).toHaveLength(1);
 expect(projectTranscript([{id:'blank',type:'reasoning',summary:['  \n'],content:[],_turn:'t',_order:2}])).toHaveLength(0);
 expect(projectTranscript([{id:'timed',type:'reasoning',summary:[],content:[],startedAtMs:1793722173939,completedAtMs:1793722173939}])).toHaveLength(0);
 const filtered=new AgentStore();filtered.select('s');filtered.hydrate([{id:'t',status:'inProgress',items:[]}]);
 filtered.event({method:'item/reasoning/summaryTextDelta',params:{threadId:'s',turnId:'t',itemId:'host-filtered',delta:'Text arriving after host filtering'}});
 expect(projectTranscript(filtered.items()).find(i=>i.id==='host-filtered')?.text).toBe('Text arriving after host filtering');
});
