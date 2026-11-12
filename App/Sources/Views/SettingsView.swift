import SwiftUI
import YearBarcodeCore

/// Purchases and appearance, opened from the gear on the Years screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.dark.rawValue
    @State private var showingOrders = false

    var body: some View {
        let purchases = model.purchases
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Appearance")
                        PillSegmented(
                            options: Appearance.allCases.map { ($0.rawValue, $0.title) },
                            selection: $appearance
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Purchases")
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: purchases.isUnlocked ? "checkmark.seal.fill" : "star")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Remove Watermark").font(.system(size: 15, weight: .semibold))
                                    Text(purchases.isUnlocked ? "Purchased · every year and size" : "Not purchased · one-time purchase")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                .foregroundStyle(Theme.primaryText)
                                Spacer(minLength: 0)
                                if !purchases.isUnlocked {
                                    Button {
                                        Task { await purchases.purchase() }
                                    } label: {
                                        Group {
                                            if purchases.state == .purchasing {
                                                ProgressView().tint(Theme.background)
                                            } else {
                                                Text(purchases.displayPrice ?? "Buy")
                                            }
                                        }
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color(hex: 0x0A0A0B))
                                        .padding(.horizontal, 14)
                                        .frame(height: 36)
                                        .background(Theme.accent, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(purchases.state == .purchasing)
                                }
                            }
                            .padding(14)

                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)

                            Button {
                                Task { await purchases.restore() }
                            } label: {
                                HStack {
                                    Text("Restore Purchases")
                                    Spacer()
                                    if purchases.state == .purchasing { ProgressView() }
                                }
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.accent)
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(purchases.state == .purchasing)
                        }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))

                        if purchases.state == .pending {
                            Text("Purchase pending approval. The watermark is removed once it's approved.")
                                .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        }
                        if case .failed(let message) = purchases.state {
                            Text(message).font(.system(size: 13)).foregroundStyle(Theme.destructive)
                        }
                        Text("Purchases are tied to your Apple Account. Restore brings them back on a new or reset iPhone.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Prints")
                        Button { showingOrders = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
                                Text("Print Orders").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
                            }
                            .padding(14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Privacy")
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock").foregroundStyle(Theme.primaryText)
                            Text("Your photos are analyzed on your iPhone. Your photo library is never uploaded; only a poster you order as a print is sent, to print it.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.bodyText)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Text(versionLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .sheet(isPresented: $showingOrders) { PrintOrdersView() }
        .preferredColorScheme((Appearance(rawValue: appearance) ?? .dark).colorScheme)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Year Barcode \(version) (\(build))"
    }
}
