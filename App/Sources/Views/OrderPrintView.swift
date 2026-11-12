import AuthenticationServices
import SwiftUI
import YearBarcodeCore

/// Order a printed poster, framed print or canvas of the current artwork.
///
/// Steps: choose product and size → shipping → (create order, render the
/// full-resolution poster, upload it) → secure Stripe payment page in an
/// in-app browser sheet → confirmation. The app has no payment SDK and no
/// camera code; card details are entered on Stripe's page.
struct OrderPrintView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let session: ArtworkSession

    @State private var catalog: PrintCatalog?
    @State private var catalogError: String?
    @State private var kind: PrintKind = .framed
    @State private var size: PrintSize = .size18x24
    @AppStorage("printOrderEmail") private var email = ""
    @State private var address = ShippingAddress()

    private enum Phase: Equatable {
        case choosing
        case working(String, Double?)
        case readyToPay
        case paid
    }
    @State private var phase: Phase = .choosing
    @State private var errorMessage: String?
    @State private var order: CreatedOrder?
    @State private var showingOrders = false

    private var product: PrintProduct? { catalog?.product(kind, size) }
    private var locked: Bool { order != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if phase == .paid {
                        confirmation
                    } else {
                        preview
                        if let catalogError {
                            errorCard(catalogError) { Task { await loadCatalog() } }
                        } else if catalog == nil {
                            ProgressView().tint(Theme.tertiaryText).frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            productSection
                            shippingSection
                            Text("Price includes shipping within the US. Prints usually ship in 3–5 business days. You'll pay on Stripe's secure page; your card details never touch Year Barcode.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { if phase != .paid && catalog != nil { bottomBar } }
            .navigationTitle(phase == .paid ? "Order Placed" : "Order a Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .paid ? "Done" : "Close") { dismiss() }
                        .tint(Theme.accent)
                        .disabled(isWorking)
                }
            }
            .sheet(isPresented: $showingOrders) { PrintOrdersView() }
        }
        .interactiveDismissDisabled(isWorking)
        .task {
            size = session.artwork.settings.printSize
            await loadCatalog()
        }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    // MARK: - Sections

    private var preview: some View {
        let landscape = session.artwork.settings.orientation == .landscape
        let aspect = Double(size.longInches) / Double(size.shortInches)
        return ZStack {
            Theme.posterWell
            if let image = session.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    // Whole poster, never cropped: fit inside the box at the print's shape.
                    .aspectRatio(landscape ? aspect : 1 / aspect, contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 240)
                    .padding(kind == .framed ? 9 : 0)
                    .background(kind == .framed ? Color(hex: 0x111111) : .clear)
                    .overlay {
                        if kind == .canvas {
                            // A hint of the canvas's depth on the right and bottom edges.
                            Rectangle().strokeBorder(.black.opacity(0.18), lineWidth: 2)
                        }
                    }
                    .shadow(color: .black.opacity(kind == .poster ? 0.18 : 0.35), radius: kind == .poster ? 4 : 10, y: kind == .poster ? 2 : 6)
                    .padding(24)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var productSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Print", trailing: product.map { formatPrice($0.priceCents, currency: catalog?.currency ?? "usd") })
            PillSegmented(options: PrintKind.allCases.map { ($0, $0.title) }, selection: $kind)
            PillSegmented(options: PrintSize.allCases.map { ($0, $0.catalogKey.replacingOccurrences(of: "x", with: " × ")) }, selection: $size)
            Text(kind.detail + (size == session.artwork.settings.printSize ? "" : " The poster is redrawn at this size."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(locked)
        .opacity(locked ? 0.6 : 1)
    }

    private var shippingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Ship to (US only for now)")
            VStack(spacing: 0) {
                field("Full name", text: $address.name, content: .name)
                field("Address", text: $address.line1, content: .streetAddressLine1)
                field("Apt, suite (optional)", text: $address.line2, content: .streetAddressLine2)
                field("City", text: $address.city, content: .addressCity)
                HStack(spacing: 0) {
                    field("State", text: $address.state, content: .addressState)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    field("ZIP", text: $address.postalCode, content: .postalCode, keyboard: .numberPad)
                }
                field("Email for receipt and tracking", text: $email, content: .emailAddress, keyboard: .emailAddress, last: true)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(locked)
        .opacity(locked ? 0.6 : 1)
    }

    private func field(_ title: String, text: Binding<String>, content: UITextContentType, keyboard: UIKeyboardType = .default, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            TextField(title, text: text)
                .textContentType(content)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .autocorrectionDisabled()
                .font(.system(size: 16))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
            if !last { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch phase {
            case .working(let message, let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    if let fraction { ProgressView(value: fraction).tint(Theme.accent) } else { ProgressView().tint(Theme.accent) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            case .readyToPay:
                HStack(spacing: 10) {
                    Button("Start Over") { startOver() }
                        .buttonStyle(.secondary)
                        .frame(maxWidth: 130)
                    Button { Task { await pay() } } label: {
                        Label("Pay \(order.map { formatPrice($0.amount, currency: $0.currency) } ?? "")", systemImage: "creditcard")
                    }
                    .buttonStyle(.primary)
                }
            default:
                Button { Task { await placeOrder() } } label: {
                    Label("Continue to Payment · \(product.map { formatPrice($0.priceCents) } ?? "")", systemImage: "lock")
                }
                .buttonStyle(.primary)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.background.opacity(0.96).ignoresSafeArea())
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.success)
            Text("Thank you!")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Theme.primaryText)
            Text("Your \(product?.title ?? "print") is on its way to the printer. A receipt is coming to \(email). You can follow printing and shipping any time.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.bodyText)
            Button("View My Orders") { showingOrders = true }
                .buttonStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private func errorCard(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.system(size: 14)).foregroundStyle(Theme.bodyText)
            Button("Try Again", action: retry).buttonStyle(.secondary)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Flow

    private var emailValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && !trimmed.contains(" ")
    }

    private var canContinue: Bool { product != nil && address.isComplete && emailValid }

    private func loadCatalog() async {
        catalogError = nil
        do {
            catalog = try await OrderService.shared.catalog()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func placeOrder() async {
        guard let product else { return }
        errorMessage = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        do {
            phase = .working("Checking your order…", nil)
            let created = try await OrderService.shared.createOrder(productID: product.id, email: email, address: address)
            order = created
            OrderStore.save(SavedOrder(
                id: created.orderId, uploadToken: created.uploadToken, productTitle: product.title,
                posterTitle: session.report?.snapshot.title ?? "", amount: created.amount, createdAt: Date()
            ))

            phase = .working("Creating your full-resolution poster…", 0)
            let file = try await session.exportForPrint(size: size) { fraction in
                Task { @MainActor in if case .working(let m, _) = phase { phase = .working(m, fraction) } }
            }

            phase = .working("Sending it to the printer…", 0)
            try await OrderService.shared.uploadImage(orderID: created.orderId, token: created.uploadToken, file: file) { fraction in
                Task { @MainActor in if case .working(let m, _) = phase { phase = .working(m, fraction) } }
            }
            try? FileManager.default.removeItem(at: file)

            phase = .readyToPay
        } catch {
            errorMessage = error.localizedDescription
            // Nothing was paid: forget the half-made order and let them try again.
            if let order { OrderStore.remove(order.orderId) }
            order = nil
            phase = .choosing
            return
        }
        await pay()
    }

    /// Opens Stripe's payment page; afterwards asks the server whether it was paid.
    private func pay() async {
        guard let order else { return }
        errorMessage = nil
        do {
            _ = try await webAuthenticationSession.authenticate(
                using: OrderService.paymentPageURL(orderID: order.orderId, token: order.uploadToken),
                callbackURLScheme: "yearbarcode",
                preferredBrowserSession: .ephemeral
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed the page without paying; they can tap Pay again.
        } catch {
            errorMessage = "The payment page couldn't open. Try again."
        }
        await refreshPayment()
    }

    /// The page's own result is never trusted; the server says whether Stripe was paid.
    private func refreshPayment() async {
        guard let order else { return }
        phase = .working("Checking your payment…", nil)
        let saved = SavedOrder(id: order.orderId, uploadToken: order.uploadToken, productTitle: "", posterTitle: "", amount: order.amount, createdAt: Date())
        if let status = try? await OrderService.shared.status(of: saved),
           status.payment == "succeeded" || status.payment == "processing" {
            phase = .paid
        } else {
            phase = .readyToPay
        }
    }

    private func startOver() {
        if let order { OrderStore.remove(order.orderId) }
        order = nil
        errorMessage = nil
        phase = .choosing
    }
}

/// Orders placed from this iPhone, with live payment, printing and tracking status.
struct PrintOrdersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var orders = OrderStore.all()
    @State private var statuses: [String: OrderStatus] = [:]
    @State private var failed: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if orders.isEmpty {
                        Text("No print orders yet. Open a poster, tap Customize, then Order a Print.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 40)
                    }
                    ForEach(orders) { order in row(order) }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Print Orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(Theme.accent) }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func row(_ order: SavedOrder) -> some View {
        let status = statuses[order.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.productTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Spacer()
                Text(formatPrice(order.amount)).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            Text("\(order.posterTitle) · \(order.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Text(status?.summary ?? (failed.contains(order.id) ? "Couldn't load status" : "Loading…"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status?.problem != nil ? Theme.destructive : Theme.accent)
            ForEach(status?.shipments ?? [], id: \.self) { shipment in
                if let link = shipment.trackingUrl.flatMap(URL.init(string:)) {
                    Button("Track \(shipment.carrier ?? "package") \(shipment.trackingNumber ?? "")") { openURL(link) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func load() async {
        orders = OrderStore.all()
        for order in orders {
            if let status = try? await OrderService.shared.status(of: order) {
                statuses[order.id] = status
                failed.remove(order.id)
            } else {
                failed.insert(order.id)
            }
        }
    }
}
