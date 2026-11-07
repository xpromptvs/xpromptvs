export interface ProductFeatures { readonly graphicalAgents:boolean; readonly glasses:boolean; }
export function resolveProductFeatures(profile?:string):ProductFeatures;
export function productProfile():string;
export function transformProductHtml(html:string,features:ProductFeatures):string;
