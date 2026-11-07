import { it, expect } from "vitest";
import { renderAgentItem } from "../src/client/agents/render";

it("renders command output and file diffs as selectable graphical content", () => {
  const command = renderAgentItem({id:"c",type:"commandExecution",command:"npm test",cwd:"/repo",status:"completed",aggregatedOutput:"42 passed\n",exitCode:0});
  expect(command.textContent).toContain("npm test"); expect(command.textContent).toContain("42 passed");
  const diff = renderAgentItem({id:"d",type:"fileChange",changes:[{path:"/repo/a.ts",diff:"-old\n+new",kind:{type:"update"}}]});
  expect(diff.textContent).toContain("a.ts"); expect(diff.textContent).toContain("+new");
});
it("never executes transcript HTML or javascript URLs and preserves unknown records", () => {
  const item = renderAgentItem({id:"m",type:"agentMessage",text:'## Result\n<img src=x onerror=alert(1)>\n[bad](javascript:alert(1)) [safe](https://example.com)'});
  expect(item.querySelector("img")).toBeNull();
  expect(item.querySelector('a[href^="javascript:"]')).toBeNull();
  expect(item.querySelector('a[href="https://example.com/"]')).not.toBeNull();
  expect(renderAgentItem({id:"u",type:"futureTool",payload:{count:42}}).textContent).toContain("42");
});
it("has a readable fallback for every installed item family", () => {
  const types = ["userMessage","agentMessage","hookPrompt","functionCallOutput","plan","reasoning","commandExecution","fileChange","mcpToolCall","dynamicToolCall","collabAgentToolCall","subAgentActivity","webSearch","imageView","sleep","imageGeneration","enteredReviewMode","exitedReviewMode","contextCompaction"];
  for (const type of types) expect(renderAgentItem({id:type,type,detail:"visible"}).textContent!.length).toBeGreaterThan(0);
});
it("renders structured hook text as readable safe markdown without its transport wrapper", () => {
  const item = renderAgentItem({id:"hook",type:"hookPrompt",fragments:[{type:"text",text:"Project hook: **retain shared tokens**.\n\n<script>literal</script>"}]});
  const body = item.querySelector(".agent-markdown")!;
  expect(body.querySelector("strong")?.textContent).toBe("retain shared tokens");
  expect(body.textContent).not.toContain('"type"');
  expect(body.textContent).not.toContain('"text"');
  expect(body.querySelector("script")).toBeNull();
  expect(body.textContent).toContain("<script>literal</script>");
});
