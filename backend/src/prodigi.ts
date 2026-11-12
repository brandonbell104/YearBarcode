// Minimal Prodigi Print API v4 client.

export interface Recipient {
  name: string;
  email?: string;
  line1: string;
  line2?: string;
  city: string;
  state?: string;
  postalCode: string;
  country: string;
}

export interface ProdigiOrderSummary {
  id: string;
  stage: string;
  shipments: { carrier?: string; trackingNumber?: string; trackingUrl?: string; status?: string }[];
}

export class ProdigiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export class Prodigi {
  constructor(
    private readonly apiKey: string,
    private readonly baseURL: string,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  private async call(method: string, path: string, body?: unknown, idempotencyKey?: string): Promise<any> {
    const headers: Record<string, string> = { "X-API-Key": this.apiKey, "Content-Type": "application/json" };
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
    const response = await this.fetcher(`${this.baseURL}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const json = (await response.json().catch(() => ({}))) as any;
    if (!response.ok) throw new ProdigiError(json?.outcome ?? json?.message ?? `Prodigi ${response.status}`, response.status);
    return json;
  }

  /** One print, shipped to the customer. `merchantReference` is our order ID. */
  async createOrder(params: { merchantReference: string; sku: string; attributes?: Record<string, string>; imageURL: string; recipient: Recipient }): Promise<string> {
    const r = params.recipient;
    const json = await this.call(
      "POST",
      "/Orders",
      {
        merchantReference: params.merchantReference,
        shippingMethod: "Standard",
        recipient: {
          name: r.name,
          email: r.email,
          address: {
            line1: r.line1,
            line2: r.line2,
            postalOrZipCode: r.postalCode,
            countryCode: r.country,
            townOrCity: r.city,
            stateOrCounty: r.state,
          },
        },
        items: [
          {
            merchantReference: params.merchantReference,
            sku: params.sku,
            copies: 1,
            attributes: params.attributes && Object.keys(params.attributes).length ? params.attributes : undefined,
            sizing: "fillPrintArea",
            assets: [{ printArea: "default", url: params.imageURL }],
          },
        ],
      },
      params.merchantReference,
    );
    const id = json?.order?.id;
    if (!id) throw new ProdigiError("Prodigi did not return an order ID", 502);
    return id;
  }

  async getOrder(id: string): Promise<ProdigiOrderSummary> {
    const json = await this.call("GET", `/Orders/${encodeURIComponent(id)}`);
    const order = json?.order ?? {};
    return {
      id: order.id ?? id,
      stage: order.status?.stage ?? "Unknown",
      shipments: (order.shipments ?? []).map((s: any) => ({
        carrier: s.carrier?.name,
        trackingNumber: s.tracking?.number,
        trackingUrl: s.tracking?.url,
        status: s.status,
      })),
    };
  }
}
