import{it,expect}from'vitest';
import{AgentScrollInset}from'../src/client/agents/scroll-inset';
it('coalesces nested control changes into one viewport correction with the original height',()=>{
 const conversation=document.createElement('div'),scroll=document.createElement('div'),footer=document.createElement('div');conversation.append(scroll,footer);document.body.append(conversation);
 let footerHeight=100;Object.defineProperty(scroll,'clientHeight',{value:800});scroll.getClientRects=()=>[new DOMRect()] as unknown as DOMRectList;
 conversation.getBoundingClientRect=()=>({bottom:800} as DOMRect);footer.getBoundingClientRect=()=>({top:800-footerHeight} as DOMRect);
 const previous:(number|undefined)[]=[];const inset=new AgentScrollInset(scroll,footer,(change,height)=>{previous.push(height);change();});
 try{
  inset.resizeViewport(()=>{});previous.length=0;
  inset.resizeViewport(()=>{footerHeight=150;inset.resizeViewport(()=>{footerHeight=200;});});
  expect(previous).toEqual([700]);expect(inset.height).toBe(200);expect(conversation.style.getPropertyValue('--agent-footer-height')).toBe('200px');
 }finally{inset.dispose();conversation.remove();}
});
