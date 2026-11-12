import Foundation
import YearBarcodeCore

// Talks to the print-order server (backend/, a Cloudflare Worker). The server
// creates the Stripe payment, stores the poster file, and sends paid orders to
// Prodigi for printing and shipping.

enum PrintKind: String, Codable, CaseIterable, Hashable, Sendable {
    case poster, framed, canvas

    var title: String {
        switch self {
        case .poster: return "Poster"
        case .framed: return "Black Frame"
        case .canvas: return "Canvas"
        }
    }

    var detail: String {
        switch self {
        case .poster: return "Matte fine art paper, shipped rolled in a tube."
        case .framed: return "Black wood frame, acrylic glazing, no mat, ready to hang."
        case .canvas: return "Stretched on a 1.5 in (38 mm) wooden frame, mirrored edges, ready to hang."
        }
    }
}

struct PrintProduct: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: PrintKind
    /// "12x18", "18x24" or "24x36".
    var size: String
    var title: String
    var priceCents: Int
}

struct PrintCatalog: Codable, Sendable {
    var currency: String
    var countries: [String]
    var products: [PrintProduct]

    func product(_ kind: PrintKind, _ size: PrintSize) -> PrintProduct? {
        products.first { $0.kind == kind && $0.size == size.catalogKey }
    }
}

extension PrintSize {
    /// The order server's name for this size.
    var catalogKey: String { "\(shortInches)x\(longInches)" }
}

struct ShippingAddress: Codable, Equatable, Sendable {
    var name = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = "US"

    var isComplete: Bool {
        ![name, line1, city, state, postalCode].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

struct CreatedOrder: Codable, Sendable {
    var orderId: String
    var clientSecret: String
    var uploadToken: String
    var amount: Int
    var currency: String
}

struct OrderStatus: Codable, Sendable {
    struct Shipment: Codable, Hashable, Sendable {
        var carrier: String?
        var trackingNumber: String?
        var trackingUrl: String?
        var status: String?
    }

    var orderId: String
    /// Stripe PaymentIntent status, e.g. "succeeded" or "requires_payment_method".
    var payment: String
    var product: String?
    var imageReceived: Bool
    /// Prodigi stage: "InProgress", "Complete", "Cancelled"… or "Submitting".
    var printStage: String?
    var shipments: [Shipment]
    var problem: String?

    /// One line for the order list.
    var summary: String {
        if problem != nil { return "Needs attention: contact support" }
        if payment != "succeeded" { return payment == "processing" ? "Payment processing" : "Not paid" }
        if let shipped = shipments.first, shipped.trackingNumber != nil { return "Shipped" }
        switch printStage {
        case "Complete": return "Shipped"
        case "Cancelled": return "Cancelled"
        case "InProgress": return "Printing"
        default: return "Paid · sending to the printer"
        }
    }
}

/// An order placed from this iPhone, kept so its status can be checked later.
struct SavedOrder: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var uploadToken: String
    var productTitle: String
    var posterTitle: String
    var amount: Int
    var createdAt: Date
}

enum OrderError: LocalizedError {
    case server(String)
    case network

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .network: return "Couldn't reach the print service. Check your connection and try again."
        }
    }
}

final class OrderService: Sendable {
    static let shared = OrderService()

    static let baseURL = URL(string: "https://year-barcode-orders.brandonbell104.workers.dev")!

    /// The secure payment page (Stripe's Payment Element) for an order. The
    /// token travels in the fragment, which browsers never send to servers.
    static func paymentPageURL(orderID: String, token: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/pay"), resolvingAgainstBaseURL: false)!
        components.fragment = "order=\(orderID)&token=\(token)"
        return components.url!
    }

    private let decoder = JSONDecoder()

    func catalog() async throws -> PrintCatalog {
        try await send(URLRequest(url: Self.baseURL.appendingPathComponent("v1/catalog")))
    }

    func createOrder(productID: String, email: String, address: ShippingAddress) async throws -> CreatedOrder {
        struct Body: Encodable {
            var productId: String
            var email: String
            var recipient: ShippingAddress
        }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/orders"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var cleaned = address
        cleaned.state = cleaned.state.trimmingCharacters(in: .whitespaces).uppercased()
        request.httpBody = try JSONEncoder().encode(Body(productId: productID, email: email, recipient: cleaned))
        return try await send(request)
    }

    /// Streams the poster PNG from disk to the order.
    func uploadImage(orderID: String, token: String, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/orders/\(orderID)/image"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let delegate = UploadProgress(progress)
        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate)
        } catch {
            throw OrderError.network
        }
        try check(data, response)
    }

    func status(of order: SavedOrder) async throws -> OrderStatus {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/orders/\(order.id)"))
        request.setValue("Bearer \(order.uploadToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    // MARK: -

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OrderError.network
        }
        try check(data, response)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw OrderError.server("The print service sent an unexpected reply.")
        }
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OrderError.network }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { var error: String }
            let message = (try? decoder.decode(Failure.self, from: data))?.error
            throw OrderError.server(message ?? "The print service returned an error (\(http.statusCode)).")
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// Orders placed from this iPhone (IDs and their private status tokens).
enum OrderStore {
    private static let key = "printOrders"

    static func all() -> [SavedOrder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let orders = try? JSONDecoder().decode([SavedOrder].self, from: data) else { return [] }
        return orders.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ order: SavedOrder) {
        var orders = all().filter { $0.id != order.id }
        orders.append(order)
        if let data = try? JSONEncoder().encode(orders) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func remove(_ id: String) {
        let orders = all().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(orders) { UserDefaults.standard.set(data, forKey: key) }
    }
}

func formatPrice(_ cents: Int, currency: String = "usd") -> String {
    (Double(cents) / 100).formatted(.currency(code: currency.uppercased()))
}
