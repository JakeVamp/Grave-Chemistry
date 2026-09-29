// Both worker functions are called by Supabase Cron, not by users. They
// require a shared secret header; with no secret configured they refuse
// every request (fail closed).

export function isAuthorizedCronRequest(req: Request, secret: string | undefined): boolean {
  if (!secret || secret.length < 32) return false;
  const provided = req.headers.get("x-cron-secret") ?? "";
  return constantTimeEqual(provided, secret);
}

function constantTimeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length ^ right.length;
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}
