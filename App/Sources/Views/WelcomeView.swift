import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private let heroColors = DecorativeStripes.colors(160, seed: 11)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            VStack(alignment: .leading, spacing: 10) {
                Text("YEAR BARCODE")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.accent)
                Text("Your year,\nin color.")
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-1.2)
                    .lineSpacing(-4)
                    .foregroundStyle(Theme.primaryText)
                Text("Every photo becomes one stripe of its average color. A whole year becomes art you can print.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
            .padding(.top, 36)

            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text("Analyzed on your iPhone. Your photo library is never uploaded.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.bodyText)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 22)

            Spacer(minLength: 20)

            if model.authorization == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.primary)
                Text("Photo access is turned off. Allow it in Settings to continue.")
                    .footnoteStyle()
            } else {
                Button("Allow Photo Access") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(.primary)
                Text("Full access recommended. With limited access, only the photos you choose are included.")
                    .footnoteStyle()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    private var hero: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(Calendar.current.component(.year, from: Date()) - 1))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(2.3)
                    .foregroundStyle(Color(hex: 0x1D1D1F))
                Spacer()
                Text("One stripe per photo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x5E5E63))
            }
            StripesView(colors: heroColors)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                ForEach(["JAN", "APR", "JUL", "OCT", "DEC"], id: \.self) { month in
                    Text(month)
                    if month != "DEC" { Spacer() }
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color(hex: 0x5E5E63))
        }
        .padding(EdgeInsets(top: 26, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 30)
        .accessibilityHidden(true)
    }
}

private extension Text {
    func footnoteStyle() -> some View {
        self.font(.system(size: 13))
            .foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, 12)
    }
}
