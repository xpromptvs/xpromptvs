import {expect,it} from 'vitest';
import {renderAgentItem,markdown} from '../src/client/agents/render';
it('shows the first three command output lines with hidden count and full readable details',()=>{
 const node=renderAgentItem({id:'cmd',type:'commandExecution',command:'npm test',status:'completed',exitCode:0,aggregatedOutput:'one\ntwo\nthree\nfour\nfive'});
 expect(node.querySelector('.agent-item-title')?.textContent).toContain('Ran');
 expect(node.querySelector('.agent-preview')?.textContent).toContain('three');
 expect(node.querySelector('.agent-preview')?.textContent).not.toContain('four');
 const details=node.querySelector('details[data-disclosure="cmd:output"]');expect(details?.textContent).toContain('2 more lines');expect(details?.textContent).toContain('one');
});
it('keeps submitted prompts literal and renders assistant markdown structurally and safely',()=>{
 const user=renderAgentItem({id:'u',type:'userMessage',content:[{type:'text',text:'**literal**\n- prompt'}]});expect(user.querySelector('strong')).toBeNull();expect(user.textContent).toContain('**literal**');
 const m=markdown('# Title\n\n- first\n  - nested\n\n> quoted\n\n| A | B |\n| - | - |\n| x | y |\n\n```ts\nconst answer = 42;\n```\n\n<img src=x onerror=alert(1)> [bad](javascript:alert(1)) ![remote](https://example.com/pixel.png)');
 expect(m.querySelector('h1')?.textContent).toBe('Title');expect(m.querySelectorAll('ul')).toHaveLength(2);expect(m.querySelector('blockquote')?.textContent).toContain('quoted');expect(m.querySelector('td')?.textContent).toBe('x');expect(m.querySelector('code')?.textContent).toContain('const answer');expect(m.querySelector('img')).toBeNull();expect(m.querySelector('a[href^="javascript:"]')).toBeNull();
});
it('renders supplied dynamic and function output text arrays instead of raw JSON only',()=>{
 const dynamic=renderAgentItem({id:'d',type:'dynamicToolCall',namespace:'local',tool:'inspect',status:'completed',success:true,contentItems:[{type:'inputText',text:'Useful dynamic result'}]});
 expect(dynamic.querySelector('.agent-preview')?.textContent).toContain('Useful dynamic result');expect(dynamic.querySelector('.agent-item-title')?.textContent).toContain('Called local.inspect');
 const fn=renderAgentItem({id:'f',type:'functionCallOutput',name:'inspect',output:[{type:'input_text',text:'Useful function result'}]});expect(fn.querySelector('.agent-preview')?.textContent).toContain('Useful function result');
});
it('uses ANSI colors without allowing OSC clipboard, hyperlinks, HTML or controls',()=>{
 const node=renderAgentItem({id:'cmd',type:'commandExecution',command:'test',status:'failed',exitCode:1,aggregatedOutput:'\x1b[31mFAILED\x1b[0m\n\x1b]52;c;secret\x07safe <script>bad()</script>'});
 expect(node.querySelector('.ansi-red')?.textContent).toContain('FAILED');expect(node.textContent).toContain('safe <script>bad()</script>');expect(node.querySelector('script')).toBeNull();expect(node.querySelector('.agent-preview')?.textContent).not.toContain('secret');expect(node.querySelector('.agent-item-title')?.textContent).toContain('Exited (status 1)');
});
it('renders exploration and keeps failed commands and reasoning in the expanded detail',()=>{
 const n=renderAgentItem({id:'e',type:'exploration',members:[{id:'r',type:'commandExecution',command:'cat a.ts',commandActions:[{type:'read',name:'a.ts'}],status:'completed',exitCode:0},{id:'why',type:'reasoning',summary:['Check the file']},{id:'bad',type:'commandExecution',command:'cat missing',commandActions:[{type:'read',name:'missing'}],status:'completed',exitCode:1}]});
 expect(n.querySelector('.agent-item-title')?.textContent).toContain('Explored');expect(n.querySelector('.agent-preview')?.textContent).toContain('missing');expect(n.textContent).toContain('Check the file');expect(n.textContent).toContain('exit 1');
});
it('renders numbered colored diffs, plan progress and agent lifecycle metadata',()=>{
 const diff=renderAgentItem({id:'p',type:'fileChange',status:'completed',changes:[{path:'/repo/a.ts',kind:{type:'update'},diff:'@@ -7,2 +7,2 @@\n before\n-old\n+new'}]});expect(diff.querySelector('.agent-item-title')?.textContent).toContain('Edited 1 file (+1 -1)');expect(diff.querySelector('.agent-diff-add')?.textContent).toContain('8');expect(diff.querySelector('.agent-diff-add')?.textContent).toContain('+new');
 const plan=renderAgentItem({id:'p',type:'plan',plan:[{step:'Inspect',status:'completed'},{step:'Fix',status:'inProgress'}]});expect(plan.querySelector('.agent-item-title')?.textContent).toContain('Updated Plan · 1/2 complete');expect(plan.textContent).toContain('✔ Inspect');
 const agent=renderAgentItem({id:'a',type:'collabAgentToolCall',tool:'spawnAgent',status:'completed',receiverThreadIds:['child'],agentsStates:{child:{status:'completed',message:'Finished'}},agentMetadata:{child:{agentNickname:'Robie',agentRole:'explorer'}},model:'gpt-test',reasoningEffort:'high'});expect(agent.textContent).toContain('Spawned');expect(agent.textContent).toContain('Robie');expect(agent.textContent).toContain('gpt-test high');
});
it('offers completed reasoning as readable disclosure and keeps unknown content available',()=>{
 const r=renderAgentItem({id:'r',type:'reasoning',summary:['Why this works'],content:['Detail']});expect(r.querySelector('details[data-disclosure="r:reasoning"]')?.textContent).toContain('Why this works');expect(r.querySelector('details')?.open).toBe(false);
 const u=renderAgentItem({id:'u',type:'futureTool',payload:{answer:42}});expect(u.textContent).toContain('42');
});
it('formats supplied completion duration and time without inventing missing metadata',()=>{
 const n=renderAgentItem({id:'t',type:'turnCompletion',durationMs:62000,completedAt:1793685631});expect(n.textContent).toContain('Worked for 1m 2s');expect(n.querySelector('time')?.dateTime).toBe(new Date(1793685631000).toISOString());
});
it('does not present declined or failed operations as successfully completed',()=>{
 for(const status of ['declined','failed']){
  const command=renderAgentItem({id:'c',type:'commandExecution',command:'dangerous-command',status,exitCode:null});
  expect(command.querySelector('.agent-item-title')?.textContent).toContain(status==='declined'?'Declined':'Failed');
  const patch=renderAgentItem({id:'p',type:'fileChange',status,changes:[{path:'a.ts',diff:'+new'}]});
  expect(patch.querySelector('.agent-item-title')?.textContent).not.toContain('Edited');
 }
});
it('loads supplied raster tool images only on request and never loads SVG or remote pixels automatically',()=>{
 const node=renderAgentItem({id:'m',type:'mcpToolCall',server:'images',tool:'view',status:'completed',result:{content:[{type:'image',mimeType:'image/png',data:'iVBORw0KGgo='},{type:'image',mimeType:'image/svg+xml',data:'PHN2Zz48L3N2Zz4='}]}});
 expect(node.querySelector('img')).toBeNull();const button=[...node.querySelectorAll('button')].find(b=>b.textContent==='Show image');expect(button).toBeTruthy();button!.click();expect(node.querySelector('img')?.src).toBe('data:image/png;base64,iVBORw0KGgo=');expect(node.querySelectorAll('img')).toHaveLength(1);
 const external=renderAgentItem({id:'d',type:'dynamicToolCall',tool:'image',status:'completed',contentItems:[{type:'inputImage',imageUrl:'https://example.com/pixel.png'}]});expect(external.querySelector('img')).toBeNull();expect(external.querySelector('a[href="https://example.com/pixel.png"]')).not.toBeNull();
});
it('folds multiline executed commands into one header line with full command and output in details',()=>{
 const command="python3 - <<'PY'\nprint('large script')\nprint('second line')\nPY";
 const n=renderAgentItem({id:'folded',type:'commandExecution',command,status:'completed',exitCode:0,aggregatedOutput:'first\nsecond\nthird\nfourth\nfifth',cwd:'/repo',durationMs:12});
 const header=n.querySelector('.agent-item-title')!;
 expect(header.textContent).toContain("python3 - <<'PY'");expect(header.textContent).toContain('…');expect(header.textContent).not.toContain('large script');
 expect(n.querySelector('.agent-preview')?.textContent).toContain('third');expect(n.querySelector('.agent-preview')?.textContent).not.toContain('fourth');
 const details=n.querySelector<HTMLDetailsElement>('details[data-disclosure="folded:output"]')!;
 expect(details.open).toBe(false);expect(details.querySelector('summary')?.textContent).toContain('Show details');
 expect(details.textContent).toContain(command);expect(details.textContent).toContain('first');expect(details.textContent).toContain('fifth');expect(details.textContent).toContain('/repo');
});

it('strips only recognized complete shell wrappers from compact command titles',()=>{
 const command=`/bin/zsh -lc 'python3 - <<"PY"
print("hello")
PY'`;
 const node=renderAgentItem({id:'wrapped',type:'commandExecution',command,status:'completed',exitCode:0,aggregatedOutput:''});
 expect(node.querySelector('.agent-command-title code')?.textContent).toBe('python3 - <<"PY" …');
 expect(node.querySelector('.agent-command-full')?.textContent).toBe(command);
 expect(node.querySelector('.agent-preview')?.textContent).toBe('(no output)');
 expect(node.querySelector('.agent-activity-dot')).not.toBeNull();
 const compound=renderAgentItem({id:'compound',type:'commandExecution',command:"/bin/zsh -lc 'echo one' && echo two",status:'completed'});
 expect(compound.querySelector('.agent-command-title code')?.textContent).toContain('/bin/zsh');
 const dynamic=renderAgentItem({id:'dynamic',type:'commandExecution',command:'/bin/sh -c "$SCRIPT"',status:'completed'});
 expect(dynamic.querySelector('.agent-command-title code')?.textContent).toBe('/bin/sh -c "$SCRIPT"');
});
it('keeps compact long output as bounded ANSI-safe logical rows while full details retain every byte of text',()=>{
 const output='\x1b[31m'+ 'x'.repeat(20000)+'\x1b[0m\nsecond\nthird\nfourth';
 const node=renderAgentItem({id:'huge',type:'commandExecution',command:'probe',status:'completed',aggregatedOutput:output});
 const compact=node.querySelector('.agent-output-preview')!;
 expect(compact.children).toHaveLength(3);expect(compact.textContent!.length).toBeLessThan(17000);
 expect(compact.querySelector('.ansi-red')).not.toBeNull();expect(compact.textContent).not.toContain('fourth');
 expect(node.querySelector('.agent-command-expanded')?.textContent).toContain('x'.repeat(20000));
});
