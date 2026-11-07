import type {AgentObject} from './protocol';
import {emptyReasoning} from './reasoning';

/** Canonical records remain untouched; both replay and live paint use this projection. */
export function projectTranscript(items:AgentObject[],agentMetadata?:ReadonlyMap<string,AgentObject>):AgentObject[] {
  const result:AgentObject[]=[];
  let group:AgentObject|undefined;
  const changes=new Map<string,AgentObject>();
  const aggregates=new Map<string,AgentObject>();
  for(const item of items){
    if(item.type==='fileChange'&&item.changes?.length)changes.set(item._turn,item);
    else if(item.type==='fileChange'&&typeof item.diff==='string')aggregates.set(item._turn,item);
  }
  for(const item of items){
    if(emptyReasoning(item))continue;
    const actions=item.commandActions;
    const exploring=item.type==='commandExecution'&&item.source!=='userShell'&&item.status!=='declined'&&!(item.status==='failed'&&item.exitCode==null)&&Array.isArray(actions)&&actions.length>0&&actions.every((a:AgentObject)=>['read','listFiles','search'].includes(a.type));
    if(group&&group._turn!==item._turn)group=undefined;
    if(exploring){
      if(!group){group={id:`explore:${item.id}`,type:'exploration',_turn:item._turn,members:[],_sources:[]};result.push(group);}
      group.members.push(item);group._sources.push(item);
      if(item.exitCode!=null&&item.exitCode!==0)group=undefined;
      continue;
    }
    if(group&&item.type==='reasoning'){group.members.push(item);group._sources.push(item);continue;}
    group=undefined;
    const aggregate=aggregates.get(item._turn);
    if(item===aggregate&&changes.has(item._turn))continue;
    if(item===changes.get(item._turn)&&aggregate){result.push({...item,turnDiff:aggregate.diff,_sources:[item,aggregate]});continue;}
    if(agentMetadata&&(item.type==='collabAgentToolCall'||item.type==='subAgentActivity')){
      const ids:string[]=item.receiverThreadIds??(item.agentThreadId?[item.agentThreadId]:[]);
      const metadata=ids.map(id=>agentMetadata.get(id)).filter((m):m is AgentObject=>!!m);
      if(metadata.length){result.push({...item,agentMetadata:Object.fromEntries(metadata.map(m=>[m.id,m])),_sources:[item,...metadata]});continue;}
    }
    result.push(item);
  }
  return result;
}
export function samePresentation(a:AgentObject,b:AgentObject):boolean {
  if(a===b)return true;
  const left=a._sources as AgentObject[]|undefined,right=b._sources as AgentObject[]|undefined;
  return !!left&&!!right&&a.id===b.id&&left.length===right.length&&left.every((source,i)=>source===right[i]);
}
