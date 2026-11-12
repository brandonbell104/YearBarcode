// The payment page the app opens in a secure in-app browser sheet
// (ASWebAuthenticationSession). It uses Stripe's Payment Element, so the app
// itself carries no payment SDK (and no camera code).
//
// The app opens  /v1/pay#order=<id>&token=<upload token>
// The page loads the order's client secret from /v1/orders/<id>/payment,
// confirms the payment, then hands control back with
//   yearbarcode://payment?order=<id>&status=<succeeded|processing|failed>
// The app never trusts that status; it asks the server for the order's state.

const STYLE = `
  :root { color-scheme: light dark; --bg:#0a0a0b; --card:#161618; --text:#f5f5f7; --muted:#a1a1a6; --accent:#ff9f0a; --error:#ff6961; }
  @media (prefers-color-scheme: light) { :root { --bg:#f2f2f7; --card:#fff; --text:#1c1c1e; --muted:#6e6e73; --accent:#f28c00; --error:#e5372c; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  main { max-width:480px; margin:0 auto; padding:24px 16px 40px; }
  h1 { font-size:24px; margin:0 0 4px; letter-spacing:-0.4px; }
  .muted { color:var(--muted); font-size:14px; }
  .card { background:var(--card); border-radius:16px; padding:16px; margin:18px 0; }
  button { width:100%; height:52px; border:0; border-radius:14px; background:var(--accent); color:#0a0a0b; font-size:17px; font-weight:700; }
  button:disabled { opacity:0.5; }
  #error { color:var(--error); font-size:14px; min-height:20px; margin:10px 0; }
`;

export function payPage(publishableKey: string): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Pay for your print · Year Barcode</title>
<style>${STYLE}</style>
<script src="https://js.stripe.com/v3/"></script>
</head><body><main>
  <h1 id="title">Pay for your print</h1>
  <div class="muted" id="subtitle">Loading your order…</div>
  <form id="form" class="card" hidden>
    <div id="payment-element"></div>
  </form>
  <div id="error" role="alert"></div>
  <button id="pay" form="form" type="submit" disabled>Pay</button>
  <p class="muted">Payments are processed by Stripe. Year Barcode never sees your card details.</p>
</main>
<script>
(async () => {
  const params = new URLSearchParams(location.hash.slice(1));
  const order = params.get("order"), token = params.get("token");
  const errorBox = document.getElementById("error"), button = document.getElementById("pay");
  const back = (status) => { location.href = "yearbarcode://payment?order=" + encodeURIComponent(order) + "&status=" + status; };
  const fail = (message) => { errorBox.textContent = message; };
  if (!order || !token) return fail("This payment link is incomplete. Close this page and try again.");

  let info;
  try {
    const response = await fetch("/v1/orders/" + encodeURIComponent(order) + "/payment", { headers: { Authorization: "Bearer " + token } });
    info = await response.json();
    if (!response.ok) return fail(info.error || "This order can't be paid right now.");
  } catch { return fail("Couldn't reach the payment service. Check your connection."); }
  if (info.status === "succeeded" || info.status === "processing") return back(info.status);

  const price = new Intl.NumberFormat("en-US", { style: "currency", currency: info.currency.toUpperCase() }).format(info.amount / 100);
  document.getElementById("subtitle").textContent = (info.product || "Print") + " · " + price + " · shipping included";
  button.textContent = "Pay " + price;

  const stripe = Stripe(${JSON.stringify(publishableKey)});
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  const elements = stripe.elements({ clientSecret: info.clientSecret, appearance: { theme: dark ? "night" : "stripe", variables: { colorPrimary: dark ? "#ff9f0a" : "#f28c00", borderRadius: "12px" } } });
  const paymentElement = elements.create("payment", { layout: "tabs", defaultValues: { billingDetails: { email: info.email || undefined, name: info.name || undefined } } });
  paymentElement.mount("#payment-element");
  document.getElementById("form").hidden = false;
  paymentElement.on("ready", () => { button.disabled = false; });

  document.getElementById("form").addEventListener("submit", async (event) => {
    event.preventDefault();
    button.disabled = true;
    errorBox.textContent = "";
    const { error, paymentIntent } = await stripe.confirmPayment({
      elements,
      confirmParams: { return_url: location.origin + "/v1/pay/return" },
      redirect: "if_required",
    });
    if (error) { fail(error.message || "The payment didn't go through."); button.disabled = false; return; }
    back(paymentIntent.status === "succeeded" || paymentIntent.status === "processing" ? paymentIntent.status : "failed");
  });
})();
</script>
</body></html>`;
}

/** Where Stripe sends the buyer back after a redirect-based payment method (bank, wallet). */
export function returnPage(): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Returning to Year Barcode</title>
<style>${STYLE}</style>
</head><body><main>
  <h1>Returning to Year Barcode…</h1>
  <p class="muted">If nothing happens, close this page.</p>
</main>
<script>
  const q = new URLSearchParams(location.search);
  const status = q.get("redirect_status") === "succeeded" ? "succeeded" : (q.get("redirect_status") || "failed");
  location.href = "yearbarcode://payment?order=" + encodeURIComponent(q.get("payment_intent") || "") + "&status=" + status;
</script>
</body></html>`;
}
