import {it,expect,beforeEach,afterEach,vi} from 'vitest';
import {createHostUpdateUI} from '../src/client/host-update';
const release={channel:'staging' as const,build:12,version:'0.2.0',revision:'abc',published:true};
beforeEach(()=>{vi.useFakeTimers();HTMLDialogElement.prototype.showModal=function(){this.open=true;};HTMLDialogElement.prototype.close=function(){this.open=false;};});
afterEach(()=>{document.body.innerHTML='';vi.useRealTimers();});
function setup(){const sent:unknown[]=[];const ui=createHostUpdateUI({clientRelease:release,send:m=>{sent.push(m);},document});return {ui,sent};}
function info(build:number,eligible=true,allowed=true){return {t:'host-info',release:{...release,build},update:{supported:true,eligible,allowed,availableBuild:12}};}
it('warns on older hosts and lets owners explicitly restart',()=>{
 const {ui,sent}=setup();ui.receive(info(11));expect(document.querySelector('dialog')?.open).toBe(true);
 expect(document.body.textContent).toContain('Some features may be incompatible');
 const button=[...document.querySelectorAll('button')].find(b=>b.textContent==='Update and Restart')!;button.click();
 expect(sent).toEqual([{t:'host-update-request',requestId:expect.any(String),minimumBuild:12}]);
 expect(document.body.textContent).toContain('Checking');
 ui.receive({t:'host-update-status',requestId:(sent[0] as any).requestId,phase:'restarting',targetBuild:12});
 expect(document.body.textContent).toContain('Restarting');
 ui.receive(info(12));expect(document.body.textContent).toContain('updated');ui.dispose();
});
it('never gives guests or disabled hosts an update button',()=>{
 const {ui}=setup();ui.receive(info(11,false));expect(document.body.textContent).not.toContain('Update and Restart');
 ui.receive(info(11,true,false));expect(document.body.textContent).toContain('disabled');ui.dispose();
});
it('equal and newer hosts are quiet; dismissed warnings stay quiet on reconnect',()=>{
 const {ui}=setup();ui.receive(info(12));ui.receive(info(13));expect(document.querySelector('dialog')?.open??false).toBe(false);
 ui.receive(info(11));[...document.querySelectorAll('button')].find(b=>b.textContent==='Continue')!.click();
 ui.receive(info(11));expect(document.querySelector('dialog')?.open).toBe(false);ui.dispose();
});
it('legacy hosts get manual guidance after exchange; mismatches cannot update',()=>{
 const {ui}=setup();ui.controlReady();vi.advanceTimersByTime(1000);expect(document.body.textContent).toContain('manually');
 ui.receive({...info(11),release:{...release,channel:'public'}});expect(document.body.textContent).toContain('different release channels');expect(document.body.textContent).not.toContain('Update and Restart');ui.dispose();
});
it('reconnect retries the accepted request using the same identity',()=>{
 const {ui,sent}=setup();ui.receive(info(11));[...document.querySelectorAll('button')].find(b=>b.textContent==='Update and Restart')!.click();
 ui.controlReady();expect(sent).toHaveLength(2);expect(sent[1]).toEqual(sent[0]);ui.dispose();
});
