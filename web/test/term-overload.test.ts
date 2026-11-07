import { describe, expect, it, vi } from 'vitest';
import { TermOverload, parseTermStreamError } from '../src/client/term-overload';

function setup() {
  const d = { stop: vi.fn(), show: vi.fn(), reconnect: vi.fn() };
  const overload = new TermOverload(d);
  return { d, overload };
}
const message = (epoch: string) => ({ t: 'term-stream-error', reason: 'overloaded', epoch });
describe('terminal overload', () => {
  it('parses codec recovery errors with exact UInt64 epochs', () => {
    expect(parseTermStreamError({ t: 'term-stream-error', reason: 'codec', epoch: '18446744073709551615' }))
      .toEqual({ reason: 'codec', epoch: 18446744073709551615n });
    expect(parseTermStreamError({ t: 'term-stream-error', reason: 'codec', epoch: '18446744073709551616' })).toBeNull();
  });
  it('latches matching-epoch failure once and leaves recovery to explicit reconnect', () => {
    const { d, overload } = setup();
    overload.receive(message('9007199254740993'), 9007199254740993n);
    expect(overload.blocked).toBe(true);
    expect(d.stop).toHaveBeenCalledTimes(1);
    expect(d.show).toHaveBeenCalledWith('Terminal output stopped: queue limit reached.', expect.any(Function));
    overload.receive(message('9007199254740993'), 9007199254740993n);
    overload.receive(message('9007199254740994'), 9007199254740994n);
    expect(d.stop).toHaveBeenCalledTimes(1);
    expect(overload.blocked).toBe(true);
    expect(d.reconnect).not.toHaveBeenCalled();
    d.show.mock.calls[0]![1]();
    expect(d.reconnect).toHaveBeenCalledTimes(1);
  });
  it('ignores stale and malformed errors', () => {
    const { d, overload } = setup();
    for (const epoch of ['1', '0', '-1', '01', '18446744073709551616', 'oops']) overload.receive(message(epoch), 2n);
    expect(overload.blocked).toBe(false); expect(d.stop).not.toHaveBeenCalled();
  });
  it('stops even when overload retires a future wire before START can be sent', () => {
    const { d, overload } = setup();
    overload.receive(message('3'), 2n);
    expect(overload.blocked).toBe(true); expect(d.stop).toHaveBeenCalledTimes(1);
    const first = setup(); first.overload.receive(message('3'), null);
    expect(first.overload.blocked).toBe(true);
    const stale = setup(); stale.overload.receive(message('3'), 4n);
    expect(stale.overload.blocked).toBe(false);
  });
});
