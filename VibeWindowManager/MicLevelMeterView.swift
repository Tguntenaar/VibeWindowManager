//
//  MicLevelMeterView.swift
//  VibeWindowManager
//
//  Green-to-red loudness meter for the continuous mic passthrough received from the iOS app.
//  `level` is 0…1 (see VibeBridgeServer.passthroughLevel).
//

import SwiftUI

struct MicLevelMeterView: View {
    /// 0…1 loudness of the received audio.
    var level: Float
    /// Whether the phone is actively streaming; the bar dims when idle.
    var active: Bool

    private var clamped: CGFloat { CGFloat(min(max(level, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .orange, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // Gradient is sized to the full track so colors stay fixed; the bar reveals up to `level`.
                    .frame(width: width)
                    .mask(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .frame(width: max(2, width * clamped))
                    }
                    .opacity(active ? 1 : 0.35)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .animation(.linear(duration: 0.08), value: clamped)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}

#Preview {
    VStack(spacing: 16) {
        MicLevelMeterView(level: 0.2, active: true)
        MicLevelMeterView(level: 0.6, active: true)
        MicLevelMeterView(level: 0.95, active: true)
        MicLevelMeterView(level: 0.5, active: false)
    }
    .frame(height: 28)
    .padding()
}
