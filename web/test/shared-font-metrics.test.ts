import {expect,it,vi} from 'vitest';
import {shareGlyphMeasurements,invalidateFontMetrics,fontMetricsStats} from '../src/client/shared-font-metrics';
const cache=()=>({_font:'Mono',_fontSize:14,_weight:'normal',_weightBold:'bold',_measure:vi.fn((_text:string,_variant:number)=>8)});
it('shares identical measurements while separating size, variant, family, and document',()=>{
 invalidateFontMetrics(document);
 const a=cache(),b=cache(),original=b._measure;shareGlyphMeasurements(a,document);const stop=shareGlyphMeasurements(b,document);
 expect(a._measure('W',0)).toBe(8);expect(b._measure('W',0)).toBe(8);expect(original).not.toHaveBeenCalled();
 b._measure('W',1);b._fontSize=16;b._measure('W',0);b._font='Other';b._measure('W',0);expect(original).toHaveBeenCalledTimes(3);
 const c=cache(),other=c._measure;shareGlyphMeasurements(c,document.implementation.createHTMLDocument());c._measure('W',0);expect(other).toHaveBeenCalledOnce();
 invalidateFontMetrics(document);a._measure('W',0);expect(fontMetricsStats(document).size).toBe(1);
 stop();expect(b._measure).toBe(original);
});
it('bounds retained measurements and refuses invalid widths',()=>{
 invalidateFontMetrics(document);const a=cache();shareGlyphMeasurements(a,document);
 for(let i=0;i<4200;i++)a._measure(String(i),0);
 expect(fontMetricsStats(document).size).toBe(4096);
 const b={...cache(),_measure:vi.fn((_text:string,_variant:number)=>0)};shareGlyphMeasurements(b,document);b._measure('invalid',0);b._measure('invalid',0);
 expect(fontMetricsStats(document).size).toBe(4096);
});
it('invalidates on font loading and bypasses measurements during loading',()=>{
 const fonts=new EventTarget();Object.assign(fonts,{status:'loaded'});
 const doc={fonts,defaultView:{devicePixelRatio:1}} as unknown as Document;
 const a=cache(),measure=a._measure;shareGlyphMeasurements(a,doc);a._measure('x',0);a._measure('x',0);expect(measure).toHaveBeenCalledOnce();
 Object.assign(fonts,{status:'loading'});fonts.dispatchEvent(new Event('loading'));a._measure('x',0);a._measure('x',0);expect(measure).toHaveBeenCalledTimes(3);
 Object.assign(fonts,{status:'loaded'});fonts.dispatchEvent(new Event('loadingdone'));a._measure('x',0);expect(measure).toHaveBeenCalledTimes(4);
});
