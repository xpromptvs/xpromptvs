import {expect,it,vi} from 'vitest';
import {LiveSubagents} from '../src/client/agents/subagents';
const tick=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
const child=(id='child',parent='parent',type='active')=>({id,parentThreadId:parent,agentNickname:id==='child'?'Ada':id,agentRole:'explorer',status:{type,activeFlags:[]}});
it('shows only live direct children, navigates without taking control, and retains parent return',async()=>{
 const root=document.createElement('nav'),selected:string[]=[],calls:string[]=[];
 const strip=new LiveSubagents(root,async id=>{calls.push(id);return {data:[child(),child('idle','parent','idle'),child('saved','parent','notLoaded'),child('other','elsewhere')]};},id=>selected.push(id));
 try{strip.setVisible(true);strip.show({id:'parent',name:'Parent work'});await tick();expect(root.textContent).toContain('Ada');expect(root.textContent).not.toContain('idle');expect(root.textContent).not.toContain('saved');expect(root.querySelectorAll('[data-subagent]')).toHaveLength(1);
 (root.querySelector('[data-subagent="child"]')as HTMLButtonElement).click();expect(selected).toEqual(['child']);strip.show(child());await tick();(root.querySelector('[data-parent="parent"]')as HTMLButtonElement).click();expect(selected).toEqual(['child','parent']);expect(calls).toEqual(['parent','child']);
 }finally{strip.dispose();}
});
it('fences stale replies and stops polling when hidden',async()=>{
 vi.useFakeTimers();const root=document.createElement('nav'),pending:{id:string;resolve:(v:any)=>void}[]=[];
 const strip=new LiveSubagents(root,id=>new Promise(resolve=>pending.push({id,resolve})),()=>{});
 try{strip.setVisible(true);strip.show({id:'old'});strip.show({id:'new'});pending[0]!.resolve({data:[child('stale','old')]});await tick();expect(root.textContent).not.toContain('stale');pending[1]!.resolve({data:[child('fresh','new')]});await tick();expect(root.textContent).toContain('fresh');strip.setVisible(false);await vi.advanceTimersByTimeAsync(10000);expect(pending).toHaveLength(2);expect(root.hidden).toBe(true);
 }finally{strip.dispose();vi.useRealTimers();}
});
it('polls serially, preserves focused child buttons, and removes completed agents',async()=>{
 vi.useFakeTimers();const root=document.createElement('nav');document.body.append(root);let count=0;let next:any[]=[child()];
 const strip=new LiveSubagents(root,async()=>{count++;return {data:next};},()=>{});
 try{strip.setVisible(true);strip.show({id:'parent'});await tick();const button=root.querySelector<HTMLButtonElement>('[data-subagent="child"]')!;button.focus();await vi.advanceTimersByTimeAsync(3001);expect(count).toBe(2);expect(document.activeElement).toBe(button);next=[child('child','parent','idle')];await vi.advanceTimersByTimeAsync(3001);expect(root.querySelector('[data-subagent]')).toBeNull();expect(root.hidden).toBe(true);
 }finally{strip.dispose();root.remove();vi.useRealTimers();}
});
it('does not overlap a slow poll or retain live rows after a failed refresh',async()=>{
 vi.useFakeTimers();const root=document.createElement('nav');const pending:{resolve:(v:any)=>void;reject:(e:Error)=>void}[]=[];
 const strip=new LiveSubagents(root,()=>new Promise((resolve,reject)=>pending.push({resolve,reject})),()=>{});
 try{strip.setVisible(true);strip.show({id:'parent'});await vi.advanceTimersByTimeAsync(10000);expect(pending).toHaveLength(1);pending[0]!.resolve({data:[child()]});await tick();await vi.advanceTimersByTimeAsync(3001);pending[1]!.reject(Error('unavailable'));await tick();expect(root.querySelector('[data-subagent]')).toBeNull();expect(root.textContent).toContain('unavailable');
 }finally{strip.dispose();vi.useRealTimers();}
});

it('stops discovery while the document is hidden and refreshes on return',async()=>{
 vi.useFakeTimers();const hidden=vi.spyOn(document,'hidden','get');hidden.mockReturnValue(false);
 const root=document.createElement('nav');let calls=0;const strip=new LiveSubagents(root,async()=>{calls++;return {data:[child()]};},()=>{});
 try{strip.setVisible(true);strip.show({id:'parent'});await tick();hidden.mockReturnValue(true);document.dispatchEvent(new Event('visibilitychange'));await vi.advanceTimersByTimeAsync(9000);expect(calls).toBe(1);hidden.mockReturnValue(false);document.dispatchEvent(new Event('visibilitychange'));await tick();expect(calls).toBe(2);}
 finally{strip.dispose();hidden.mockRestore();vi.useRealTimers();}
});
