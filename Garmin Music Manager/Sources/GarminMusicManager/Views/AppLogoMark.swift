import SwiftUI

/// Bundled logo mark for the window chrome.
struct AppLogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("AppLogo", bundle: .module)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
