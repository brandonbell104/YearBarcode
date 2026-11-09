// Small Web Crypto helpers (available in Workers and Node 20+).

const encoder = new TextEncoder();

export function toHex(bytes: ArrayBuffer | Uint8Array): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(bytes = 32): string {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return toHex(buffer);
}

export async function sha256Hex(text: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

/** Constant-time comparison of two hex strings. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Signed, expiring link so Prodigi (and only someone with the link) can fetch a poster file. */
export async function signAssetPath(secret: string, key: string, expiresAt: number): Promise<string> {
  const sig = await hmacHex(secret, `${key}:${expiresAt}`);
  return `/v1/assets/${key}?exp=${expiresAt}&sig=${sig}`;
}

export async function verifyAssetSignature(secret: string, key: string, exp: string | null, sig: string | null, now = Date.now()): Promise<boolean> {
  if (!exp || !sig) return false;
  const expiresAt = Number(exp);
  if (!Number.isFinite(expiresAt) || expiresAt < now) return false;
  return safeEqual(await hmacHex(secret, `${key}:${expiresAt}`), sig);
}
