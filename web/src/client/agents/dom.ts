export function element<K extends keyof HTMLElementTagNameMap>(tag:K,className='',text=''):HTMLElementTagNameMap[K]{
  const node=document.createElement(tag);node.className=className;if(text)node.textContent=text;return node;
}
export function safeLink(value:string):string|null{
  try{const u=new URL(value);return ['https:','http:','mailto:'].includes(u.protocol)?u.href:null;}catch{return null;}
}
export function json(value:unknown):string{try{return JSON.stringify(value,null,2)??'';}catch{return String(value);}}
