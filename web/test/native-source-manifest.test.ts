import { describe, expect, it } from 'vitest';
import { nativeSourceManifest } from '../src/client/native-source/manifest';
import type { ViewSetMsg } from '../src/client/source-picker';
const state: ViewSetMsg = { windows:[{source:'win:1',minimized:false},{source:'sim:abc',minimized:true,name:'Phone'}],subs:[],focused:'win:1',view:{surface:'windows',fullscreen:null},tabOrder:[],version:9 };
describe('native presentation membership', () => {
  it('keeps minimized sources and known names/sizes before browser windowViews filters them', () => {
    expect(nativeSourceManifest(3,4,state,[{id:'win:1',kind:'win',name:'Editor',w:800,h:600,running:true,inputCapable:true}],true,'dark',new Map())).toEqual({
      generation:3,revision:4,driving:true,focused:'win:1',theme:'dark',sources:[
        {source:'win:1',kind:'window',title:'Editor',minimized:false,width:800,height:600},
        {source:'sim:abc',kind:'simulator',title:'Phone',minimized:true},
      ],
    });
  });
  it('refuses parked applications, opaque instrument sources and invalid native IDs', () => {
    const windows=['apps:workspace','test','win:-1','win:4294967296','dsp:x'].map(source=>({source,minimized:false}));
    const manifest=nativeSourceManifest(1,1,{...state,windows},[],true,'dark',new Map());
    expect(manifest.sources).toEqual([]);expect(manifest.focused).toBe(null);
  });
  it('uses confirmed logical sizes and clears focus when the source is minimized or absent', () => {
    const manifest=nativeSourceManifest(1,2,{...state,focused:'sim:abc'},[],false,'light',new Map([['win:1',{w:400,h:300}]]));
    expect(manifest.focused).toBe(null);expect(manifest.driving).toBe(false);
    expect(manifest.sources[0]).toMatchObject({width:400,height:300});
  });
});
