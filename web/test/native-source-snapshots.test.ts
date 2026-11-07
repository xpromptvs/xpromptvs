import { describe, expect, it } from 'vitest';
import { SourceWindowSnapshots } from '../src/client/native-source/snapshots';
import type { SourceWindowKey } from '../src/client/native-source/types';

type Snapshot = { key: SourceWindowKey; revision: number; stream: object | null };
const key = (source = 'win:11', incarnation = 1, generation = 2, owner = 7): SourceWindowKey => ({ owner, generation, source, incarnation });
const endpoint = (events: unknown[] = []) => ({ update(value: Snapshot) { events.push(value); }, dispose() { events.push('dispose'); } });

describe('native source snapshot ownership', () => {
  it('retains only the newest snapshot until a child is ready, preserving the exact stream reference', () => {
    const store = new SourceWindowSnapshots<Snapshot>(7, 2), k = key(), first = {}, stream = {};
    expect(store.begin(k)).toBe(true);
    expect(store.publish({ key: k, revision: 1, stream: first })).toBe(true);
    expect(store.publish({ key: k, revision: 3, stream })).toBe(true);
    expect(store.publish({ key: k, revision: 2, stream: first })).toBe(false);
    const events: unknown[] = [], view = endpoint(events);
    expect(store.attach(k, view)).toBe(true);
    expect(events).toHaveLength(1);
    expect((events[0] as Snapshot).stream).toBe(stream);
    expect(store.attach(k, view)).toBe(true);
    expect(events).toHaveLength(1);
  });

  it('rejects old/equal revisions after readiness and delivers later track replacement once', () => {
    const store = new SourceWindowSnapshots<Snapshot>(7, 2), k = key(), events: unknown[] = [];
    store.begin(k); store.attach(k, endpoint(events));
    const a = { key: k, revision: 2, stream: {} }, b = { key: k, revision: 3, stream: {} };
    expect(store.publish(a)).toBe(true);
    expect(store.publish({ ...a, stream: {} })).toBe(false);
    expect(store.publish({ ...a, revision: 1 })).toBe(false);
    expect(store.publish(b)).toBe(true);
    expect(events).toEqual([a, b]);
  });

  it('cannot revive a retired incarnation or attach a late old child over its replacement', () => {
    const store = new SourceWindowSnapshots<Snapshot>(7, 2), old = key(), next = key('win:11', 2);
    const oldEvents: unknown[] = [], nextEvents: unknown[] = [], lateEvents: unknown[] = [];
    store.begin(old); store.attach(old, endpoint(oldEvents)); store.retire(old);
    expect(store.begin(old)).toBe(false);
    expect(store.begin(next)).toBe(true);
    store.publish({ key: next, revision: 1, stream: {} }); store.attach(next, endpoint(nextEvents));
    expect(store.attach(old, endpoint(lateEvents))).toBe(false);
    expect(lateEvents).toEqual(['dispose']);
    expect(oldEvents).toEqual(['dispose']);
    expect(store.publish({ key: old, revision: 100, stream: {} })).toBe(false);
    expect(nextEvents).toHaveLength(1);
  });

  it('retires every old child before a new owner generation and rejects delayed resets', () => {
    const store = new SourceWindowSnapshots<Snapshot>(7, 2), events: unknown[] = [];
    store.begin(key()); store.attach(key(), endpoint(events));
    expect(store.reset(3)).toBe(true);
    expect(events).toEqual(['dispose']);
    expect(store.begin(key())).toBe(false);
    expect(store.reset(2)).toBe(false);
    expect(store.begin(key('win:11', 2, 3))).toBe(true);
    expect(store.reset(3)).toBe(false);
    expect(store.current('win:11')).toEqual(key('win:11', 2, 3));
  });

  it('isolates identical source IDs on two remote owners and refuses malformed keys/revisions', () => {
    const a = new SourceWindowSnapshots<Snapshot>(7, 2), b = new SourceWindowSnapshots<Snapshot>(8, 2);
    expect(a.begin(key())).toBe(true); expect(b.begin(key('win:11', 1, 2, 8))).toBe(true);
    expect(a.begin(key('win:11', 2, 2, 8))).toBe(false);
    expect(a.begin({ ...key(), incarnation: 1.5 })).toBe(false);
    expect(a.publish({ key: key(), revision: NaN, stream: null })).toBe(false);
    expect(a.publish({ key: key(), revision: -1, stream: null })).toBe(false);
    expect(a.publish({ key: key(), revision: Number.MAX_SAFE_INTEGER + 1, stream: null })).toBe(false);
    a.clear(); expect(b.current('win:11')).toEqual(key('win:11', 1, 2, 8));
  });

  it('clears all endpoints even if a dead child throws during disposal', () => {
    const errors: unknown[] = [], events: unknown[] = [];
    const store = new SourceWindowSnapshots<Snapshot>(7, 2, error => errors.push(error));
    const failure = Error('child is gone');
    store.begin(key()); store.attach(key(), { update() {}, dispose() { throw failure; } });
    store.begin(key('dsp:1')); store.attach(key('dsp:1'), endpoint(events));
    store.clear(); store.clear();
    expect(errors).toEqual([failure]); expect(events).toEqual(['dispose']);
    expect(store.current('win:11')).toBeUndefined(); expect(store.current('dsp:1')).toBeUndefined();
    expect(store.begin(key())).toBe(false);
  });
  it('a broken child update cannot abort a sibling or revive the failing endpoint', () => {
    const errors:unknown[]=[];const updates:unknown[]=[];const failure=Error('dead child update');
    const store=new SourceWindowSnapshots<Snapshot>(7,2,error=>errors.push(error));
    const broken={update(){throw failure;},dispose(){updates.push('broken disposed');}};
    store.begin(key());store.attach(key(),broken);
    store.begin(key('dsp:1'));store.attach(key('dsp:1'),endpoint(updates));
    expect(()=>store.publish({key:key(),revision:1,stream:null})).not.toThrow();
    expect(store.endpoint(key())).toBeUndefined();
    store.publish({key:key('dsp:1'),revision:1,stream:null});
    expect(errors).toEqual([failure]);expect(updates[0]).toBe('broken disposed');expect(updates).toHaveLength(2);
  });

});
