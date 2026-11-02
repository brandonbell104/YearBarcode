# Year Barcode backlog

Status: `[ ]` to do · `[~]` in progress · `[x]` done

## App changes

### 1. [ ] Show photo counts when picking a year
- Years screen: each year in the picker shows how many photos it has, e.g. `2025 · 7,842 photos`.
- Count still images by capture year in the same pass that already lists years (`PhotoLibraryService.availableYears`), so it costs no extra library scan.
- This is the count *before* filtering (screenshots, documents, duplicates, and so on), so label it as "photos in library". The final "included" count after Generate can be lower. Add one line of help text saying so.

### 2. [ ] Every Photo: say when grouping starts
- Under the mode picker, show the selected size's limit and what will happen to the selected year:
  - "This 24 × 36 poster fits 4,860 photos as separate stripes. 2025 has 7,842, so some neighboring photos from the same day will be combined."
  - or "2025 has 3,100 photos, so every photo gets its own stripe."
- Limits (from the spec, floor(barcode length / 2)): 12 × 18 → 2,430 · 18 × 24 → 3,240 · 24 × 36 → 4,860. Read them from `PosterLayout.maxGroups` instead of hard-coding them.
- Use the same wording on the Artwork screen's Layout section, where the included count is already known exactly.
- Every Day help text stays as it is (one stripe per day; empty days white).

### 3. [ ] Buy a print tab
Goal: order a physical poster of the finished artwork from inside the app.

Constraints:
- Physical goods must **not** use Apple In-App Purchase; Apple requires a regular payment method for them (App Review Guideline 3.1.3(e)/3.1.5). So the print order needs its own checkout (Stripe, Apple Pay through Stripe, or the print partner's checkout).
- Sends only the finished PNG, and only after the user taps Order. The source photo library is never uploaded. The privacy text and App Store privacy label must mention that the artwork is uploaded for print orders.
- Prints keep the white border, at the poster's exact size (12 × 18, 18 × 24, 24 × 36). Some partners may need bleed added.

Recommended approach:
- **Print partner with an API:** Prodigi or Printful. Both print and ship giclée/poster sizes worldwide, and both accept an image URL plus an order.
- **Small backend:** one serverless function, e.g. a Supabase Edge Function like the one in the airtistic project. It (a) gives the app a one-time upload URL for the PNG, (b) creates a Stripe Checkout session with the price, shipping and tax, and (c) on payment, sends the order to the partner. The partner and Stripe keys stay on the server and never ship in the app.
- **App:** a new "Prints" tab. Pick a saved artwork, pick size and paper/frame, see the price, tap Order. The full PNG is created and uploaded, then Stripe Checkout opens with Apple Pay available. A confirmation screen and order history (status pulled from the backend) follow.
- **Business setup (yours):** Stripe account, partner account, retail prices and margin, refund/reprint policy, shipping countries.

Decisions needed before building:
- [ ] Partner: Prodigi, Printful, or another
- [ ] Products: unframed poster only, or framed too; which papers
- [ ] Countries to ship to at launch
- [ ] Prices

## Publishing on the App Store

### Accounts and agreements
- [x] Apple Developer Program membership
- [x] App record in App Store Connect, bundle ID, TestFlight pipeline
- [ ] **Paid Applications agreement** signed, with banking and tax forms filled in (App Store Connect → Business). Required for the $1.99 watermark purchase.
- [ ] **EU trader status** declared (App Store Connect → Business), required to be listed in EU countries

### In-app purchase
- [ ] Create the Non-Consumable IAP `com.yearbarcode.app.removewatermark` (reference name, price tier, display name, description, review screenshot)
- [ ] Test purchase, restore, Ask to Buy and refund with a Sandbox account through TestFlight
- [ ] Submit the IAP **together with** the first app version

### App Store listing
- [ ] App name and subtitle (30 characters each)
- [ ] Description, keywords, promotional text
- [ ] Category (suggest Photo & Video; secondary Lifestyle)
- [ ] Screenshots: iPhone 6.9" set required (3–10 images). Suggest Welcome, Years, a finished poster landscape and portrait, Customize
- [ ] Optional app preview video
- [ ] Final app icon (the current icon is a generated placeholder)
- [ ] Support URL (a simple page or GitHub Pages site)
- [ ] Marketing URL (optional)
- [ ] Copyright line

### Privacy and compliance
- [ ] **Privacy policy URL** (required). It says photos are analyzed on the device and not uploaded, explains print-order uploads once item 3 ships, and covers purchases.
- [ ] **App Privacy questionnaire** ("nutrition label"): currently "Data Not Collected". This changes when print orders upload artwork and take shipping addresses.
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`): declare any required-reason APIs and confirm no tracking
- [ ] Age rating questionnaire (likely 4+)
- [x] Export compliance: no non-exempt encryption (set in Info.plist)
- [ ] Content rights: confirm the app has no third-party content

### App Review readiness
- [ ] Review notes explaining: photo access is used only to compute colors; processing is on the device; what Generate does; how to test the watermark purchase
- [ ] Remove placeholder IDs and strings; final bundle ID and display name
- [ ] Check the `processing` background mode is justified, or remove it if `BGContinuedProcessingTask` doesn't need it
- [ ] Graceful behavior with limited or denied photo access, an empty library, and iCloud-only photos offline (reviewers test these)
- [ ] No crashes on the review device. Test on the lowest-memory iPhone that supports iOS 26.

### Quality (from the spec's acceptance criteria)
- [ ] Device QA checklist in README (snapshot freeze, leap years, grouping, PNG sizes, interruptions, purchase/restore)
- [ ] Peak memory and battery during a 24 × 36 export
- [ ] Filter accuracy pass on a varied photo set; tune `FilterPolicy` thresholds
- [ ] Accessibility: VoiceOver labels, Dynamic Type on all screens

### Release
- [ ] Version 1.0 (build from the TestFlight workflow)
- [ ] Pricing (free download, $1.99 unlock) and availability by country
- [ ] Submit for review. Choose manual release so you control the launch date.

## Later
- [ ] TestFlight auto-renew: scheduled workflow run every ~60 days (only if needed)
- [ ] Android port (spec step 6)
