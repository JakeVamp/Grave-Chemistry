// Provider boundaries for child-safety scanning and general moderation.
//
// No paid provider is wired in. Until one is approved and configured, the
// defaults below return "manual review", so nothing is ever auto-approved
// (fail closed). Adapters for e.g. PhotoDNA or Thorn Safer implement
// ChildSafetyProvider and read credentials from Edge Function secrets.

export type ChildSafetyResult =
  | "clear"
  | "possible_match"
  | "confirmed_known_hash_match"
  | "provider_error"
  | "manual_review_required"
  | "pending";

export interface ChildSafetyScanInput {
  /** Normalised JPEG. Only the image and its hash are sent: no user data. */
  jpeg: Uint8Array;
  sha256: string;
}

export interface ChildSafetyProvider {
  readonly name: string;
  scan(input: ChildSafetyScanInput): Promise<{ result: ChildSafetyResult }>;
}

export type ModerationResult = "approve" | "reject" | "manual_review" | "provider_error" | "pending";

export interface ModerationOutcome {
  result: ModerationResult;
  /**
   * Policy categories, e.g. explicit_sexual, graphic_violence, promotional,
   * text_solicitation, not_a_person. Internal only.
   */
  categories: string[];
}

export interface ModerationProvider {
  readonly name: string;
  check(input: { jpeg: Uint8Array }): Promise<ModerationOutcome>;
}

/** Default until a child-safety provider is approved: always a human. */
export class UnconfiguredChildSafetyProvider implements ChildSafetyProvider {
  readonly name = "none";
  scan(): Promise<{ result: ChildSafetyResult }> {
    return Promise.resolve({ result: "manual_review_required" });
  }
}

/** Default until a moderation provider is approved: always a human. */
export class UnconfiguredModerationProvider implements ModerationProvider {
  readonly name = "none";
  check(): Promise<ModerationOutcome> {
    return Promise.resolve({ result: "manual_review", categories: [] });
  }
}

/**
 * Chooses providers from Edge Function secrets. An unknown provider name
 * is a configuration error: the function refuses to run rather than
 * silently skipping checks.
 */
export function providersFromEnv(env: (key: string) => string | undefined): {
  childSafety: ChildSafetyProvider;
  moderation: ModerationProvider;
} {
  const childSafety = env("CHILD_SAFETY_PROVIDER") ?? "none";
  const moderation = env("MODERATION_PROVIDER") ?? "none";
  if (childSafety !== "none") {
    throw new Error(`child-safety provider "${childSafety}" is not implemented`);
  }
  if (moderation !== "none") {
    throw new Error(`moderation provider "${moderation}" is not implemented`);
  }
  return {
    childSafety: new UnconfiguredChildSafetyProvider(),
    moderation: new UnconfiguredModerationProvider(),
  };
}

export class ProviderTimeout extends Error {}

export async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new ProviderTimeout("provider timed out")), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/** Provider calls never throw: errors and timeouts become provider_error. */
export async function scanChildSafety(
  provider: ChildSafetyProvider,
  input: ChildSafetyScanInput,
  timeoutMs: number,
): Promise<ChildSafetyResult> {
  try {
    return (await withTimeout(provider.scan(input), timeoutMs)).result;
  } catch {
    return "provider_error";
  }
}

export async function checkModeration(
  provider: ModerationProvider,
  jpeg: Uint8Array,
  timeoutMs: number,
): Promise<ModerationOutcome> {
  try {
    const outcome = await withTimeout(provider.check({ jpeg }), timeoutMs);
    return { result: outcome.result, categories: outcome.categories.slice(0, 10) };
  } catch {
    return { result: "provider_error", categories: [] };
  }
}
