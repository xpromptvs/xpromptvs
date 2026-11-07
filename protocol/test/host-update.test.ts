import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { parseReleaseIdentity, compareReleases, parseHostUpdateRequest } from '../src/host-update';
const fixtures = JSON.parse(readFileSync(new URL('../fixtures/host-update.json', import.meta.url), 'utf8'));
describe('release identity', () => {
  for (const c of fixtures.identities) it(c.name, () => expect(parseReleaseIdentity(c.value) !== null).toBe(c.valid));
  for (const c of fixtures.comparisons) it(c.name, () => expect(compareReleases(c.host, c.client)).toBe(c.result));
  it('accepts only bounded update requests without caller-controlled URLs', () => {
    const r = {t:'host-update-request', requestId:'47b01652-900b-44c7-bb13-60704c2bb0b4', minimumBuild:12};
    expect(parseHostUpdateRequest(r)).toEqual(r);
    for (const bad of [{...r,minimumBuild:0},{...r,minimumBuild:1.5},{...r,requestId:'x'}, {...r,url:'https://evil.test'}]) expect(parseHostUpdateRequest(bad)).toBeNull();
  });
});
