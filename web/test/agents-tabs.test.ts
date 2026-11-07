import {it,expect} from "vitest";
import {AgentTabs} from "../src/client/agents/tabs";
it("keeps agent tab identity, selects only the shown session and closes without selecting",()=>{
 const root=document.createElement("div");const selected:string[]=[],closed:string[]=[];
 const tabs=new AgentTabs(root,{select:id=>selected.push(id),close:id=>closed.push(id)});
 const rows=[{id:"one",title:"Build",cwd:"/project"},{id:"two",title:"Review",cwd:"/project"}];
 tabs.update(rows,"one",true);
 const first=root.querySelector<HTMLElement>('[data-tab-key="agent:one"]')!;
 expect(first.getAttribute("aria-selected")).toBe("true");
 tabs.update(rows,"two",true);expect(root.firstElementChild).toBe(first);
 first.querySelector<HTMLElement>(".rl-tab-close")!.click();
 expect(closed).toEqual(["one"]);expect(selected).toEqual([]);
 tabs.update(rows,null,true);expect(root.querySelector('[aria-selected="true"]')).toBeNull();
 tabs.update(rows,"one",false);expect(root.childElementCount).toBe(0);
});
it("uses actual Codex runtime activity for the terminal working treatment",()=>{
 const root=document.createElement("div");const tabs=new AgentTabs(root,{select:()=>{},close:()=>{}});
 tabs.update([{id:"one",title:"Build",cwd:"",status:"active"}],"one",true);
 const tab=root.querySelector<HTMLElement>(".rl-tab")!;expect(tab.hasAttribute("data-agent-working")).toBe(true);expect(tab.getAttribute("aria-busy")).toBe("true");
 tabs.update([{id:"one",title:"Build",cwd:"",status:"idle"}],"one",true);expect(tab.hasAttribute("data-agent-working")).toBe(false);expect(tab.title).toContain("Ready");
 tabs.update([{id:"one",title:"Build",cwd:"",status:"active",activeFlags:["waitingOnApproval"]}],"one",true);expect(tab.hasAttribute("data-agent-working")).toBe(false);expect(tab.title).toContain("Ready");
 tabs.update([{id:"one",title:"Build",cwd:""}],"one",true);expect(tab.title).not.toContain("Ready");
});
it("keeps unchanged label text nodes through selection and activity updates",()=>{
 const root=document.createElement("div");const tabs=new AgentTabs(root,{select:()=>{},close:()=>{}});
 const rows=[{id:"one",title:"Build",cwd:"",status:"active"},{id:"two",title:"Review",cwd:"",status:"idle"}] as const;
 tabs.update(rows,"one",true);
 const labels=[...root.querySelectorAll(".rl-tab-label")];const text=labels.map(label=>label.firstChild);
 tabs.update(rows.map(row=>({...row,status:"idle"})),"two",true);
 labels.forEach((label,i)=>expect(label.firstChild).toBe(text[i]));
 tabs.update([{...rows[0],name:"Renamed"},rows[1]],"two",true);
 expect(labels[0]!.textContent).toBe("Renamed");expect(labels[1]!.firstChild).toBe(text[1]);
});
