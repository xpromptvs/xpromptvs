import { invalidateFontMetrics } from '../shared-font-metrics';
import { clientFontFaces } from "./styles";
// This registry shares immutable font assets, never session state or a current client.
const documents = new WeakMap<Document, {users: number; faces: FontFace[]; ready: Promise<void>}>();
export function acquireClientFonts(document: Document) {
  if (!document.fonts || typeof FontFace === "undefined") return {ready:Promise.resolve(),release(){}};
  let entry=documents.get(document);
  if(!entry) {
    invalidateFontMetrics(document);
    const faces=clientFontFaces.map(f=>new FontFace(f.family,f.source,f.descriptors));
    for(const face of faces)document.fonts.add(face);
    entry={users:0,faces,ready:Promise.all(faces.map(f=>f.load())).then(()=>{})};
    // Every surface observes its own failure and may keep rendering using its fallback fonts.
    void entry.ready.catch(()=>{});
    documents.set(document,entry);
  }
  const owned=entry;owned.users++;
  let released=false;
  return {ready:owned.ready,release(){if(released)return;released=true;if(--owned.users===0){invalidateFontMetrics(document);for(const face of owned.faces)document.fonts.delete(face);documents.delete(document);}}};
}
