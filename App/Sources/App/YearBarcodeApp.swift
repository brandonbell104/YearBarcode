import StripePaymentSheet
import SwiftUI

@main
struct YearBarcodeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.dark.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme((Appearance(rawValue: appearance) ?? .dark).colorScheme)
                .tint(Theme.accent)
                .task { await model.onLaunch() }
                // Bank and wallet payments return here after leaving the app.
                .onOpenURL { url in _ = StripeAPI.handleURLCallback(with: url) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.onForeground() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.authorization.access == nil {
                WelcomeView()
            } else {
                NavigationStack(path: $model.path) {
                    YearsView()
                        .toolbarBackground(Theme.background, for: .navigationBar)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .progress(let id): JobProgressView(generationID: id)
                            case .artwork(let id): ArtworkView(generationID: id)
                            case .customize(let id): CustomizeView(generationID: id)
                            case .saved: SavedPostersView()
                            }
                        }
                }
            }
        }
        .alert("Year Barcode", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}
