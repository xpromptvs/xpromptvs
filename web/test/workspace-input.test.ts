// @vitest-environment jsdom
import { expect, it, vi } from 'vitest';
import { attachWorkspaceInput } from '../src/client/workspace-input';
it('leaves trusted gap events on their original path, intercepts remote presses and latches drag ownership',()=>{
 const root=document.createElement('div'),term=document.createElement('button');root.append(term);document.body.append(root);
 const messages:any[]=[];let hit:boolean|null=false;const local=vi.fn();term.addEventListener('pointerdown',local);
 const handle=attachWorkspaceInput(root,{hit:()=>hit,point:()=>({x:.4,y:.3}),active:()=>true,focused:()=>true,focus:()=>{},send:m=>messages.push(m),drawScale:()=>1,rect:()=>({left:0,top:0,width:100,height:100}),accepts:()=>true});
 const fire=(type:string)=>{const e=new MouseEvent(type,{bubbles:true,cancelable:true});Object.defineProperties(e,{pointerId:{value:1},pointerType:{value:'mouse'}});term.dispatchEvent(e);return e;};
 fire('pointerdown');expect(local).toHaveBeenCalledTimes(1);hit=true;fire('pointermove');fire('pointerup');expect(messages).toHaveLength(0);
 fire('pointerdown');hit=false;fire('pointermove');fire('pointerup');expect(messages.map(m=>m.phase)).toEqual(['down','move','up']);expect(local).toHaveBeenCalledTimes(1);
 hit=null;expect(fire('pointerdown').defaultPrevented).toBe(true);fire('pointerup');expect(messages).toHaveLength(3);handle.dispose();root.remove();
});
it('always releases a sent press when the driver loses control',()=>{
 const root=document.createElement('div');let active=true;const messages:any[]=[];
 const h=attachWorkspaceInput(root,{hit:()=>true,point:()=>({x:0,y:0}),active:()=>active,focused:()=>true,focus:()=>{},send:m=>messages.push(m),drawScale:()=>1,rect:()=>({left:0,top:0,width:1,height:1}),accepts:()=>true});
 const e=new MouseEvent('pointerdown',{bubbles:true});Object.defineProperties(e,{pointerId:{value:1},pointerType:{value:'mouse'}});root.dispatchEvent(e);active=false;h.cancelGesture();h.dispose();expect(messages.map(m=>m.phase)).toEqual(['down','up']);
});
