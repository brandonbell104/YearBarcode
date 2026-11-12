import { describe, expect, it, beforeEach } from "vitest";
import worker, { type Env, validateOrder } from "../src/index";
import { formEncode, verifyStripeSignature } from "../src/stripe";
import { hmacHex, signAssetPath, verifyAssetSignature } from "../src/crypto";
import { PRODUCTS, publicCatalog } from "../src/catalog";

// MARK: - Fakes

class FakeR2 {
  objects = new Map<string, { bytes: Uint8Array; type?: string }>();
  async put(key: string, body: ReadableStream | ArrayBuffer, options?: { httpMetadata?: { contentType?: string } }) {
    const bytes = new Uint8Array(await new Response(body as any).arrayBuffer());
    this.objects.set(key, { bytes, type: options?.httpMetadata?.contentType });
    return {};
  }
  async get(key: string) {
    const object = this.objects.get(key);
    if (!object) return null;
    return { body: new Response(object.bytes).body, size: object.bytes.length, httpMetadata: { contentType: object.type } };
  }
}

/** In-memory Stripe + Prodigi that the worker talks to through `fetch`. */
class FakeServices {
  intents = new Map<string, any>();
  prodigiOrders: any[] = [];
  next = 1;

  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    if (url.host === "api.stripe.com") return this.stripe(url, method, String(init?.body ?? ""));
    if (url.host.includes("prodigi")) return this.prodigi(url, method, init);
    throw new Error(`Unexpected fetch ${url}`);
  };

  private stripe(url: URL, method: string, body: string): Response {
    const form = new URLSearchParams(body);
    const get = (k: string) => form.get(k) ?? undefined;
    const metadataFrom = () => {
      const m: Record<string, string> = {};
      for (const [k, v] of form) {
        const match = k.match(/^metadata\[(.+)\]$/);
        if (match) m[match[1]] = v;
      }
      return m;
    };
    if (method === "POST" && url.pathname === "/v1/payment_intents") {
      const id = `pi_${this.next++}`;
      const intent = {
        id, status: "requires_payment_method", amount: Number(get("amount")), currency: get("currency"),
        client_secret: `${id}_secret`, receipt_email: get("receipt_email"), metadata: metadataFrom(),
        shipping: {
          name: get("shipping[name]"),
          address: {
            line1: get("shipping[address][line1]"), line2: get("shipping[address][line2]") ?? null,
            city: get("shipping[address][city]"), state: get("shipping[address][state]"),
            postal_code: get("shipping[address][postal_code]"), country: get("shipping[address][country]"),
          },
        },
      };
      this.intents.set(id, intent);
      return Response.json(intent);
    }
    const id = decodeURIComponent(url.pathname.split("/").pop()!);
    const intent = this.intents.get(id);
    if (!intent) return Response.json({ error: { message: "No such payment_intent" } }, { status: 404 });
    if (method === "POST") {
      for (const [k, v] of Object.entries(metadataFrom())) {
        if (v === "") delete intent.metadata[k]; else intent.metadata[k] = v;
      }
    }
    return Response.json(intent);
  }

  private prodigi(url: URL, method: string, init?: RequestInit): Response {
    if (method === "POST" && url.pathname.endsWith("/Orders")) {
      const order = { id: `ord_${this.prodigiOrders.length + 1}`, request: JSON.parse(String(init?.body)), headers: init?.headers };
      this.prodigiOrders.push(order);
      return Response.json({ outcome: "Created", order: { id: order.id } });
    }
    const id = url.pathname.split("/").pop();
    return Response.json({
      order: { id, status: { stage: "InProgress" }, shipments: [{ carrier: { name: "USPS" }, tracking: { number: "9400", url: "https://track.example/9400" }, status: "Shipped" }] },
    });
  }
}

// MARK: - Helpers

const env = (r2: FakeR2): Env => ({
  PRINTS: r2 as unknown as R2Bucket,
  PRODIGI_BASE_URL: "https://api.sandbox.prodigi.com/v4.0",
  STRIPE_SECRET_KEY: "sk_test_x",
  STRIPE_WEBHOOK_SECRET: "whsec_test",
  STRIPE_PUBLISHABLE_KEY: "pk_test_x",
  PRODIGI_API_KEY: "prodigi_test",
  ASSET_SIGNING_KEY: "asset-secret",
});

const order = {
  productId: "canvas-24x36",
  email: "buyer@example.com",
  recipient: { name: "Ada Lovelace", line1: "1 Main St", city: "Springfield", state: "IL", postalCode: "62701", country: "US" },
};

async function signedWebhook(payload: object) {
  const body = JSON.stringify(payload);
  const t = Math.floor(Date.now() / 1000);
  const sig = await hmacHex("whsec_test", `${t}.${body}`);
  return new Request("https://orders.example/v1/stripe/webhook", { method: "POST", body, headers: { "Stripe-Signature": `t=${t},v1=${sig}` } });
}

// MARK: - Tests

describe("helpers", () => {
  it("form-encodes nested objects like Stripe expects", () => {
    expect(formEncode({ amount: 100, shipping: { address: { line1: "1 Main" } }, skip: undefined }))
      .toEqual(["amount=100", "shipping%5Baddress%5D%5Bline1%5D=1%20Main"]);
  });

  it("verifies Stripe signatures and rejects tampering or old events", async () => {
    const t = 1_700_000_000;
    const sig = await hmacHex("whsec", `${t}.{"a":1}`);
    expect(await verifyStripeSignature('{"a":1}', `t=${t},v1=${sig}`, "whsec", 300, t)).toBe(true);
    expect(await verifyStripeSignature('{"a":2}', `t=${t},v1=${sig}`, "whsec", 300, t)).toBe(false);
    expect(await verifyStripeSignature('{"a":1}', `t=${t},v1=${sig}`, "whsec", 300, t + 301)).toBe(false);
    expect(await verifyStripeSignature('{"a":1}', null, "whsec")).toBe(false);
  });

  it("signs expiring asset links", async () => {
    const path = await signAssetPath("k", "prints/a.png", 2_000);
    const url = new URL(`https://x${path}`);
    expect(await verifyAssetSignature("k", "prints/a.png", url.searchParams.get("exp"), url.searchParams.get("sig"), 1_000)).toBe(true);
    expect(await verifyAssetSignature("k", "prints/a.png", url.searchParams.get("exp"), url.searchParams.get("sig"), 3_000)).toBe(false);
    expect(await verifyAssetSignature("k", "prints/b.png", url.searchParams.get("exp"), url.searchParams.get("sig"), 1_000)).toBe(false);
  });

  it("validates orders", () => {
    expect(typeof validateOrder(order)).toBe("object");
    expect(validateOrder({ ...order, productId: "nope" })).toBe("Unknown product.");
    expect(validateOrder({ ...order, email: "x" })).toBe("Enter a valid email address.");
    expect(validateOrder({ ...order, recipient: { ...order.recipient, country: "FR" } })).toBe("We don't ship to FR yet.");
    expect(validateOrder({ ...order, recipient: { ...order.recipient, state: "" } })).toBe("Missing state.");
  });

  it("publishes a catalog without supplier details", () => {
    const catalog = publicCatalog();
    expect(catalog.products).toHaveLength(PRODUCTS.length);
    expect(JSON.stringify(catalog)).not.toContain("GLOBAL-");
  });
});

describe("order flow", () => {
  let r2: FakeR2;
  let services: FakeServices;
  const call = (request: Request) => worker.fetch(request, env(r2), undefined, services.fetch as typeof fetch);

  beforeEach(() => {
    r2 = new FakeR2();
    services = new FakeServices();
  });

  it("creates, uploads, pays, sends to Prodigi once, and reports status", async () => {
    // 1. Create
    const created = await call(new Request("https://orders.example/v1/orders", { method: "POST", body: JSON.stringify(order) }));
    expect(created.status).toBe(201);
    const { orderId, clientSecret, uploadToken, amount } = (await created.json()) as any;
    expect(clientSecret).toBe(`${orderId}_secret`);
    expect(amount).toBe(14900);
    expect(services.intents.get(orderId).metadata.upload_token_hash).toBeTruthy();
    expect(JSON.stringify(services.intents.get(orderId))).not.toContain(uploadToken);

    // 2. Upload (wrong token refused)
    const png = new Uint8Array([137, 80, 78, 71, 1, 2, 3]);
    const upload = (token: string) => call(new Request(`https://orders.example/v1/orders/${orderId}/image`, {
      method: "PUT", body: png, headers: { Authorization: `Bearer ${token}`, "Content-Type": "image/png", "Content-Length": String(png.length) },
    }));
    expect((await upload("wrong")).status).toBe(403);
    expect((await upload(uploadToken)).status).toBe(204);
    const key = services.intents.get(orderId).metadata.image_object;
    expect(key).toMatch(/^prints\/.+\.png$/);
    expect(r2.objects.get(key)?.bytes).toEqual(png);

    // 2b. The hosted payment page gets the client secret only with the token.
    const payment = (token: string) => call(new Request(`https://orders.example/v1/orders/${orderId}/payment`, { headers: { Authorization: `Bearer ${token}` } }));
    expect((await payment("wrong")).status).toBe(403);
    expect(await (await payment(uploadToken)).json()).toMatchObject({ clientSecret, amount: 14900, email: "buyer@example.com", name: "Ada Lovelace" });
    const page = await call(new Request("https://orders.example/v1/pay"));
    expect(page.headers.get("Content-Type")).toContain("text/html");
    const pageText = await page.text();
    expect(pageText).toContain('"pk_test_x"');
    expect(pageText).not.toContain("sk_test");

    // 3. Payment succeeds → webhook (bad signature refused)
    services.intents.get(orderId).status = "succeeded";
    const event = { type: "payment_intent.succeeded", data: { object: { id: orderId } } };
    const forged = new Request("https://orders.example/v1/stripe/webhook", { method: "POST", body: JSON.stringify(event), headers: { "Stripe-Signature": "t=1,v1=00" } });
    expect((await call(forged)).status).toBe(400);
    expect((await call(await signedWebhook(event))).status).toBe(200);
    expect(services.prodigiOrders).toHaveLength(1);
    const sent = services.prodigiOrders[0].request;
    expect(sent.merchantReference).toBe(orderId);
    expect(sent.items[0].sku).toBe("GLOBAL-CAN-24X36");
    expect(sent.items[0].attributes).toEqual({ wrap: "MirrorWrap" });
    expect(sent.recipient.address).toMatchObject({ line1: "1 Main St", stateOrCounty: "IL", countryCode: "US" });
    expect(services.intents.get(orderId).metadata.prodigi_order_id).toBe("ord_1");

    // Stripe retries the webhook: no duplicate print.
    await call(await signedWebhook(event));
    expect(services.prodigiOrders).toHaveLength(1);

    // 4. Prodigi can download the poster through the signed link.
    const asset = await call(new Request(sent.items[0].assets[0].url));
    expect(asset.status).toBe(200);
    expect(new Uint8Array(await asset.arrayBuffer())).toEqual(png);
    const tampered = await call(new Request(sent.items[0].assets[0].url.replace(/sig=[0-9a-f]+/, "sig=00")));
    expect(tampered.status).toBe(403);

    // 5. Status for the app
    const status = await call(new Request(`https://orders.example/v1/orders/${orderId}`, { headers: { Authorization: `Bearer ${uploadToken}` } }));
    expect(await status.json()).toMatchObject({ payment: "succeeded", printStage: "InProgress", shipments: [{ trackingNumber: "9400" }] });

    // Uploads are closed after payment.
    expect((await upload(uploadToken)).status).toBe(409);
  });

  it("flags a paid order whose image never arrived instead of printing nothing", async () => {
    const created = await call(new Request("https://orders.example/v1/orders", { method: "POST", body: JSON.stringify(order) }));
    const { orderId } = (await created.json()) as any;
    services.intents.get(orderId).status = "succeeded";
    expect((await call(await signedWebhook({ type: "payment_intent.succeeded", data: { object: { id: orderId } } }))).status).toBe(200);
    expect(services.prodigiOrders).toHaveLength(0);
    expect(services.intents.get(orderId).metadata.fulfillment_error).toBe("image_missing");
  });

  it("rejects bad requests", async () => {
    expect((await call(new Request("https://orders.example/v1/orders", { method: "POST", body: "{" }))).status).toBe(400);
    expect((await call(new Request("https://orders.example/v1/nope"))).status).toBe(404);
    expect((await call(new Request("https://orders.example/v1/catalog"))).status).toBe(200);
  });
});
