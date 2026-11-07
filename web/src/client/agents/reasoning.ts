import type {AgentObject} from './protocol';
const metadata=new Set(['id','type','status','turnId','startedAtMs','completedAtMs','startedAt','completedAt','durationMs','_turn','_order']);
function hasContent(value:unknown,depth=0):boolean {
 if(value==null)return false;
 if(depth>16)return true;
 if(typeof value==='string')return !!value.trim();
 if(Array.isArray(value))return value.some(v=>hasContent(v,depth+1));
 if(typeof value==='object')return Object.values(value).some(v=>hasContent(v,depth+1));
 if(typeof value==='number'||typeof value==='boolean')return !!value;
 return true;
}
/** Hide empty live placeholders; keep canonical records so later deltas can populate them. */
export function emptyReasoning(item:AgentObject):boolean {
 return item.type==='reasoning'&&!Object.entries(item).some(([key,value])=>!metadata.has(key)&&hasContent(value));
}
