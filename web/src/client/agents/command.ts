/** Display-only argv decoding. Unwrap exactly shell -c SCRIPT, never a compound command. */
export function commandDisplay(command:string):string{
 const words:string[]=[];let word='',quote='',started=false;
 for(let i=0;i<command.length;i++){
  const c=command[i]!;
  if(quote==="'"){if(c==="'")quote='';else word+=c;continue;}
  if(quote==='"'){
   if(c==='"'){quote='';continue;}
   if(c==='$'||c==='`')return command;
   if(c==='\\'&&i+1<command.length&&'$`"\\\n'.includes(command[i+1]!)){const next=command[++i]!;if(next!=='\n')word+=next;}
   else word+=c;continue;
  }
  if(/\s/.test(c)){if(started){words.push(word);word='';started=false;}continue;}
  if(c==="'"||c==='"'){quote=c;started=true;continue;}
  if(c==='\\'){if(i+1===command.length)return command;const next=command[++i]!;if(next!=='\n'){word+=next;started=true;}continue;}
  if(';|&<>()`$#'.includes(c))return command;
  word+=c;started=true;
 }
 if(quote)return command;if(started)words.push(word);
 return words.length===3&&['bash','zsh','sh'].includes(words[0]!.split('/').at(-1)!)&&['-c','-lc','-cl'].includes(words[1]!)?words[2]!:command;
}
