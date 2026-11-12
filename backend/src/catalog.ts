// Print products offered in the app: an unframed poster, a black-framed
// print and a stretched canvas, each in the three poster sizes.
//
// To confirm before launch:
//  * `prodigiSku` and `attributes`: the deploy's "Check Prodigi products"
//    step asks Prodigi whether each SKU exists, which attributes it needs,
//    and what it costs to make and ship.
//  * `priceCents`: retail price charged to the customer, shipping included.
//    Set it from Prodigi's cost + shipping + Stripe fees + margin.

export type ProductKind = "poster" | "framed" | "canvas";
export type PrintSize = "12x18" | "18x24" | "24x36";

export interface Product {
  id: string;
  kind: ProductKind;
  size: PrintSize;
  title: string;
  prodigiSku: string;
  /** Prodigi item attributes (frame colour, canvas edge wrap). */
  attributes: Record<string, string>;
  priceCents: number;
}

export const CURRENCY = "usd";

/** ISO country codes we ship to. */
export const SHIPPING_COUNTRIES = ["US"];

export const SIZES: PrintSize[] = ["12x18", "18x24", "24x36"];

const POSTER_PRICES: Record<PrintSize, number> = { "12x18": 3900, "18x24": 4900, "24x36": 6900 };
const FRAMED_PRICES: Record<PrintSize, number> = { "12x18": 9900, "18x24": 13900, "24x36": 18900 };
const CANVAS_PRICES: Record<PrintSize, number> = { "12x18": 7900, "18x24": 10900, "24x36": 14900 };

/** Prodigi SKUs per kind: matte art paper; classic frame with no mat (the whole
 *  poster shows; a mat would crop its edges); standard stretched canvas. */
export const SKU_PREFIX: Record<ProductKind, string> = { poster: "GLOBAL-FAP", framed: "GLOBAL-CFP", canvas: "GLOBAL-CAN" };
export const ATTRIBUTES: Record<ProductKind, Record<string, string>> = {
  poster: {},
  framed: { color: "black" },
  // Mirror wrap repeats the edge of the image around the sides, so nothing on
  // the front (like the title) gets folded around the frame.
  canvas: { wrap: "MirrorWrap" },
};

export const PRODUCTS: Product[] = SIZES.flatMap((size): Product[] => {
  const label = size.replace("x", " × ");
  return [
    {
      id: `poster-${size}`,
      kind: "poster",
      size,
      title: `${label} poster`,
      prodigiSku: `${SKU_PREFIX.poster}-${size.toUpperCase()}`,
      attributes: ATTRIBUTES.poster,
      priceCents: POSTER_PRICES[size],
    },
    {
      id: `framed-black-${size}`,
      kind: "framed",
      size,
      title: `${label} black frame`,
      prodigiSku: `${SKU_PREFIX.framed}-${size.toUpperCase()}`,
      attributes: ATTRIBUTES.framed,
      priceCents: FRAMED_PRICES[size],
    },
    {
      id: `canvas-${size}`,
      kind: "canvas",
      size,
      title: `${label} stretched canvas`,
      prodigiSku: `${SKU_PREFIX.canvas}-${size.toUpperCase()}`,
      attributes: ATTRIBUTES.canvas,
      priceCents: CANVAS_PRICES[size],
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
