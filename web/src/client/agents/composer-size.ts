/** Measure real wrapped text; CSS supplies the minimum and ten-line/viewport cap. */
export class ComposerSize {
 private observer?:ResizeObserver;
 private width=0;
 constructor(private input:HTMLTextAreaElement,private resizeViewport:(change:()=>void)=>void){
  input.addEventListener('input',this.update);
  if(typeof ResizeObserver==='function'){
   this.observer=new ResizeObserver(entries=>{
    const width=entries[0]?.contentRect.width??0;
    if(width!==this.width){this.width=width;if(width>0)this.update();}
   });
   this.observer.observe(input);
  }
 }
 update=():void=>{
  if(!this.input.getClientRects().length)return;
  this.resizeViewport(()=>{
   const top=this.input.scrollTop;
   this.input.style.height='auto';
   this.input.style.height=this.input.scrollHeight+'px';
   this.input.scrollTop=top;
  });
 };
 dispose():void{this.observer?.disconnect();this.input.removeEventListener('input',this.update);}
}
