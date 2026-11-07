export function readRelease(path?:string):{channel:'staging'|'public';build:number;version:string;revision:string;published:boolean};
export function releaseChannel(value?:string):'staging'|'public';
export function validateManifest(value:unknown,channel:string):unknown;
