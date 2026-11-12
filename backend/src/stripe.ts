// Minimal Stripe REST client (fetch only, no SDK) plus webhook verification.

import { hmacHex, safeEqual } from "./crypto";

const API = "https://api.stripe.com/v1";

export interface PaymentIntent {
  id: string;
  status: string;
  amount: number;
  currency: string;
  client_secret: string;
  metadata: Record<string, string>;
  receipt_email?: string | null;
  shipping?: {
    name: string;
    address: { line1: string; line2?: string | null; city: string; state?: string | null; postal_code: string; country: string };
  } | null;
}

export class StripeError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

/** Stripe's form encoding: nested objects become a[b][c]=value. */
export function formEncode(value: Record<string, unknown>, prefix = ""): string[] {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(value)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === "object" && !Array.isArray(v)) {
      parts.push(...formEncode(v as Record<string, unknown>, key));
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
    }
  }
  return parts;
}

export class Stripe {
  constructor(private readonly secretKey: string, private readonly fetcher: typeof fetch = (input, init) => fetch(input, init)) {}

  private async call<T>(method: string, path: string, body?: Record<string, unknown>, idempotencyKey?: string): Promise<T> {
    const headers: Record<string, string> = { Authorization: `Bearer ${this.secretKey}` };
    if (body) headers["Content-Type"] = "application/x-www-form-urlencoded";
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
    const response = await this.fetcher(`${API}${path}`, { method, headers, body: body ? formEncode(body).join("&") : undefined });
    const json = (await response.json()) as any;
    if (!response.ok) throw new StripeError(json?.error?.message ?? `Stripe ${response.status}`, response.status);
    return json as T;
  }

  createPaymentIntent(params: Record<string, unknown>, idempotencyKey?: string) {
    return this.call<PaymentIntent>("POST", "/payment_intents", params, idempotencyKey);
  }

  retrievePaymentIntent(id: string) {
    return this.call<PaymentIntent>("GET", `/payment_intents/${encodeURIComponent(id)}`);
  }

  updateMetadata(id: string, metadata: Record<string, string>) {
    return this.call<PaymentIntent>("POST", `/payment_intents/${encodeURIComponent(id)}`, { metadata });
  }
}

/**
 * Verifies a Stripe-Signature header (t=timestamp,v1=signature,...) against the
 * raw body. Rejects events older than `toleranceSeconds`.
 */
export async function verifyStripeSignature(
  payload: string,
  header: string | null,
  secret: string,
  toleranceSeconds = 300,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!header) return false;
  const parts = header.split(",").map((p) => p.trim().split("="));
  const timestamp = parts.find(([k]) => k === "t")?.[1];
  const signatures = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!timestamp || signatures.length === 0) return false;
  if (Math.abs(nowSeconds - Number(timestamp)) > toleranceSeconds) return false;
  const expected = await hmacHex(secret, `${timestamp}.${payload}`);
  return signatures.some((s) => s !== undefined && safeEqual(s, expected));
}
