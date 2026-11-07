import { openClientDialog, closeClientDialog } from "./instance/overlays";
import {compareReleases,parseReleaseIdentity,positiveBuild,type ReleaseIdentity,type HostUpdateRequest} from '../../../protocol/src/host-update';
declare const __RDEV_RELEASE__: unknown;
export const clientRelease = typeof __RDEV_RELEASE__ === 'undefined' ? null : parseReleaseIdentity(__RDEV_RELEASE__);
export function createHostUpdateUI(o:{clientRelease:ReleaseIdentity|null;send:(m:HostUpdateRequest)=>void;document:Document;container?:HTMLElement}) {
 const d=o.document, dismissed=new Set<string>();
 let dialog:HTMLDialogElement|null=null, key='', seen=false, timer:ReturnType<typeof setTimeout>|undefined;
 let pending:string|null=null, target=0;
 const close=()=>{dismissed.add(key);closeClientDialog(dialog);};
 function panel(text:string,detail:string,canUpdate=false){
  if(!dialog){dialog=d.createElement('dialog');dialog.className='ss-dialog host-update-dialog';dialog.addEventListener('cancel',e=>{e.preventDefault();close();});(o.container??d.body).append(dialog);}
  dialog.replaceChildren();
  const title=d.createElement('h2');title.textContent='Host update';
  const p=d.createElement('p');p.textContent=text;
  const small=d.createElement('p');small.className='host-update-detail';small.textContent=detail;
  const buttons=d.createElement('div');buttons.className='ss-dialog-actions host-update-actions';
  if(canUpdate){const update=d.createElement('button');update.textContent='Update and Restart';update.onclick=()=>{
    pending=crypto.randomUUID();target=o.clientRelease!.build;
    panel('Checking for an update…','This Mac will restart and reconnect. Ordinary terminal processes will end.');
    o.send({t:'host-update-request',requestId:pending,minimumBuild:target});
  };buttons.append(update);}
  const cont=d.createElement('button');cont.textContent='Continue';cont.onclick=close;buttons.append(cont);
  dialog.append(title,p,small,buttons);
  if(!dialog.open&&!dismissed.has(key))openClientDialog(dialog);
 }
 function receive(value:unknown):boolean {
  if(!value||typeof value!=='object')return false;
  const m=value as Record<string,any>;
  if(m.t==='host-info'){
   seen=true;clearTimeout(timer);
   const release=parseReleaseIdentity(m.release), comparison=compareReleases(release,o.clientRelease);
   if(pending&&release&&release.channel===o.clientRelease?.channel&&release.build>=target){pending=null;panel('This host has been updated.',`Host build ${release.build}`);return true;}
   if(comparison==='equal'||comparison==='newer'){if(!pending)closeClientDialog(dialog);return true;}
   if(!o.clientRelease)return true;
   key=`${release?.channel??'unknown'}:${release?.build??'unknown'}:${o.clientRelease.channel}:${o.clientRelease.build}`;
   const u=m.update;
   const eligible=u?.supported===true&&u?.allowed===true&&u?.eligible===true&&positiveBuild(u?.availableBuild)&&u.availableBuild>=o.clientRelease.build&&comparison==='older';
   let detail=`Host ${release?.version??'unknown'} (build ${release?.build??'unknown'}); client ${o.clientRelease.version} (build ${o.clientRelease.build}). `;
   detail+=eligible?'Updating restarts this Mac’s app, disconnects clients, and ends ordinary terminal processes.':u?.allowed===false?'Remote updates are disabled on this host.':u?.supported!==true?'Update Xpromptvs manually on this Mac.':u?.eligible!==true?'Only an owner can update this host.':'The matching host release is not available yet.';
   if(!pending)panel(comparison==='channel-mismatch'?'The client and host use different release channels.':'This host is outdated. Some features may be incompatible. Update Xpromptvs on this Mac.',detail,eligible);
   return true;
  }
  if(m.t==='host-update-status'){
   if(m.requestId!==pending)return true;
   const names:Record<string,string>={checking:'Checking for an update…',downloading:'Downloading the update…',verifying:'Verifying the update…',restarting:'Restarting this host…',succeeded:'Waiting for the updated host…',failed:'The update failed.',cancelled:'The update was cancelled.','rolled-back':'The update failed. The previous version was restored.'};
   if(typeof m.phase!=='string'||!names[m.phase])return true;
   panel(names[m.phase]!,typeof m.error==='string'?m.error.slice(0,500):'The connection will recover when the host is ready.');
   if(['failed','cancelled','rolled-back'].includes(m.phase))pending=null;
   return true;
  }
  return false;
 }
 return {receive,controlReady(){if(pending)o.send({t:"host-update-request",requestId:pending,minimumBuild:target});if(!seen&&!timer&&o.clientRelease?.published)timer=setTimeout(()=>receive({t:'host-info',release:null,update:{supported:false}}),750);},dispose(){clearTimeout(timer);closeClientDialog(dialog);dialog?.remove();dialog=null;}};
}
