import {readRelease} from '../scripts/lib/release-manifest.mjs';
import {resolveProductFeatures,productProfile,transformProductHtml} from '../scripts/lib/product-features.mjs';
import {fileURLToPath} from 'node:url';
import {defineConfig} from 'vite';
const release=readRelease(),features=resolveProductFeatures(productProfile());
export default defineConfig({
 base:'./',define:{__RDEV_RELEASE__:JSON.stringify(release),__RDEV_PRODUCT_FEATURES__:JSON.stringify(features)},
 plugins:[{name:'product-resources',transformIndexHtml(html){return transformProductHtml(html,features);},generateBundle(){
  for(const [fileName,value] of [['release.json',release],['product-features.json',features]] as const)this.emitFile({type:'asset',fileName,source:JSON.stringify(value)+'\n'});
 }}],
 resolve:{alias:{'@rdev/protocol':fileURLToPath(new URL('../protocol/src/index.ts',import.meta.url))}},
 build:{target:'es2022',rollupOptions:{preserveEntrySignatures:'exports-only',input:{
  nativeSourceOwner:fileURLToPath(new URL('./src/client/native-source/owner.ts',import.meta.url)),
  embed:fileURLToPath(new URL('./src/client/embed.ts',import.meta.url)),
  client:fileURLToPath(new URL('./index.html',import.meta.url)),source:fileURLToPath(new URL('./source-window.html',import.meta.url)),
 },output:{entryFileNames:chunk=>chunk.name==='embed'?'embed.js':'assets/[name]-[hash].js'}}},
 test:{environment:'jsdom'},
});
