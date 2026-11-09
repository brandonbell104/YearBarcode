// Print products offered in the app.
//
// PLACEHOLDERS — confirm before launch:
//  * `prodigiSku`: copy the exact SKUs from the Prodigi dashboard product
//    catalog (they are not verified here).
//  * `priceCents`: retail price charged to the customer, shipping included.
//    Set it from Prodigi's wholesale cost + shipping + Stripe fees + margin.

export type ProductKind = "poster" | "framed";
export type PrintSize = "12x18" | "18x24" | "24x36";

export interface Product {
  id: string;
  kind: ProductKind;
  size: PrintSize;
  title: string;
  prodigiSku: string;
  priceCents: number;
}

export const CURRENCY = "usd";

/** ISO country codes we ship to. */
export const SHIPPING_COUNTRIES = ["US"];

const SIZES: PrintSize[] = ["12x18", "18x24", "24x36"];

const POSTER_PRICES: Record<PrintSize, number> = { "12x18": 3900, "18x24": 4900, "24x36": 6900 };
const FRAMED_PRICES: Record<PrintSize, number> = { "12x18": 9900, "18x24": 13900, "24x36": 18900 };

export const PRODUCTS: Product[] = SIZES.flatMap((size): Product[] => {
  const label = size.replace("x", " × ");
  return [
    {
      id: `poster-${size}`,
      kind: "poster",
      size,
      title: `${label} in poster`,
      prodigiSku: `GLOBAL-FAP-${size.toUpperCase()}`, // TODO: verify in Prodigi
      priceCents: POSTER_PRICES[size],
    },
    {
      id: `framed-black-${size}`,
      kind: "framed",
      size,
      title: `${label} in black frame`,
      prodigiSku: `GLOBAL-CFPM-${size.toUpperCase()}`, // TODO: verify in Prodigi
      priceCents: FRAMED_PRICES[size],
    },
  ];
});

export function findProduct(id: string): Product | undefined {
  return PRODUCTS.find((p) => p.id === id);
}

/** What the app shows (no supplier details). */
export function publicCatalog() {
  return {
    currency: CURRENCY,
    countries: SHIPPING_COUNTRIES,
    products: PRODUCTS.map(({ id, kind, size, title, priceCents }) => ({ id, kind, size, title, priceCents })),
  };
}
