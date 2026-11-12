import Foundation
import Observation
import Security
import StoreKit

/// One non-consumable purchase removes the watermark for all years and sizes.
///
/// Entitlement comes from StoreKit's verified transactions (cached by the OS
/// for offline use). A paid print order also unlocks it, as a thank-you; that
/// is recorded in the Keychain (only after the order server confirms payment),
/// so it survives reinstalling the app.
@MainActor
@Observable
final class PurchaseManager {
    static let removeWatermarkID = "com.yearbarcode.app.removewatermark"

    enum State: Equatable {
        case idle
        case purchasing
        case pending
        case failed(String)
    }

    private(set) var product: Product?
    /// Watermark removed: bought in the App Store, or included with a print order.
    var isUnlocked: Bool { storeUnlocked || unlockedByPrint }
    /// Unlocked through the App Store purchase.
    private(set) var storeUnlocked = false
    /// Unlocked because a print order was paid.
    private(set) var unlockedByPrint = PrintUnlock.isSet
    private(set) var state: State = .idle

    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlement()
        }
    }

    /// Localized store price, e.g. "$1.99"; the store decides the actual price.
    var displayPrice: String? { product?.displayPrice }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.removeWatermarkID]).first
    }

    /// Re-derives the unlock from verified, unrevoked transactions (handles refunds).
    func refreshEntitlement() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.removeWatermarkID && transaction.revocationDate == nil {
                unlocked = true
            }
        }
        storeUnlocked = unlocked
        if unlocked && state == .pending { state = .idle }
    }

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            state = .failed("The store is unavailable right now. Try again later.")
            return
        }
        state = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    state = .failed("The purchase could not be verified.")
                    return
                }
                await transaction.finish()
                await refreshEntitlement()
                state = .idle
            case .pending:
                // Ask to Buy or payment approval: unlock arrives via Transaction.updates.
                state = .pending
            case .userCancelled:
                state = .idle
            @unknown default:
                state = .idle
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called once the order server confirms a print order was paid.
    func unlockFromPrintOrder() {
        guard !unlockedByPrint else { return }
        PrintUnlock.set()
        unlockedByPrint = true
    }

    func restore() async {
        state = .purchasing
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            state = isUnlocked ? .idle : .failed("No previous purchase was found for this Apple Account.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = state { state = .idle }
    }
}

/// Keychain flag for "a print order was paid on this Apple Account's device".
enum PrintUnlock {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.yearbarcode.app") + ".printUnlock",
            kSecAttrAccount as String: "watermark",
        ]
    }

    static var isSet: Bool {
        var lookup = query
        lookup[kSecReturnData as String] = true
        return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
    }

    static func set() {
        var item = query
        item[kSecValueData as String] = Data("1".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
