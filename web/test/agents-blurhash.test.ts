import {it,expect} from 'vitest';
import {blurhashPixels} from '../src/client/agents/blurhash';
it('decodes standard BlurHash and rejects missing or malformed metadata',()=>{
 const pixels=blurhashPixels('K~TI:j|cfQ|c$5fQfQfQfQ');expect(pixels).toHaveLength(32*32*4);
 expect([...pixels!.slice(0,4)]).toEqual([255,0,0,255]);
 for(const value of [undefined,'','broken','!'.repeat(22),'A'.repeat(1000)])expect(blurhashPixels(value)).toBeNull();
});
