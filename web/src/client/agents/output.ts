import {element} from './dom';
const colors=['black','red','green','yellow','blue','magenta','cyan','white'];
type Segment={text:string;classes:string};
/** Linear scanner: unterminated OSC/DCS consumes its tail once, never repeatedly searches it. */
function segments(text:string):Segment[]{
  const chunks:Segment[]=[];let foreground='',bold=false,dim=false,start=0,i=0;
  const append=(end:number)=>{const value=text.slice(start,end).replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g,'');if(value)chunks.push({text:value,classes:[foreground,bold?'ansi-bold':'',dim?'ansi-dim':''].filter(Boolean).join(' ')});};
  while(i<text.length){
    const c=text.charCodeAt(i);if(c!==27&&c!==155){i++;continue;}
    append(i);const next=text[i+1];
    if(c===155||next==='['){
      const parameters=i+(c===155?1:2);i=parameters;while(i<text.length&&(text.charCodeAt(i)<64||text.charCodeAt(i)>126))i++;
      if(c===27&&text[i]==='m'){
        const raw=text.slice(parameters,i);if(/^[\d;]*$/.test(raw)){
          const codes=raw.split(';').map(n=>Number(n)||0);
          for(let k=0;k<codes.length;k++){const n=codes[k]!;
            if(n===0){foreground='';bold=false;dim=false;}else if(n===1)bold=true;else if(n===2)dim=true;else if(n===22){bold=false;dim=false;}else if(n===39)foreground='';else if(n>=30&&n<=37)foreground='ansi-'+colors[n-30];else if(n>=90&&n<=97)foreground='ansi-'+colors[n-90];else if(n===38||n===48)k+=codes[k+1]===2?4:codes[k+1]===5?2:0;
          }
        }
      }i=Math.min(text.length,i+1);
    }else if(next&&']PX^_'.includes(next)){
      const osc=next===']';i+=2;while(i<text.length){if(osc&&text.charCodeAt(i)===7){i++;break;}if(text.charCodeAt(i)===27&&text[i+1]==='\\'){i+=2;break;}i++;}
    }else i=Math.min(text.length,i+2);
    start=i;
  }append(text.length);return chunks;
}
export function ansiOutput(text:string,lastLines?:number):HTMLElement{
  const pre=element('pre','agent-output-text'),chunks=segments(text);
  const total=chunks.reduce((count,chunk)=>count+(chunk.text.match(/\n/g)?.length??0),1)-(chunks.at(-1)?.text.endsWith('\n')?1:0);
  const first=lastLines==null?0:Math.max(0,total-lastLines);let line=0;
  for(const chunk of chunks){const rows=chunk.text.split('\n');for(let i=0;i<rows.length;i++){
    if(i){if(line>=first)pre.append(document.createTextNode('\n'));line++;}if(line<first||!rows[i])continue;
    if(chunk.classes)pre.append(element('span',chunk.classes,rows[i]));else pre.append(document.createTextNode(rows[i]!));
  }}return pre;
}
export function outputLines(text:string):number{const chunks=segments(text);return chunks.reduce((count,chunk)=>count+(chunk.text.match(/\n/g)?.length??0),1)-(chunks.at(-1)?.text.endsWith('\n')?1:0);}

/** Compact, ANSI-safe head rows. Long logical lines are ellipsized by CSS, never wrap the card. */
export function ansiOutputPreview(text:string,limit=3):HTMLElement{
 const box=element('div','agent-output-preview'),count=Math.min(limit,outputLines(text));
 const rows=Array.from({length:count},()=>element('div','agent-output-line')),used=rows.map(()=>0);box.append(...rows);
 let line=0;
 for(const chunk of segments(text)){
  const parts=chunk.text.split('\n');
  for(let i=0;i<parts.length&&line<count;i++){
   const available=16384-used[line]!,value=parts[i]!;
   if(available>0&&value){
    let head=value.slice(0,available);if(/[\uD800-\uDBFF]$/.test(head))head=head.slice(0,-1);
    const shown=head+(head.length<value.length?'…':'');used[line]!+=value.length;
    rows[line]!.append(chunk.classes?element('span',chunk.classes,shown):document.createTextNode(shown));
   }
   if(i<parts.length-1)line++;
  }
  if(line>=count)break;
 }return box;
}
