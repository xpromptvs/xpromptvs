import type {AgentObject} from './protocol';
import {element,json,safeLink} from './dom';
import {markdown} from './markdown';
import {ansiOutput,ansiOutputPreview,outputLines} from './output';
import {commandDisplay} from './command';
export {element,safeLink,markdown};

function disclosure(id:string,label:string,content:HTMLElement,className='agent-disclosure'):HTMLDetailsElement{
  const details=element('details',className),summary=element('summary','',label);details.dataset.disclosure=id;summary.dataset.focus=id+':summary';details.append(summary,content);return details;
}
function download(item:AgentObject):HTMLAnchorElement{
  const a=element('a','agent-download','Download record');a.dataset.focus=`${item.id}:download`;a.href='#';a.addEventListener('click',e=>{
    e.preventDefault();const url=URL.createObjectURL(new Blob([json(item)],{type:'application/json'}));
    const link=element('a');link.href=url;link.download=`codex-${String(item.id).replace(/[^\w-]/g,'_')}.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  });return a;
}
function record(item:AgentObject):HTMLElement{
  const detail=disclosure(`${item.id}:record`,'Record details',ansiOutput(json(item)),'agent-record');detail.append(download(item));return detail;
}
function header(title:string,state=''):HTMLElement{
  const h=element('header','agent-item-title');h.append(element('span','agent-action',title));
  if(state)h.dataset.state=state;return h;
}
function preview(text:string,id:string):HTMLElement{
  const box=element('div','agent-tool-output'),lines=outputLines(text),short=element('div','agent-preview');
  short.append(ansiOutput(text,3));box.append(short);
  if(lines>3)box.append(disclosure(`${id}:output`,`Show output · ${lines-3} earlier lines`,ansiOutput(text)));
  return box;
}
export function formatDuration(ms:number):string{
  const seconds=Math.floor(ms/1000);if(seconds<1)return '<1s';
  const h=Math.floor(seconds/3600),m=Math.floor(seconds%3600/60),s=seconds%60;
  return h?`${h}h ${m}m ${s}s`:m?`${m}m ${s}s`:`${s}s`;
}
function contentText(value:unknown):string{
  if(typeof value==='string')return value;
  if(Array.isArray(value))return value.map(part=>{
    if(typeof part==='string')return part;
    if(part&&typeof part==='object'){
      const p=part as AgentObject;if(typeof p.text==='string')return p.text;
      if(/image/i.test(p.type??''))return '[Image content]';if(/audio/i.test(p.type??''))return '[Audio content]';if(/encrypted/i.test(p.type??''))return '[Encrypted content]';
    }return json(part);
  }).join('\n');
  if(value&&typeof value==='object'){const v=value as AgentObject;if(Array.isArray(v.content))return contentText(v.content);if(typeof v.message==='string')return v.message;}
  return value==null?'':json(value);
}
function contentImages(parent:HTMLElement,item:AgentObject):void{
  const blocks=[...(Array.isArray(item.contentItems)?item.contentItems:[]),...(Array.isArray(item.output)?item.output:[]),...(Array.isArray(item.result?.content)?item.result.content:[])];
  for(const [index,block] of blocks.slice(0,16).entries()){
    if(!block||typeof block!=="object")continue;
    let url=block.imageUrl??block.image_url??block.url;
    if(block.type==="image"&&typeof block.data==="string"&&/^image\/(png|jpeg|webp|gif)$/.test(block.mimeType??""))url=`data:${block.mimeType};base64,${block.data}`;
    if(typeof url!=="string")continue;
    if(url.length<=8*1024*1024&&/^data:image\/(?:png|jpeg|webp|gif);base64,[A-Za-z0-9+/=\r\n]+$/.test(url)){
      const button=element("button","agent-link","Show image");button.type="button";button.dataset.focus=`${item.id}:image:${index}`;button.addEventListener("click",()=>{const image=element("img","agent-image");image.alt="Tool image";image.dataset.focus=button.dataset.focus;image.src=url;button.replaceWith(image);});parent.append(button);
    }else if(/image/i.test(block.type??"")){
      const href=safeLink(url);if(href&&/^https?:/.test(href)){const link=element("a","agent-link","Open image");link.href=href;link.target="_blank";link.rel="noopener noreferrer";parent.append(link);}
    }
  }
}
function addDiff(parent:HTMLElement,diff:string):void{
  const box=element('pre','agent-diff');let old=1,current=1;
  for(const text of diff.split('\n')){
    const hunk=/^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(text);
    if(hunk){old=Number(hunk[1]);current=Number(hunk[2]);box.append(element('div','agent-diff-hunk',text));continue;}
    if(/^(?:diff |index |--- |\+\+\+ )/.test(text)){box.append(element('div','agent-diff-meta',text));continue;}
    const added=text.startsWith('+'),removed=text.startsWith('-'),line=element('div',added?'agent-diff-add':removed?'agent-diff-remove':'agent-diff-context');
    line.append(element('span','agent-diff-number',String(removed?old:current)),document.createTextNode(text));box.append(line);
    if(!added)old++;if(!removed)current++;
  }parent.append(box);
}
function agentLabel(id:string,item:AgentObject):string{
  const info=item.agentMetadata?.[id]??item.agentsStates?.[id]??{};
  return (info.agentNickname??info.agentPath??item.agentPath??`Agent ${id.slice(0,8)}`)+(info.agentRole?` [${info.agentRole}]`:'');
}
function agentButton(id:string,item:AgentObject,navigate?:((id:string)=>void)):HTMLButtonElement{
  const b=element('button','agent-link',agentLabel(id,item));b.type='button';b.dataset.focus=`${item.id}:agent:${id}`;b.addEventListener('click',()=>navigate?.(id));return b;
}
export function renderAgentItem(item:AgentObject,navigate?:(thread:string)=>void):HTMLElement{
  const article=element('article',`agent-item agent-${item.type??'unknown'}`);article.dataset.item=item.id;
  if(item.phase)article.dataset.phase=item.phase;
  if(item._partial)article.append(element('p','agent-sync-note','Earlier output will be restored when this item completes.'));
  if(item._synchronizing)article.append(element('p','agent-sync-note','Synchronizing saved output; the complete item will appear when it finishes.'));
  if(item._truncated)article.append(element('p','agent-sync-note','This large record is partial. Load the full record to download everything Codex retained.'));
  let title='';
  switch(item.type){
    case 'userMessage':{
      const prompt=element('div','agent-prompt');
      for(const input of item.content??[]){if(input.type==='text')prompt.append(element('div','agent-prompt-text',String(input.text??'')));else prompt.append(element('div','agent-attachment',`[${input.type==='localImage'||input.type==='image'?'Image':input.type}${input.name?': '+input.name:''}]`));}article.append(prompt);break;
    }
    case 'agentMessage':case 'plan':{
      if(Array.isArray(item.plan)){
        const done=item.plan.filter((step:AgentObject)=>step.status==='completed').length;
        article.append(header(`Updated Plan · ${done}/${item.plan.length} complete`));if(item.explanation)article.append(markdown(item.explanation));
        const rows=element('div','agent-plan');for(const step of item.plan)rows.append(element('div',`agent-plan-step ${step.status==='inProgress'?'agent-plan-current':''}`,`${step.status==='completed'?'✔':'□'} ${step.step}`));article.append(rows);
      }else{article.append(markdown(String(item.text??'')));if(item.type==='plan')article.classList.add('agent-proposed-plan');}
      break;
    }
    case 'reasoning':{
      const content=element('div');if(item.summary?.length)content.append(markdown(contentText(item.summary)));if(item.content?.length)content.append(markdown(contentText(item.content)));if(item.text)content.append(markdown(item.text));
      article.append(disclosure(`${item.id}:reasoning`,'Reasoning',content,'agent-reasoning-details'));break;
    }
    case 'exploration':{
      const members=item.members as AgentObject[],calls=members.filter(m=>m.type==='commandExecution'),active=calls.some(c=>c.status==='inProgress'),failures=calls.filter(c=>c.exitCode!=null&&c.exitCode!==0).length;
      article.append(header(`${active?'Exploring':'Explored'}${failures?` · ${failures} nonzero ${failures===1?'exit':'exits'}`:''}`,active?'running':failures?'failed':'completed'));
      const compact=element('div','agent-preview agent-exploration-preview');
      const actions=calls.flatMap(c=>(c.commandActions??[]).map((a:AgentObject)=>({a,c}))),tail=actions.slice(-3);
      if(actions.length>3)compact.append(element('div','agent-hidden-lines',`… ${actions.length-3} earlier actions`));
      for(const {a,c}of tail){const action=a.type==='read'?`Read ${a.name??a.path??'file'}`:a.type==='listFiles'?`List ${a.path??'files'}`:`Search ${a.query??a.command??''}${a.path?' in '+a.path:''}`;compact.append(element('div',c.exitCode?'agent-exploration-failed':'',`${action}${c.exitCode?` (exit ${c.exitCode})`:''}`));}
      article.append(compact);const full=element('div','agent-exploration-details');for(const member of members)full.append(renderAgentItem(member,navigate));article.append(disclosure(`${item.id}:activity`,'Show exploration',full));break;
    }
    case 'commandExecution':{
      const nonzero=item.exitCode!=null&&item.exitCode!==0,failed=nonzero||item.status==='failed'||item.status==='declined',active=item.status==='inProgress';
      title=item.status==='declined'?'Declined':nonzero?`Exited (status ${item.exitCode})`:item.status==='failed'?'Failed':active?'Running':item.source==='unifiedExecInteraction'?'Background output':'Ran';
      const fullCommand=String(item.command??''),lines=commandDisplay(fullCommand).split(/\r\n|\r|\n/);
      const h=header(title,failed?'failed':active?'running':'completed');h.classList.add('agent-command-title');
      h.append(element('code','agent-command',lines[0]+(lines.length>1?' …':'')));article.append(h);
      const output=String(item.aggregatedOutput??''),count=outputLines(output);
      if(output){const tail=element('div','agent-preview');tail.append(ansiOutputPreview(output));article.append(tail);}
      else if(!active)article.append(element('div','agent-preview','(no output)'));
      if(fullCommand||output||item.cwd||item.durationMs!=null){
        const full=element('div','agent-command-expanded');
        full.append(element('pre','agent-command-full',fullCommand));
        if(output)full.append(element('div','agent-command-output', 'Output'),ansiOutput(output));
        if(item.cwd||item.durationMs!=null){const text=[item.cwd,item.durationMs!=null?formatDuration(item.durationMs):null].filter(Boolean).join(' · ');full.append(element('div','agent-operation-meta',text));}
        article.append(disclosure(`${item.id}:output`,count>3?`${count-3} more lines · Show details`:'Show details',full,'agent-disclosure agent-command-details'));
      }break;
    }
    case 'fileChange':{
      const changes=item.changes??[],diffs=changes.map((f:AgentObject)=>String(f.diff??''));let added=0,removed=0;
      for(const diff of diffs)for(const line of diff.split('\n')){if(line.startsWith('+')&&!line.startsWith('+++'))added++;if(line.startsWith('-')&&!line.startsWith('---'))removed++;}
      const active=item.status==='inProgress',failed=item.status==='failed'||item.status==='declined';
      article.append(header(item.status==='declined'?'Patch declined':item.status==='failed'?'Failed to apply patch':changes.length?`${active?'Editing':'Edited'} ${changes.length} ${changes.length===1?'file':'files'} (+${added} -${removed})`:'Updated changes',failed?'failed':active?'running':'completed'));
      for(const file of changes){
        const content=element('div');addDiff(content,file.diff??json(file));const detail=disclosure(`${item.id}:file:${file.path}`,file.path??'File',content,'agent-file');
        const compact=element('div','agent-diff-preview');const fullDiff=content.querySelector('.agent-diff');
        if(fullDiff){const rows=[...fullDiff.children].filter(row=>row.classList.contains('agent-diff-add')||row.classList.contains('agent-diff-remove'));for(const row of rows.slice(0,3))compact.append(row.cloneNode(true));if(rows.length>3)compact.append(element('div','agent-hidden-lines',`… ${rows.length-3} more changed lines`));}
        const group=element('div','agent-file-group');group.append(detail,compact);article.append(group);
      }
      if(item.diff){const content=element('div');addDiff(content,item.diff);article.append(disclosure(`${item.id}:diff`,'Show diff',content));}
      if(item.turnDiff){const content=element('div');addDiff(content,item.turnDiff);article.append(disclosure(`${item.id}:turn-diff`,'Full turn diff',content));}
      if(item.text)article.append(preview(item.text,item.id));break;
    }
    case 'mcpToolCall':case 'dynamicToolCall':case 'functionCallOutput':{
      const active=item.status==='inProgress',failed=item.status==='failed'||item.success===false||!!item.error;
      const name=[item.server??item.namespace,item.tool??item.name].filter(Boolean).join('.');
      const label=typeof item.arguments?.title==='string'?item.arguments.title:name||'tool';
      article.append(header(`${active?'Calling':failed?'Failed':'Called'} ${label}`,active?'running':failed?'failed':'completed'));
      const text=contentText(item.contentItems??item.result??item.error??item.output);
      if(text)article.append(preview(text,item.id));else if(!active)article.append(element('div','agent-preview','No output'));
      if(item.durationMs!=null)article.append(element('div','agent-operation-meta',formatDuration(item.durationMs)));contentImages(article,item);break;
    }
    case 'collabAgentToolCall':case 'subAgentActivity':{
      const active=item.status==='inProgress',verbs:Record<string,string>={spawnAgent:active?'Spawning':'Spawned',sendInput:'Sent input to',sendMessage:'Sent message to',followupTask:'Continued',resumeAgent:'Resumed',wait:active?'Waiting for':'Finished waiting for',closeAgent:'Closed',interruptAgent:'Interrupted',listAgents:'Listed agents'};
      title=verbs[item.tool??item.kind]??'Agent activity';const h=header(title,active?'running':item.status==='failed'?'failed':'completed');
      const ids=item.receiverThreadIds??(item.agentThreadId?[item.agentThreadId]:[]);for(const id of ids)h.append(agentButton(id,item,navigate));article.append(h);
      if(item.model)article.append(element('div','agent-operation-meta',[item.model,item.reasoningEffort].filter(Boolean).join(' ')));
      if(item.prompt)article.append(preview(item.prompt,item.id));
      for(const id of ids){const state=item.agentsStates?.[id];if(state)article.append(element('div','agent-preview',`${agentLabel(id,item)}: ${state.status}${state.message?' — '+state.message:''}`));}break;
    }
    case 'webSearch':{
      const action=item.action??{};title=action.type==='open_page'?'Opened':action.type==='find_in_page'?'Found in page':'Searched';article.append(header(title));const text=action.url??action.query??action.queries?.join('\n')??item.query??'';article.append(element('div','agent-preview',text));if(item.results?.length)article.append(preview(contentText(item.results),item.id));break;
    }
    case 'turnCompletion':{
      const line=element('div','agent-completion');if(typeof item.durationMs==='number')line.append(document.createTextNode(`Worked for ${formatDuration(item.durationMs)}`));
      if(typeof item.completedAt==='number'){const date=new Date(item.completedAt*1000);if(!Number.isNaN(date.getTime())){if(line.textContent)line.append(document.createTextNode(' · '));const time=element('time','',date.toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}));time.dateTime=date.toISOString();line.append(time);}}article.append(line);return article;
    }
    case 'turnOutcome':article.append(header(`Turn ${item.status}`,'failed'));if(item.error?.message)article.append(element('p','agent-preview',item.error.message));break;
    case 'imageView':article.append(header('Viewed image'),element('div','agent-preview',item.path??'Image'));break;
    case 'imageGeneration':article.append(header('Generated image'),element('div','agent-preview',item.savedPath??item.prompt??''));break;
    case 'sleep':article.append(header('Waiting'),element('div','agent-preview',item.reason??''));break;
    case 'enteredReviewMode':case 'exitedReviewMode':article.append(header(item.type==='enteredReviewMode'?'Review started':'Review finished'));if(item.review)article.append(markdown(item.review));break;
    case 'contextCompaction':article.append(header('Context compacted'));break;
    case 'hookPrompt':article.append(header('Hook'));for(const fragment of item.fragments??[])article.append(markdown(fragment?.type==='text'&&typeof fragment.text==='string'?fragment.text:contentText(fragment)));break;
    default:article.append(header(item.type??'Event'));if(item.text)article.append(markdown(String(item.text)));if(item.path)article.append(element('div','agent-path',item.path));
  }
  const heading=article.querySelector<HTMLElement>(':scope > .agent-item-title');
  if(heading)heading.prepend(item.type==='commandExecution'||item.type==='exploration'?element('span','agent-activity-dot','•'):activityIcon(item.type));
  heading?.querySelector('.agent-activity-dot')?.setAttribute('aria-hidden','true');
  article.append(record(item));return article;
}

/** Local outline glyphs: decoration only; the activity label carries the accessible meaning. */
function activityIcon(type:string):SVGSVGElement{
  const paths:Record<string,string>={
    commandExecution:'m5 7 4 5-4 5m6 0h8',
    exploration:'m21 21-5-5m2-6a7 7 0 1 1-14 0 7 7 0 0 1 14 0',
    plan:'m4 6 1 1 2-2m3 1h10M4 12l1 1 2-2m3 1h10M4 18l1 1 2-2m3 1h10',
    fileChange:'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Zm0 0v6h6M8 13h8m-8 4h6',
    webSearch:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M3 12h18M12 3a18 18 0 0 1 0 18 18 18 0 0 1 0-18',
    collabAgentToolCall:'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2m20 0v-2a4 4 0 0 0-3-3.87M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8m8-7.87a4 4 0 0 1 0 7.75',
    imageView:'M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1m-1 13 5-5 4 4 4-4 5 5M8 7h.01',
    sleep:'M12 8v4l3 2m6-2a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
    contextCompaction:'m8 3 4 4 4-4M12 7V1m-4 20 4-4 4 4m-4-4v6M4 10h16M4 14h16',
    turnOutcome:'M12 8v5m0 4h.01M10 3 2 18a2 2 0 0 0 2 3h16a2 2 0 0 0 2-3L14 3a2 2 0 0 0-4 0',
  };
  const aliases:Record<string,string>={subAgentActivity:'collabAgentToolCall',imageGeneration:'imageView',enteredReviewMode:'fileChange',exitedReviewMode:'fileChange'};
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
  svg.setAttribute('class','agent-activity-icon');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('fill','none');svg.setAttribute('stroke','currentColor');svg.setAttribute('stroke-width','1.5');svg.setAttribute('stroke-linecap','round');svg.setAttribute('stroke-linejoin','round');svg.setAttribute('aria-hidden','true');
  const path=document.createElementNS(svg.namespaceURI,'path');path.setAttribute('d',paths[aliases[type]??type]??'m8 8-4 4 4 4m8-8 4 4-4 4m-3-12-2 16');svg.append(path);return svg;
}
