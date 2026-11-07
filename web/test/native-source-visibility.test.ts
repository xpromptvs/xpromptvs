import {describe,expect,it} from 'vitest';
import {nativeMediaHidden} from '../src/client/native-source/visibility';
const key={owner:1,generation:1,source:'win:1',incarnation:1};
describe('native media visibility',()=>{
  it('keeps media active with owner minimized and a visible child',()=>{
    expect(nativeMediaHidden(false,[{key,visible:true,minimized:false}])).toBe(false);
  });
  it('allows hidden grace only when owner and all current children are hidden or minimized',()=>{
    expect(nativeMediaHidden(false,[{key,visible:true,minimized:true}])).toBe(true);
    expect(nativeMediaHidden(false,[{key,visible:false,minimized:false}])).toBe(true);
    expect(nativeMediaHidden(true,[])).toBe(false);
  });
  it('a complete empty/replaced snapshot drops old visible children',()=>{
    const old=[{key,visible:true,minimized:false}];expect(nativeMediaHidden(false,old)).toBe(false);
    expect(nativeMediaHidden(false,[])).toBe(true);
    expect(nativeMediaHidden(false,[{key:{...key,incarnation:2},visible:false,minimized:false}])).toBe(true);
  });
});
