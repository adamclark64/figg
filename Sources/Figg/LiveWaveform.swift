import FiggAudio
import SwiftUI

/// Two small scrolling level meters, "Me" (mic) and "Them" (system audio),
/// matching the transcript labels. Polls `LevelMeter` on a timeline instead
/// of publishing through `AppModel`, so only this view redraws.
///
/// Doubles as diagnostics: a flat "Them" row while people are talking means
/// the System Audio Recording permission is missing, well before the 30 s
/// silence banner fires.
struct LiveWaveform: View {
    @Environment(\.theme) private var theme
    let meter: LevelMeter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            let snapshot = meter.snapshot()
            VStack(alignment: .leading, spacing: 2) {
                row("Me", snapshot[.mic], help: "Your microphone")
                row("Them", snapshot[.system], help: "Audio playing on this Mac (the call). Flat while people talk means figg lacks System Audio Recording permission.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live audio levels")
    }

    private func row(_ label: String, _ bars: [Float]?, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.inkMuted)
                .frame(width: 30, alignment: .trailing)
            if let bars {
                Bars(levels: bars, color: theme.accent, floor: theme.line)
                    .frame(width: 120, height: 12)
            } else {
                Text("off")
                    .font(.caption2)
                    .foregroundStyle(theme.inkMuted)
                    .frame(width: 120, height: 12, alignment: .leading)
            }
        }
        .help(help)
    }
}

/// Centred vertical bars, newest on the right. Silent bars keep a hairline
/// so a running but quiet stream still reads as "on".
private struct Bars: View {
    let levels: [Float]
    let color: Color
    let floor: Color

    var body: some View {
        Canvas { ctx, size in
            guard !levels.isEmpty else { return }
            let step = size.width / CGFloat(levels.count)
            let barWidth = max(1, step * 0.6)
            for (i, level) in levels.enumerated() {
                let h = max(1, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * step + (step - barWidth) / 2,
                    y: (size.height - h) / 2,
                    width: barWidth,
                    height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(level > 0.02 ? color : floor))
            }
        }
    }
}
