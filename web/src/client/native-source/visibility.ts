import type {SourceWindowKey} from './types';
/** A complete owned-window snapshot, not a merge: a retired incarnation cannot keep media awake.
 * The host retains its existing hidden grace. Terminal pause remains main-document-local. */
export function nativeMediaHidden(ownerVisible:boolean, children:readonly {key:SourceWindowKey;visible:boolean;minimized:boolean}[]):boolean {
  return !ownerVisible&&!children.some(child=>child.visible&&!child.minimized);
}
