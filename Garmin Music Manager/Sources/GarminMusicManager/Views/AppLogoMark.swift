import SwiftUI

/// Simple vector mark for the window chrome (matches Resources/AppIcon.svg).
struct AppLogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .fill(Color(red: 0.0, green: 0.49, blue: 0.76))

            Circle()
                .stroke(Color.white, lineWidth: size * 0.05)
                .frame(width: size * 0.58, height: size * 0.58)

            Circle()
                .fill(Color.white)
                .frame(width: size * 0.03, height: size * 0.03)

            ZStack(alignment: .topLeading) {
                Ellipse()
                    .fill(Color.white)
                    .frame(width: size * 0.13, height: size * 0.10)
                    .offset(x: size * 0.17, y: size * 0.52)

                RoundedRectangle(cornerRadius: size * 0.015, style: .continuous)
                    .fill(Color.white)
                    .frame(width: size * 0.08, height: size * 0.28)
                    .offset(x: size * 0.29, y: size * 0.24)

                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.08, height: size * 0.08)
                    .offset(x: size * 0.33, y: size * 0.20)

                Path { path in
                    let baseX = size * 0.50
                    let baseY = size * 0.34
                    let edge = size * 0.14
                    path.move(to: CGPoint(x: baseX, y: baseY))
                    path.addLine(to: CGPoint(x: baseX, y: baseY + edge))
                    path.addLine(to: CGPoint(x: baseX + edge * 0.75, y: baseY + edge * 0.5))
                    path.closeSubpath()
                }
                .fill(Color.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
