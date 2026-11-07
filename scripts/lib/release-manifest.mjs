import {readFileSync} from 'node:fs';
export function releaseChannel(value='public') { if(!['staging','public'].includes(value))throw Error('Channel must be staging or public');return value; }
export function readRelease(path=process.env.RDEV_RELEASE_RECORD) {
 const r=path?JSON.parse(readFileSync(path,'utf8')):{channel:releaseChannel(process.env.RDEV_RELEASE_CHANNEL),build:1,version:'0.2.0-source',revision:'source',published:false};
 releaseChannel(r.channel);
 if(!Number.isSafeInteger(r.build)||r.build<1||typeof r.version!=='string'||!r.version||r.version.length>64||typeof r.revision!=='string'||!r.revision||r.revision.length>128||typeof r.published!=='boolean')throw Error('Invalid release identity');
 return {channel:r.channel,build:r.build,version:r.version,revision:r.revision,published:r.published};
}
export function validateManifest(r,channel){
 releaseChannel(channel);
 const origin=channel==='public'?'https://app.xpromptvs.ai':'https://staging.xpromptvs.ai';
 if(r.channel!==channel||!Number.isSafeInteger(r.build)||r.build<1||!r.published||r.artifactURL!==`https://github.com/xpromptvs/xpromptvs/releases/download/${channel}-${r.build}/Xpromptvs.dmg`||!Number.isSafeInteger(r.size)||r.size<1||r.size>2*1024**3||!/^[a-f0-9]{64}$/.test(r.sha256))throw Error('Invalid release manifest');
 return r;
}
