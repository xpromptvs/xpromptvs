/// The tab bar's ORDER — terminal tabs and window tabs interleaved, as the driver arranged them.
///
/// THE HOST KEEPS IT (`view-set.tabOrder`, docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md):
/// every device shows the same bar, and only the driver's `move-tab` changes it. This module reads it,
/// and moves a key the way the host will so a drop shows at once.

export type TabKind = "terminal" | "window" | "agent";

/// A key's kind by its PREFIX, the rule every id in the protocol follows: `pty:`/`tmux:` a terminal tab,
/// `win:`/`dsp:`/`sim:` a window of the session — a simulator only in the spelling the host writes, an uppercase
/// UUID (`TabKey.isWindow`).
export function tabKind(key: string): TabKind | null {
  if (/^agent:.+/.test(key)) return "agent";
  if (/^(pty|tmux):./.test(key)) return "terminal";
  if (/^(win|dsp):./.test(key)) return "window";
  if (/^sim:[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(key)) return "window";
  return null;
}

/// Insert `key` where the host's DEFAULT PLACEMENT puts a new tab: right after the last tab of its own
/// kind; with none, a terminal FIRST and a window LAST — so a bar nobody dragged is today's bar.
function placeNew(order: string[], key: string, kind: (k: string) => TabKind): void {
  const ownKind = kind(key), terminal = ownKind === "terminal";
  let last = -1;
  for (let i = order.length - 1; i >= 0; i--) {
    if (kind(order[i]!) === ownKind) { last = i; break; }
  }
  if (last >= 0) order.splice(last + 1, 0, key);
  else if (terminal) order.unshift(key);
  else order.push(key);
}

/// The bar this client shows: `tabOrder`'s keys that it knows, in that order, then any it knows that
/// `tabOrder` does not name yet, each placed as the host will place it — a `term-list` can land ahead
/// of the `view-set` that orders its new tab, and the tab must not jump when that arrives.
///
/// The kind comes from which LIST a key is in, never its prefix: the headless test pattern's one
/// source is not a `win:` id.
export function tabBarOrder(terminals: readonly string[], windows: readonly string[],
                            tabOrder: readonly string[], agents: readonly string[] = []): string[] {
  const termSet = new Set(terminals);
  const known = new Set<string>([...terminals, ...windows, ...agents]);
  const agentSet=new Set(agents);
  const kind = (k: string):TabKind => termSet.has(k)?"terminal":agentSet.has(k)?"agent":"window";
  const out: string[] = [];
  const seen = new Set<string>();
  for (const k of tabOrder) if (known.has(k) && !seen.has(k)) { out.push(k); seen.add(k); }
  for (const k of [...terminals, ...windows, ...agents]) if (!seen.has(k)) { placeNew(out, k, kind); seen.add(k); }
  return out;
}

/// `order` with `key` moved to just before `before`, or to the END when it is null — the host's
/// `SessionState.moveTab`. Null for what the host refuses: an unknown key or `before`, or `before === key`.
export function moveTab(order: readonly string[], key: string, before: string | null): string[] | null {
  if (!order.includes(key) || before === key || (before !== null && !order.includes(before))) return null;
  const rest = order.filter((k) => k !== key);
  rest.splice(before === null ? rest.length : rest.indexOf(before), 0, key);
  return rest;
}

/// Whether two orders agree on every key they share.
function agrees(a: readonly string[], b: readonly string[]): boolean {
  const inB = new Set(b), inA = new Set(a);
  const x = a.filter((k) => inB.has(k)), y = b.filter((k) => inA.has(k));
  return x.length === y.length && x.every((k, i) => k === y[i]);
}

/// WHAT THE DRIVER JUST DID, SHOWN AT ONCE, until the host's state says the same thing — a drop and a
/// rename are one round trip from their echo, and the bar snapping back for it reads as a refusal. A
/// move or a name the host REFUSED is never echoed, so each gives up after `HOLD_MS` and the host's
/// state shows again. Pure: the caller passes the clock.
export class PendingTabs {
  static readonly HOLD_MS = 3000;
  private order: { keys: string[]; until: number } | null = null;
  private readonly names = new Map<string, { label: string; was: string; until: number }>();

  /// The bar after a drop.
  moved(order: readonly string[], now: number): void {
    this.order = { keys: [...order], until: now + PendingTabs.HOLD_MS };
  }

  /// A tab given `label` while the host still calls it `hostLabel`.
  renamed(key: string, label: string, hostLabel: string, now: number): void {
    this.names.set(key, { label, was: hostLabel, until: now + PendingTabs.HOLD_MS });
  }

  /// The host said no to `key`'s name (`tmux-error rename-failed`): show the host's label again now.
  refused(key: string): void { this.names.delete(key); }

  /// The bar to show over the host's `host` order. A pending order the host agrees with is CONFIRMED and
  /// forgotten — the host's own order then shows, with whatever else changed meanwhile. One it does not
  /// agree with yet shows over it, with the host's keys it lacks placed after their host predecessor.
  barOrder(host: readonly string[], now: number): string[] {
    const p = this.order;
    if (p && (now >= p.until || agrees(p.keys, host))) this.order = null;
    if (!this.order) return [...host];
    const inHost = new Set(host);
    const out = this.order.keys.filter((k) => inHost.has(k));
    host.forEach((k, i) => {
      if (out.includes(k)) return;
      const prev = host.slice(0, i).reverse().find((h) => out.includes(h));
      out.splice(prev === undefined ? 0 : out.indexOf(prev) + 1, 0, k);
    });
    return out;
  }

  /// The label to show for `key`, which the host calls `hostLabel`. The pending name holds only while the
  /// host's label is still the one it replaced: ANY change is the host's answer (tmux stores a name its
  /// own way — a backslash comes back doubled — so its answer need not be what was typed).
  label(key: string, hostLabel: string, now: number): string {
    const p = this.names.get(key);
    if (!p) return hostLabel;
    if (now < p.until && hostLabel === p.was) return p.label;
    this.names.delete(key);
    return hostLabel;
  }

  /// When the next pending entry gives up, or null with none — the caller re-renders then. Drops every
  /// entry already past FIRST: one nothing reads again (a name for a tab that closed, an order while a
  /// rename holds the bar) would otherwise answer a time in the past for ever, and the caller's timer
  /// re-arm every millisecond.
  nextExpiry(now: number): number | null {
    if (this.order && now >= this.order.until) this.order = null;
    for (const [key, n] of this.names) if (now >= n.until) this.names.delete(key);
    const all = [...this.names.values()].map((n) => n.until);
    if (this.order) all.push(this.order.until);
    return all.length ? Math.min(...all) : null;
  }
}
