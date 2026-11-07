/**
 * WebSocket close code a client sends to say it is LEAVING DELIBERATELY, rather than dropping.
 *
 * Without it the control plane cannot tell a closed tab from a network blip, so it suspends
 * unconditionally and the host holds the peer — with its video sinks attached — for the full 180s
 * grace window, capturing and encoding for a page that is gone.
 *
 * 4001 is in the 3000-4999 application range that `SessionDO.webSocketClose` already echoes, and is
 * deliberately NOT 1000/1001: a browser may send those itself on an ordinary close, so they cannot
 * carry intent.
 */
export const LEAVE_CLOSE_CODE = 4001;
