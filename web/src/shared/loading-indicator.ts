import './loading-indicator.css';
import logo from '../../public/favicon.svg?raw';

let mask:string|undefined;
let artworkReady:Promise<void>=Promise.resolve();
export const loadingIndicatorReady=()=>artworkReady;
/** Use the actual logo geometry without its app-icon background. */
export function createLoadingIndicator(){
 if(!mask){
  const source=new DOMParser().parseFromString(logo,'image/svg+xml');
  const chevrons=source.querySelector('#chevron-pair')!;chevrons.removeAttribute('transform');
  for(const path of chevrons.querySelectorAll('path'))path.setAttribute('fill','white');
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
  svg.setAttribute('viewBox','-80 0 820 600');svg.setAttribute('width','64');svg.setAttribute('height','48');svg.append(chevrons);
  const url=`data:image/svg+xml,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`;
  mask=`url("${url}")`;
  // Warm the SVG at the exact rendered size before an entrance fade can begin.
  const image=new Image();image.src=url;
  artworkReady=image.decode().catch(()=>{});
 }
 const mark=document.createElement('div');mark.className='loading-indicator';mark.setAttribute('aria-hidden','true');
 mark.style.maskImage=mask;mark.style.webkitMaskImage=mask;
 return mark;
}
