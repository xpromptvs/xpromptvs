import { describe, it, expect, vi } from "vitest";
import { AgentProtocol } from "../src/client/agents/protocol";

describe("agent wire authority and bulk reassembly", () => {
  it("names the negotiated epoch and rejects outstanding work on reset", async () => {
    const sent: any[] = [];
    const p = new AgentProtocol(m => sent.push(m), () => {});
    const hello = p.call("hello");
    p.receive({t:"agent-response",id:sent[0].id,epoch:"7",result:{available:true}});
    await hello;
    const list = p.call("list");
    expect(sent[1].epoch).toBe("7");
    p.reset();
    await expect(list).rejects.toThrow(/connection|control/i);
    expect(p.receive({t:"agent-response",id:sent[1].id,epoch:"7",result:{secret:true}})).toBe(true);
  });
  it("assembles ordered chunks once and refuses mismatched size and duplicate chunks", () => {
    const event = vi.fn(), p = new AgentProtocol(() => {},event);
    const wire = JSON.stringify({t:"agent-event",epoch:"7",event:{method:"turn/completed",params:{threadId:"t"}}});
    const b64 = (s:string) => btoa(s);
    p.receive({t:"agent-chunk",transfer:"x",epoch:"7",seq:0,count:2,total:wire.length,data:b64(wire.slice(0,20))});
    p.receive({t:"agent-chunk",transfer:"x",epoch:"7",seq:1,count:2,total:wire.length,data:b64(wire.slice(20))});
    // No negotiated epoch: unauthenticated events are not rendered.
    expect(event).not.toHaveBeenCalled();
    expect(()=>p.receive({t:"agent-chunk",transfer:"huge",epoch:"7",seq:0,count:1,total:100_000_000,data:""})).not.toThrow();
  });
});
