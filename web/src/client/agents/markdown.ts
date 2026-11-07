import {Marked,type Token} from 'marked';
// Disable HTML tokenization so Markdown after a literal HTML-looking line still renders.
const tokenizer=new Marked({gfm:true,tokenizer:{html(){return undefined;},tag(){return undefined;}}});
import {element,safeLink} from './dom';
import type {AgentObject} from './protocol';

function entities(text:string):string{
  const names:Record<string,string>={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:'\u00a0'};
  return text.replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,(whole,name:string)=>{
    if(name[0]!=='#')return names[name.toLowerCase()]??whole;
    const n=name[1]?.toLowerCase()==='x'?parseInt(name.slice(2),16):parseInt(name.slice(1),10);
    return n>0&&n<=0x10ffff&&!(n>=0xd800&&n<=0xdfff)?String.fromCodePoint(n):'\ufffd';
  });
}
/** Small lexical emphasis, never interprets code as HTML. Unknown languages remain plain. */
function codeBlock(text:string,language:string):HTMLElement{
  const pre=element('pre','agent-code'),code=element('code');pre.append(code);
  code.dataset.language=language;
  if(!/^(?:js|javascript|ts|typescript|tsx|jsx|swift|rust|rs|python|py|json|sh|bash|shell|css|go|c|cpp)$/.test(language)){code.textContent=text;return pre;}
  const tokens=/(\/\/[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:const|let|var|func|fn|function|return|if|else|for|while|import|from|export|class|struct|enum|pub|async|await|try|catch|throw|true|false|null|nil|None|def|in|as)\b|\b\d+(?:\.\d+)?\b)/g;
  let at=0;for(const match of text.matchAll(tokens)){
    code.append(document.createTextNode(text.slice(at,match.index)));
    const s=match[0],kind=s.startsWith('//')||s.startsWith('#')?'comment':s.startsWith('"')||s.startsWith("'")?'string':/^\d/.test(s)?'number':'keyword';
    code.append(element('span','agent-syntax-'+kind,s));at=match.index!+s.length;
  }code.append(document.createTextNode(text.slice(at)));return pre;
}
/** Tokenize Markdown, then build allowed DOM nodes; no HTML renderer or transcript innerHTML. */
export function markdown(text:string):HTMLElement{
  const root=element('div','agent-markdown');
  function render(parent:HTMLElement,tokens:Token[],depth=0):void{
    if(depth>48){parent.append(document.createTextNode(tokens.map(t=>t.raw).join('')));return;}
    for(const value of tokens){const t=value as AgentObject;let node:HTMLElement|undefined;
      switch(t.type){
        case 'space':break;
        case 'heading':node=element(`h${Math.min(6,Math.max(1,t.depth))}` as 'h1');render(node,t.tokens,depth+1);break;
        case 'paragraph':node=element('p');render(node,t.tokens,depth+1);break;
        case 'text':if(t.tokens){render(parent,t.tokens,depth+1);}else parent.append(document.createTextNode(entities(t.text)));break;
        case 'escape':parent.append(document.createTextNode(entities(t.text)));break;
        case 'strong':case 'em':case 'del':node=element(t.type==='strong'?'strong':t.type==='em'?'em':'del');render(node,t.tokens,depth+1);break;
        case 'codespan':node=element('code','',entities(t.text));break;
        case 'code':node=codeBlock(t.text,String(t.lang??'').split(/\s/)[0]!.toLowerCase());break;
        case 'br':node=element('br');break;
        case 'hr':node=element('hr');break;
        case 'blockquote':node=element('blockquote');render(node,t.tokens,depth+1);break;
        case 'list':{
          node=element(t.ordered?'ol':'ul');if(t.ordered&&typeof t.start==='number')(node as HTMLOListElement).start=t.start;
          for(const entry of t.items){const li=element('li');if(entry.task)li.append(element('span','agent-task',entry.checked?'✔ ':'□ '));render(li,entry.tokens,depth+1);node.append(li);}break;
        }
        case 'link':{
          const href=safeLink(entities(t.href));if(href){const a=element('a');a.href=href;a.target='_blank';a.rel='noopener noreferrer';if(t.title)a.title=t.title;render(a,t.tokens,depth+1);node=a;}else render(parent,t.tokens,depth+1);break;
        }
        // Remote images are not fetched just by displaying a transcript. Host images use scoped assets.
        case 'image':node=element('span','agent-attachment',`[Image${t.text?': '+entities(t.text):''}]`);break;
        case 'table':{
          node=element('div','agent-table-scroll');const table=element('table'),thead=element('thead'),head=element('tr'),body=element('tbody');
          t.header.forEach((cell:AgentObject,i:number)=>{const th=element('th');if(t.align[i])th.style.textAlign=t.align[i];render(th,cell.tokens,depth+1);head.append(th);});thead.append(head);
          for(const row of t.rows){const tr=element('tr');row.forEach((cell:AgentObject,i:number)=>{const td=element('td');if(t.align[i])td.style.textAlign=t.align[i];render(td,cell.tokens,depth+1);tr.append(td);});body.append(tr);}table.append(thead,body);node.append(table);break;
        }
        case 'html':parent.append(document.createTextNode(t.raw));break;
        default:parent.append(document.createTextNode(t.raw??t.text??''));
      }if(node)parent.append(node);
    }
  }
  try{render(root,tokenizer.lexer(text));}catch{root.textContent=text;}
  return root;
}
