import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            BarcodeMark()
                .frame(height: 120)
                .padding(.horizontal, 40)
            VStack(spacing: 12) {
                Text("Your year, in color")
                    .font(.largeTitle.bold())
                Text("Year Barcode turns the average color of every photo you took in a year into printable barcode art.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Label {
                Text("Your photos are analyzed on your phone. We do not upload your photo library.")
            } icon: {
                Image(systemName: "lock.iphone")
            }
            .font(.callout)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            if model.authorization == .denied {
                Text("Photo access is turned off. Allow access in Settings to continue. Full access is recommended; with limited access only the photos you choose are included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Text("Full library access is recommended. Limited access works, but only the photos you allow will be included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.requestAccess() }
                } label: {
                    Text("Allow Photo Access").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}

/// Decorative barcode used on the welcome screen.
struct BarcodeMark: View {
    private let colors: [Color] = (0..<36).map { i in
        Color(hue: Double(i) / 36 * 0.85, saturation: 0.55, brightness: 0.85)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { colors[$0] }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
