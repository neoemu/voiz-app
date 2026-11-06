import SwiftUI

/// Build metadata comes from the development bundle, never from a shell command at runtime.
struct DevelopmentBuildBadge: View {
    private let environment = AppEnvironment.current

    private var sourceTooltip: String {
        (["Voiz Dev", environment.buildSourceDescription] + [environment.buildSourcePath].compactMap { $0 })
            .joined(separator: "\n")
    }

    var body: some View {
        if environment.isDevelopment {
            HStack(spacing: 6) {
                Text(verbatim: "DEV")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .fixedSize()
                Text(verbatim: environment.buildSourceDescription)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(VoizTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.22)))
            .frame(maxWidth: 160, alignment: .trailing)
            .help(Text(verbatim: sourceTooltip))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Voiz Dev · \(environment.buildSourceDescription)"))
        }
    }
}
