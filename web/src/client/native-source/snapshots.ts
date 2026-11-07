import { sameSourceWindowKey, validSourceWindowKey, type SourceWindowKey } from './types';

export interface SourceWindowEndpoint<T> { update(snapshot: T): void; dispose(): void }
interface Slot<T> { key: SourceWindowKey; latest?: T; endpoint?: SourceWindowEndpoint<T> }

/** Coalesces state, never media. A stream stays the owner's exact received reference, not a clone.
 * Readiness and track callbacks may arrive after retirement; neither can revive an old key. */
export class SourceWindowSnapshots<T extends { key: SourceWindowKey; revision: number }> {
  private readonly slots = new Map<string, Slot<T>>();
  private readonly retired = new Map<string, number>();
  constructor(private readonly owner: number, private generation: number,
              private readonly onError: (error: unknown, key?: SourceWindowKey) => void = error => console.error('[native-source]', error)) {}

  begin(key: SourceWindowKey): boolean {
    if (!validSourceWindowKey(key) || key.owner !== this.owner || key.generation !== this.generation) return false;
    const current = this.slots.get(key.source);
    if (sameSourceWindowKey(current?.key, key)) return true;
    const previous = Math.max(this.retired.get(key.source) ?? 0, current?.key.incarnation ?? 0);
    if (key.incarnation <= previous) return false;
    if (current) this.retire(current.key);
    this.slots.set(key.source, { key });
    return true;
  }
  publish(snapshot: T): boolean {
    const slot = this.slots.get(snapshot.key.source);
    if (!sameSourceWindowKey(slot?.key, snapshot.key) || !Number.isSafeInteger(snapshot.revision)
        || snapshot.revision < 0 || (slot!.latest && snapshot.revision <= slot!.latest.revision)) return false;
    slot!.latest = snapshot;
    this.deliver(slot!, snapshot);
    return true;
  }
  attach(key: SourceWindowKey, endpoint: SourceWindowEndpoint<T>): boolean {
    const slot = this.slots.get(key.source);
    if (!sameSourceWindowKey(slot?.key, key)) {
      // A misordered callback must not dispose an endpoint already attached to another current key.
      if (![...this.slots.values()].some(value => value.endpoint === endpoint)) this.dispose(endpoint);
      return false;
    }
    if (slot!.endpoint === endpoint) return true;
    if (slot!.endpoint) this.dispose(slot!.endpoint);
    slot!.endpoint = endpoint;
    if (slot!.latest) this.deliver(slot!, slot!.latest);
    return slot!.endpoint === endpoint;
  }
  current(source: string): SourceWindowKey | undefined { return this.slots.get(source)?.key; }
  endpoint(key: SourceWindowKey): SourceWindowEndpoint<T> | undefined {
    const slot = this.slots.get(key.source);
    return sameSourceWindowKey(slot?.key, key) ? slot?.endpoint : undefined;
  }
  retire(key: SourceWindowKey): void {
    const slot = this.slots.get(key.source);
    if (!sameSourceWindowKey(slot?.key, key)) return;
    // Retire before calling into a child: disposal itself may produce a final callback.
    this.slots.delete(key.source);
    this.retired.set(key.source, Math.max(this.retired.get(key.source) ?? 0, key.incarnation));
    if (slot!.endpoint) this.dispose(slot!.endpoint);
  }
  reset(generation: number): boolean {
    if (!Number.isSafeInteger(generation) || generation <= this.generation) return false;
    this.clear(); this.generation = generation; this.retired.clear();
    return true;
  }
  clear(): void { for (const slot of [...this.slots.values()]) this.retire(slot.key); }
  private deliver(slot: Slot<T>, snapshot: T): void {
    const endpoint=slot.endpoint;if(!endpoint)return;
    try { endpoint.update(snapshot); }
    catch(error) {
      if(slot.endpoint===endpoint)slot.endpoint=undefined;
      this.dispose(endpoint);
      try { this.onError(error,slot.key); } catch { /* one child never aborts sibling publication */ }
    }
  }
  private dispose(endpoint: SourceWindowEndpoint<T>): void {
    try { endpoint.dispose(); }
    catch (error) { try { this.onError(error); } catch { /* teardown continues even if a reporting callback fails */ } }
  }
}
