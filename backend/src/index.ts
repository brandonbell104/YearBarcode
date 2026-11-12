// Year Barcode print orders.
//
// Flow (the app drives steps 1–3):
//   1. POST /v1/orders               → Stripe PaymentIntent (order ID = its ID) + an upload token
//   2. PUT  /v1/orders/:id/image     → poster PNG/JPEG streamed into R2
//   3. App shows Stripe's payment sheet with the client secret
//   4. POST /v1/stripe/webhook       → on payment success, send the order to Prodigi
//   5. GET  /v1/orders/:id           → payment + printing/shipping status for the app
// Prodigi downloads the poster from GET /v1/assets/... with a signed, expiring link.

import { findProduct, publicCatalog, CURRENCY, SHIPPING_COUNTRIES, type Product } from "./catalog";
import { randomToken, sha256Hex, safeEqual, signAssetPath, verifyAssetSignature } from "./crypto";
import { Prodigi, ProdigiError, type Recipient } from "./prodigi";
import { Stripe, StripeError, verifyStripeSignature, type PaymentIntent } from "./stripe";
import { payPage, returnPage } from "./paypage";

export interface Env {
  PRINTS: R2Bucket;
  PRODIGI_BASE_URL: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  /** Used by the hosted payment page (safe to publish). */
  STRIPE_PUBLISHABLE_KEY: string;
  PRODIGI_API_KEY: string;
  ASSET_SIGNING_KEY: string;
}

/** Larger than any poster PNG we produce, and within Workers' request limit. */
export const MAX_IMAGE_BYTES = 95 * 1024 * 1024;
/** How long Prodigi's download link stays valid. */
const ASSET_LINK_DAYS = 14;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const error = (message: string, status: number) => json({ error: message }, status);
const html = (body: string) =>
  new Response(body, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Frame-Options": "DENY",
    },
  });

export default {
  async fetch(request: Request, env: Env, _ctx?: ExecutionContext, fetcher: typeof fetch = (input, init) => fetch(input, init)): Promise<Response> {
    const url = new URL(request.url);
    // Keys pasted into dashboards often carry a stray space or line break,
    // which makes them invalid in an HTTP header.
    const stripe = new Stripe((env.STRIPE_SECRET_KEY ?? "").trim(), fetcher);
    const prodigi = new Prodigi((env.PRODIGI_API_KEY ?? "").trim(), env.PRODIGI_BASE_URL, fetcher);
    const parts = url.pathname.split("/").filter(Boolean); // ["v1", ...]

    try {
      if (request.method === "GET" && url.pathname === "/v1/catalog") return json(publicCatalog());
      if (request.method === "GET" && url.pathname === "/v1/pay") {
        if (!env.STRIPE_PUBLISHABLE_KEY) return error("Payments aren't set up yet.", 503);
        return html(payPage(env.STRIPE_PUBLISHABLE_KEY.trim()));
      }
      if (request.method === "GET" && url.pathname === "/v1/pay/return") return html(returnPage());
      if (request.method === "POST" && url.pathname === "/v1/orders") return await createOrder(request, stripe);
      if (request.method === "POST" && url.pathname === "/v1/stripe/webhook") return await stripeWebhook(request, env, stripe, prodigi, url.origin);
      if (parts[0] === "v1" && parts[1] === "orders" && parts[2]) {
        const id = decodeURIComponent(parts[2]);
        if (request.method === "PUT" && parts[3] === "image" && parts.length === 4) return await uploadImage(request, env, stripe, id);
        if (request.method === "GET" && parts.length === 3) return await orderStatus(request, stripe, prodigi, id);
        if (request.method === "GET" && parts[3] === "payment" && parts.length === 4) return await paymentDetails(request, stripe, id);
      }
      if (request.method === "GET" && parts[0] === "v1" && parts[1] === "assets" && parts.length > 2) {
        return await serveAsset(env, parts.slice(2).join("/"), url);
      }
      return error("Not found", 404);
    } catch (e) {
      if (e instanceof StripeError || e instanceof ProdigiError) {
        console.error(e.message);
        return error(e.status >= 500 ? "A payment or print service is unavailable. Please try again." : e.message, e.status >= 500 ? 502 : 400);
      }
      console.error(e);
      const detail = e instanceof Error ? e.message : String(e);
      return json({ error: `Something went wrong on the order server (${detail}).` }, 500);
    }
  },
};

// MARK: - Orders

interface CreateOrderBody {
  productId?: string;
  email?: string;
  recipient?: Partial<Recipient>;
}

export function validateOrder(body: CreateOrderBody): { product: Product; email: string; recipient: Recipient } | string {
  const product = body.productId ? findProduct(body.productId) : undefined;
  if (!product) return "Unknown product.";
  const email = (body.email ?? "").trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return "Enter a valid email address.";
  const r = body.recipient ?? {};
  const required: (keyof Recipient)[] = ["name", "line1", "city", "postalCode", "country"];
  for (const field of required) {
    if (!String(r[field] ?? "").trim()) return `Missing ${field}.`;
  }
  const country = String(r.country).trim().toUpperCase();
  if (!SHIPPING_COUNTRIES.includes(country)) return `We don't ship to ${country} yet.`;
  if (country === "US" && !String(r.state ?? "").trim()) return "Missing state.";
  const clean = (v: unknown) => (v === undefined ? undefined : String(v).trim().slice(0, 200) || undefined);
  return {
    product,
    email,
    recipient: {
      name: clean(r.name)!,
      line1: clean(r.line1)!,
      line2: clean(r.line2),
      city: clean(r.city)!,
      state: clean(r.state),
      postalCode: clean(r.postalCode)!,
      country,
      email,
    },
  };
}

async function createOrder(request: Request, stripe: Stripe): Promise<Response> {
  const body = (await request.json().catch(() => null)) as CreateOrderBody | null;
  if (!body) return error("Invalid request.", 400);
  const valid = validateOrder(body);
  if (typeof valid === "string") return error(valid, 400);
  const { product, email, recipient } = valid;

  const uploadToken = randomToken();
  const imageKey = `prints/${crypto.randomUUID()}`;
  const intent = await stripe.createPaymentIntent({
    amount: product.priceCents,
    currency: CURRENCY,
    automatic_payment_methods: { enabled: true },
    description: `Year Barcode print: ${product.title}`,
    receipt_email: email,
    shipping: {
      name: recipient.name,
      address: {
        line1: recipient.line1,
        line2: recipient.line2,
        city: recipient.city,
        state: recipient.state,
        postal_code: recipient.postalCode,
        country: recipient.country,
      },
    },
    metadata: {
      product_id: product.id,
      image_key: imageKey,
      upload_token_hash: await sha256Hex(uploadToken),
    },
  });

  return json({
    orderId: intent.id,
    clientSecret: intent.client_secret,
    uploadToken,
    amount: intent.amount,
    currency: intent.currency,
  }, 201);
}

/** The upload token proves the caller created this order. */
async function authorize(request: Request, intent: PaymentIntent): Promise<boolean> {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!token || !intent.metadata.upload_token_hash) return false;
  return safeEqual(await sha256Hex(token), intent.metadata.upload_token_hash);
}

async function uploadImage(request: Request, env: Env, stripe: Stripe, id: string): Promise<Response> {
  const intent = await stripe.retrievePaymentIntent(id);
  if (!(await authorize(request, intent))) return error("Not allowed.", 403);
  if (intent.status === "succeeded" || intent.status === "canceled") return error("This order can no longer be changed.", 409);

  const type = request.headers.get("Content-Type") ?? "";
  if (type !== "image/png" && type !== "image/jpeg") return error("Upload a PNG or JPEG.", 415);
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (!length || length > MAX_IMAGE_BYTES) return error("The image is missing or too large.", 413);
  if (!request.body) return error("Missing image.", 400);

  const extension = type === "image/png" ? "png" : "jpg";
  const key = `${intent.metadata.image_key}.${extension}`;
  await env.PRINTS.put(key, request.body, { httpMetadata: { contentType: type } });
  await stripe.updateMetadata(intent.id, { image_object: key });
  return new Response(null, { status: 204 });
}

/** What the payment page needs: the client secret, amount and prefill details. */
async function paymentDetails(request: Request, stripe: Stripe, id: string): Promise<Response> {
  const intent = await stripe.retrievePaymentIntent(id);
  if (!(await authorize(request, intent))) return error("Not allowed.", 403);
  if (!intent.metadata.image_object) return error("The poster hasn't finished uploading. Go back and try again.", 409);
  return json({
    clientSecret: intent.client_secret,
    amount: intent.amount,
    currency: intent.currency,
    status: intent.status,
    product: findProduct(intent.metadata.product_id ?? "")?.title ?? null,
    email: intent.receipt_email ?? null,
    name: intent.shipping?.name ?? null,
  });
}

async function orderStatus(request: Request, stripe: Stripe, prodigi: Prodigi, id: string): Promise<Response> {
  const intent = await stripe.retrievePaymentIntent(id);
  if (!(await authorize(request, intent))) return error("Not allowed.", 403);
  const prodigiID = intent.metadata.prodigi_order_id;
  const print = prodigiID ? await prodigi.getOrder(prodigiID) : null;
  return json({
    orderId: intent.id,
    payment: intent.status,
    product: findProduct(intent.metadata.product_id ?? "")?.title ?? null,
    imageReceived: Boolean(intent.metadata.image_object),
    printStage: print?.stage ?? (intent.status === "succeeded" ? "Submitting" : null),
    shipments: print?.shipments ?? [],
    problem: intent.metadata.fulfillment_error ?? null,
  });
}

// MARK: - Fulfillment

async function stripeWebhook(request: Request, env: Env, stripe: Stripe, prodigi: Prodigi, origin: string): Promise<Response> {
  const payload = await request.text();
  const valid = await verifyStripeSignature(payload, request.headers.get("Stripe-Signature"), (env.STRIPE_WEBHOOK_SECRET ?? "").trim());
  if (!valid) return error("Bad signature.", 400);

  const event = JSON.parse(payload) as { type: string; data: { object: PaymentIntent } };
  if (event.type !== "payment_intent.succeeded") return json({ received: true });

  // Re-read the intent: never trust the event body for state we act on.
  const intent = await stripe.retrievePaymentIntent(event.data.object.id);
  await fulfill(intent, env, stripe, prodigi, origin);
  return json({ received: true });
}

/** Sends a paid order to Prodigi once. Throws on transient failures so Stripe retries the webhook. */
export async function fulfill(intent: PaymentIntent, env: Env, stripe: Stripe, prodigi: Prodigi, origin: string): Promise<void> {
  if (intent.status !== "succeeded" || intent.metadata.prodigi_order_id) return;
  const product = findProduct(intent.metadata.product_id ?? "");
  const imageKey = intent.metadata.image_object;
  const shipping = intent.shipping;
  if (!product || !imageKey || !shipping) {
    await stripe.updateMetadata(intent.id, { fulfillment_error: !imageKey ? "image_missing" : "order_incomplete" });
    return;
  }

  const expiresAt = Date.now() + ASSET_LINK_DAYS * 86_400_000;
  const imageURL = origin + (await signAssetPath(env.ASSET_SIGNING_KEY, imageKey, expiresAt));
  const prodigiOrderID = await prodigi.createOrder({
    merchantReference: intent.id,
    sku: product.prodigiSku,
    attributes: product.attributes,
    imageURL,
    recipient: {
      name: shipping.name,
      email: intent.receipt_email ?? undefined,
      line1: shipping.address.line1,
      line2: shipping.address.line2 ?? undefined,
      city: shipping.address.city,
      state: shipping.address.state ?? undefined,
      postalCode: shipping.address.postal_code,
      country: shipping.address.country,
    },
  });
  await stripe.updateMetadata(intent.id, { prodigi_order_id: prodigiOrderID, fulfillment_error: "" });
}

// MARK: - Assets

async function serveAsset(env: Env, key: string, url: URL): Promise<Response> {
  const ok = await verifyAssetSignature(env.ASSET_SIGNING_KEY, key, url.searchParams.get("exp"), url.searchParams.get("sig"));
  if (!ok) return error("Link expired or invalid.", 403);
  const object = await env.PRINTS.get(key);
  if (!object) return error("Not found", 404);
  return new Response(object.body, {
    headers: {
      "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream",
      "Content-Length": String(object.size),
      "Cache-Control": "private, no-store",
    },
  });
}
