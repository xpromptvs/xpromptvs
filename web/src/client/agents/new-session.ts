import {openClientDialog,closeClientDialog} from '../instance/overlays';
import {element} from './dom';
export function newClaudeSession(parent:HTMLElement,create:(cwd:string)=>Promise<void>):HTMLDialogElement {
 const dialog=element('dialog','ss-dialog agent-new-dialog') as HTMLDialogElement;dialog.setAttribute('aria-label','New Claude session');
 const title=element('h2','','New Claude session'),description=element('p','','Choose a project directory on the host Mac.'),form=element('form');
 const label=element('label','','Project directory'),input=element('input') as HTMLInputElement;input.placeholder='/path/to/project';input.setAttribute('aria-label','Project directory on host');input.autocomplete='off';input.required=true;label.append(input);
 const notice=element('p');notice.setAttribute('role','status');const actions=element('div','ss-dialog-actions');const cancel=element('button','','Cancel'),start=element('button','','Create session');cancel.type='button';start.type='submit';actions.append(cancel,start);form.append(label,notice,actions);dialog.append(title,description,form);parent.append(dialog);
 const close=()=>closeClientDialog(dialog);cancel.addEventListener('click',close);dialog.addEventListener('close',()=>queueMicrotask(()=>dialog.remove()),{once:true});
 form.addEventListener('submit',e=>{e.preventDefault();const cwd=input.value.trim();if(!cwd.startsWith('/')){notice.textContent='Enter an absolute project directory on the host';return}start.disabled=true;notice.textContent='Starting Claude on the host…';void create(cwd).then(close,error=>{notice.textContent=String(error.message??error);start.disabled=false})});
 openClientDialog(dialog);input.focus();return dialog;
}
