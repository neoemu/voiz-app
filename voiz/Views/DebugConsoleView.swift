import SwiftUI

struct DebugConsoleSection: View {
    @EnvironmentObject var viewModel: TranslationViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console de Debug")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Limpar") {
                    viewModel.debugLogs.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.blue)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.debugLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logColor(for: log))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(8)
            .background(Color.black.opacity(0.05))
            .cornerRadius(8)
            
            HStack(spacing: 16) {
                StatCard(
                    title: "Modelo",
                    value: modelShortName,
                    color: modelColor
                )
                
                if viewModel.lastTranslationLatency > 0 {
                    StatCard(
                        title: "Latência",
                        value: "\(Int(viewModel.lastTranslationLatency * 1000))ms",
                        color: latencyColor
                    )
                }
                
                StatCard(
                    title: "Status",
                    value: statusText,
                    color: statusColor
                )
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("❌") {
            return .red
        } else if log.contains("✅") {
            return .green
        } else if log.contains("⚠️") {
            return .orange
        } else if log.contains("🌐") || log.contains("📡") {
            return .blue
        } else {
            return .primary
        }
    }
    
    private var latencyColor: Color {
        if viewModel.lastTranslationLatency < 0.5 {
            return .green
        } else if viewModel.lastTranslationLatency < 1.0 {
            return .orange
        } else {
            return .red
        }
    }
    
    private var statusText: String {
        switch viewModel.state {
        case .idle: return String(localized: "Parado")
        case .listening: return String(localized: "Gravando")
        case .processing: return String(localized: "Processando")
        case .error: return String(localized: "Erro")
        }
    }
    
    private var statusColor: Color {
        switch viewModel.state {
        case .idle: return .secondary
        case .listening: return .green
        case .processing: return .orange
        case .error: return .red
        }
    }
    
    private var modelShortName: String {
        switch viewModel.settings.translationModel {
        case .gpt56Luna: return "5.6 Luna"
        case .gpt56Terra: return "5.6 Terra"
        case .gpt56Sol: return "5.6 Sol"
        case .gpt6Astra: return "6 Astra"
        }
    }
    
    private var modelColor: Color {
        switch viewModel.settings.translationModel {
        case .gpt56Luna: return .blue
        case .gpt56Terra: return .teal
        case .gpt56Sol: return .green
        case .gpt6Astra: return .purple
        }
    }
}

struct StatCard: View {
    /// O valor pode ser modelo/latência dinâmica; o título é sempre um rótulo fixo do app.
    let title: LocalizedStringKey
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}
