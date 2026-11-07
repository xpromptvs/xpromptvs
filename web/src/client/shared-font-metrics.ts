/** xterm 6.0.0 DOM WidthCache adapter. Share only measured widths, never renderer state.
 * The private shape is guarded; an incompatible renderer keeps its original measurements.
 */
export interface GlyphMeasurements {
 _font: string; _fontSize: number; _weight: string | number; _weightBold: string | number;
 _measure(text: string, variant: number): number;
}
const LIMIT=4096;
interface Metrics { widths:Map<string,number>; hits:number; misses:number; }
const documents=new WeakMap<Document,Metrics>();
function metrics(document:Document):Metrics {
 let entry=documents.get(document);
 if(!entry){
  entry={widths:new Map(),hits:0,misses:0};documents.set(document,entry);
  const clear=()=>entry!.widths.clear();
  document.fonts?.addEventListener('loading',clear);
  document.fonts?.addEventListener('loadingdone',clear);
  document.fonts?.addEventListener('loadingerror',clear);
 }
 return entry;
}
export function invalidateFontMetrics(document:Document):void {documents.get(document)?.widths.clear();}
export function fontMetricsStats(document:Document) {
 const entry=documents.get(document);return {hits:entry?.hits??0,misses:entry?.misses??0,size:entry?.widths.size??0};
}
export function shareGlyphMeasurements(candidate:unknown,document:Document):()=>void {
 const cache=candidate as GlyphMeasurements|undefined;
 if(!cache||typeof cache._measure!=='function'||typeof cache._font!=='string'||typeof cache._fontSize!=='number'
  ||!['string','number'].includes(typeof cache._weight)||!['string','number'].includes(typeof cache._weightBold))return ()=>{};
 const entry=metrics(document),original=cache._measure;
 const measure=function(this:GlyphMeasurements,text:string,variant:number){
  // A fallback font's widths must never populate a cache used after web fonts arrive.
  if(document.fonts?.status==='loading'||!this._fontSize||text.length>256)return original.call(this,text,variant);
  const key=JSON.stringify([this._font,this._fontSize,this._weight,this._weightBold,variant,document.defaultView?.devicePixelRatio??1,text]);
  const cached=entry.widths.get(key);
  if(cached!==undefined){entry.hits++;return cached;}
  entry.misses++;
  const width=original.call(this,text,variant);
  if(Number.isFinite(width)&&width>0){
   if(entry.widths.size>=LIMIT)entry.widths.delete(entry.widths.keys().next().value!);
   entry.widths.set(key,width);
  }
  return width;
 };
 cache._measure=measure;
 return ()=>{if(cache._measure===measure)cache._measure=original;};
}
