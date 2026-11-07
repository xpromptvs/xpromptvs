import type {AgentObject} from "./protocol";
export type SearchSession = AgentObject & {id:string};

/** Debounced indexed title search, plus project matching in the recent result set. */
export class AgentSearch {
 private generation=0;
 private timer:ReturnType<typeof setTimeout>|undefined;
 private recent:SearchSession[]=[];
 constructor(private load:(query:string)=>Promise<AgentObject[]>,private update:(rows:SearchSession[],notice:string)=>void){}
 query(query:string):void {
  clearTimeout(this.timer);const generation=++this.generation,q=query.trim().toLowerCase();
  const matches=(row:AgentObject)=>!q||[row.name,row.preview,row.cwd,row.provider].some(s=>typeof s==="string"&&s.toLowerCase().includes(q));
  this.update(this.recent.filter(matches),"Searching agent sessions…");
  this.timer=setTimeout(()=>{void this.load(query).then(result=>{
   if(generation!==this.generation)return;
   const rows=result.filter((r):r is SearchSession=>typeof r.id==="string"&&r.id.length>0);
   if(!q)this.recent=rows.slice(0,100);
   const merged=new Map([...rows,...this.recent.filter(matches)].map(row=>[row.id,row]));
   this.update([...merged.values()],"");
  },error=>{if(generation===this.generation)this.update(this.recent.filter(matches),String(error?.message??error));});},200);
 }
 reset():void {this.generation++;clearTimeout(this.timer);this.recent=[];this.update([],"");}
}
