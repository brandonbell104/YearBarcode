// Asks Prodigi (sandbox by default) about every catalog product, plus a few
// alternative SKUs: does it exist, which attributes does it need, what size is
// its print area, and what does one cost to make and ship to the US?
//
// Run: PRODIGI_API_KEY=... npx tsx scripts/check-prodigi.ts
// Exits 1 if a catalog product's SKU or attribute is rejected by Prodigi.

import { PRODUCTS } from "../src/catalog";

const BASE = process.env.PRODIGI_BASE_URL ?? "https://api.sandbox.prodigi.com/v4.0";
const KEY = process.env.PRODIGI_API_KEY;
if (!KEY) {
  console.log("PRODIGI_API_KEY is not set; skipping the Prodigi product check.");
  process.exit(0);
}

async function call(method: string, path: string, body?: unknown): Promise<{ status: number; json: any }> {
  const response = await fetch(BASE + path, {
    method,
    headers: { "X-API-Key": KEY!, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, json: await response.json().catch(() => ({})) };
}

const money = (m: any) => (m ? `${m.amount} ${m.currency}` : "?");

async function describe(sku: string, attributes: Record<string, string>): Promise<{ ok: boolean; line: string }> {
  const product = await call("GET", `/products/${encodeURIComponent(sku)}`);
  if (product.status !== 200) return { ok: false, line: `${sku}: not found (${product.status} ${product.json?.outcome ?? ""})` };
  const p = product.json.product ?? {};
  const options = Object.entries(p.attributes ?? {}).map(([k, v]) => `${k}=[${(v as string[]).join(", ")}]`).join(" ");
  const areas = Object.entries(p.printAreas ?? {}).map(([k, v]: [string, any]) => `${k}${v?.required ? "*" : ""}`).join(",");
  const variant = (p.variants ?? [])[0];
  const pixels = variant?.printAreaSizes?.default ? `${variant.printAreaSizes.default.horizontalResolution}x${variant.printAreaSizes.default.verticalResolution}px` : "";

  const quote = await call("POST", "/quotes", {
    shippingMethod: "Standard",
    destinationCountryCode: "US",
    currencyCode: "USD",
    items: [{ sku, copies: 1, attributes, assets: [{ printArea: "default" }] }],
  });
  const q = quote.json?.quotes?.[0];
  const cost = q
    ? `item ${money(q.costSummary?.items)} + shipping ${money(q.costSummary?.shipping)} = ${money(q.costSummary?.totalCost ?? q.costSummary?.total)}`
    : `quote failed (${quote.status} ${quote.json?.outcome ?? ""} ${JSON.stringify(quote.json?.failures ?? quote.json?.traceParent ?? "")})`;
  return {
    ok: Boolean(q),
    line: `${sku} ${JSON.stringify(attributes)}: "${p.description ?? ""}" ${pixels} areas=${areas} options: ${options || "none"}\n    ${cost}`,
  };
}

let failed = false;
console.log(`Prodigi: ${BASE}\n\nCatalog products (US, Standard shipping):`);
for (const product of PRODUCTS) {
  const { ok, line } = await describe(product.prodigiSku, product.attributes);
  if (!ok) failed = true;
  console.log(`${ok ? "OK  " : "FAIL"} ${product.id} -> ${line}`);
}

if (failed) {
  console.log("\nSome catalog products were rejected by Prodigi; see FAIL lines above.");
  process.exit(1);
}
