import { expect, test } from "vitest";
import { schedule } from "../lib/queue";

test("never exceeds four concurrent jobs", async () => {
  let peak = 0, live = 0;
  await Promise.all(Array.from({ length: 50 }, () =>
    schedule(async () => { live++; peak = Math.max(peak, live); await new Promise(r => setTimeout(r, 1)); live--; })));
  expect(peak).toBeLessThanOrEqual(4);
});
