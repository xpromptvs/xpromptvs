import {it,expect,vi} from 'vitest';
import {AgentGoal} from '../src/client/agents/goal';
import {AgentStore} from '../src/client/agents/store';
it('shows the authoritative goal status, objective and supplied usage without inventing a budget',()=>{
 const root=document.createElement('div'),goal=new AgentGoal(root,{change:fn=>fn(),mutate:async()=>{}});
 goal.update({objective:'Finish the project',status:'active',tokensUsed:12500,tokenBudget:50000,timeUsedSeconds:90},true,true);
 expect(root.textContent).toContain('Finish the project');expect(root.textContent).toContain('Active');expect(root.textContent).toContain('12.5K / 50K');
 goal.update({objective:'Read',status:'paused',tokensUsed:400,timeUsedSeconds:60},true,true);
 expect(root.textContent).toContain('Paused');expect(root.textContent).not.toContain('/ 50K');expect(root.textContent).toContain('1m');
 goal.update(null,true,true);expect(root.hidden).toBe(true);
});
it('opens an explicit goal editor and only saves when asked, with an optional budget',async()=>{
 const root=document.createElement('div'),mutate=vi.fn(async()=>{}),goal=new AgentGoal(root,{change:fn=>fn(),mutate});goal.update(null,true,true);
 await goal.command('');expect(root.hidden).toBe(false);expect(mutate).not.toHaveBeenCalled();
 const objective=root.querySelector<HTMLTextAreaElement>('[data-goal="objective"]')!;objective.value='Build this';
 root.querySelector<HTMLFormElement>('form')!.requestSubmit();await Promise.resolve();
 expect(mutate).toHaveBeenCalledWith('goal-set',{objective:'Build this',status:'active'});
});
it('uses explicit pause/resume/clear operations and leaves unsupported providers alone',async()=>{
 const root=document.createElement('div'),mutate=vi.fn(async()=>{}),goal=new AgentGoal(root,{change:fn=>fn(),mutate});goal.update({objective:'Build',status:'active'},true,true);
 await goal.command('pause');expect(mutate).toHaveBeenLastCalledWith('goal-set',{status:'paused'});
 await goal.command('resume');expect(mutate).toHaveBeenLastCalledWith('goal-set',{status:'active'});
 await goal.command('clear');expect(mutate).toHaveBeenLastCalledWith('goal-clear',{});
 goal.update(null,true,false);await expect(goal.command('Build')).rejects.toThrow('not supported');expect(root.hidden).toBe(true);
});
it('keeps an edited objective and can explicitly remove its existing token budget',async()=>{
 const root=document.createElement('div'),mutate=vi.fn(async()=>{}),goal=new AgentGoal(root,{change:fn=>fn(),mutate});
 goal.update({objective:'Original',status:'paused',tokenBudget:5000},true,true);await goal.command('edit');
 const input=root.querySelector<HTMLTextAreaElement>('[data-goal="objective"]')!;input.value='My edited draft';
 goal.update({objective:'Other client updated',status:'paused',tokenBudget:5000,tokensUsed:30},true,true);expect(input.value).toBe('My edited draft');
 root.querySelector<HTMLInputElement>('[data-goal="budget"]')!.value='';root.querySelector<HTMLFormElement>('form')!.requestSubmit();await Promise.resolve();
 expect(mutate).toHaveBeenCalledWith('goal-set',{objective:'My edited draft',status:'paused',tokenBudget:null});
});
it('applies goal clear events only to the matching thread',()=>{
 const store=new AgentStore();store.select('one');store.metadata.goal={objective:'Build'};
 store.event({method:'thread/goal/cleared',params:{threadId:'two'}});expect(store.metadata.goal).toBeTruthy();
 store.event({method:'thread/goal/cleared',params:{threadId:'one'}});expect(store.metadata.goal).toBeNull();
});
