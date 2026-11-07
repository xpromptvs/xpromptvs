import {readFileSync} from 'node:fs';
const profiles=JSON.parse(readFileSync(new URL('../../config/product-features.json',import.meta.url),'utf8'));
export function resolveProductFeatures(profile='publication') {
 if(!Object.hasOwn(profiles,profile))throw Error(`Unknown product profile: ${profile}`);
 const value=profiles[profile];
 if(typeof value.graphicalAgents!=='boolean'||typeof value.glasses!=='boolean')throw Error('Invalid product features');
 return Object.freeze({...value});
}
export function productProfile(){const profile=process.env.RDEV_PRODUCT_PROFILE??'publication';resolveProductFeatures(profile);return profile;}

export function transformProductHtml(html,features) {
 const result=html.replace('data-theme="dark"','data-theme="dark" data-glasses-enabled="'+features.glasses+'"');
 return features.glasses?result:result.replace(/<meta\s+name="mrbd-web-app-capable"[^>]*>/g,'');
}
