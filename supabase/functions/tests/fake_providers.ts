// Fake providers for automated tests only. They return synthetic results;
// nothing here can identify real content.

import type {
  ChildSafetyProvider,
  ChildSafetyResult,
  ModerationOutcome,
  ModerationProvider,
} from "../_shared/providers.ts";

type Behaviour<T> = T | "throw" | "hang";

export class FakeChildSafety implements ChildSafetyProvider {
  readonly name = "fake";
  calls = 0;
  constructor(private readonly behaviours: Behaviour<ChildSafetyResult>[]) {}

  scan(): Promise<{ result: ChildSafetyResult }> {
    const b = this.behaviours[Math.min(this.calls, this.behaviours.length - 1)];
    this.calls++;
    if (b === "throw") return Promise.reject(new Error("synthetic provider error"));
    if (b === "hang") return new Promise(() => {});
    return Promise.resolve({ result: b });
  }
}

export class FakeModeration implements ModerationProvider {
  readonly name = "fake";
  calls = 0;
  constructor(private readonly behaviours: Behaviour<ModerationOutcome>[]) {}

  check(): Promise<ModerationOutcome> {
    const b = this.behaviours[Math.min(this.calls, this.behaviours.length - 1)];
    this.calls++;
    if (b === "throw") return Promise.reject(new Error("synthetic provider error"));
    if (b === "hang") return new Promise(() => {});
    return Promise.resolve(b);
  }
}

export const approve: ModerationOutcome = { result: "approve", categories: [] };
