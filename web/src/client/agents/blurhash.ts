import {decode,isBlurhashValid} from 'blurhash';
const alphabet='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~';
export function blurhashPixels(hash:unknown):Uint8ClampedArray|null{
 if(typeof hash!=='string'||hash.length>166||![...hash].every(c=>alphabet.includes(c))||!isBlurhashValid(hash).result)return null;
 try{return decode(hash,32,32);}catch{return null;}
}
export function blurhashCanvas(document:Document,hash:unknown):HTMLCanvasElement|null{
 const pixels=blurhashPixels(hash);if(!pixels)return null;
 const canvas=document.createElement('canvas');canvas.width=32;canvas.height=32;canvas.className='agent-image-blurhash';canvas.setAttribute('aria-hidden','true');
 const context=canvas.getContext('2d');if(!context)return null;
 const bitmap=context.createImageData(32,32);bitmap.data.set(pixels);context.putImageData(bitmap,0,0);return canvas;
}
