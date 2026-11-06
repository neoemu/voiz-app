import SwiftUI
import Combine

struct RecordingHUDView: View {
    let state: RecordingHUDState
    
    @State private var phase: Double = 0
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
    
    var body: some View {
        // Design mais fino e compacto (WhisperFlow style)
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            
            // Barra de áudio minimalista
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2.5, height: indicatorHeight(for: index))
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.75))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .onReceive(timer) { _ in
            phase += 1
        }
    }
    
    private var title: String {
        switch state {
        case .listening:
            return String(localized: "Capturando áudio…")
        case .processing:
            return String(localized: "Processando…")
        }
    }
    
    private func indicatorHeight(for index: Int) -> CGFloat {
        // Animação mais sutil e fina
        let base: CGFloat = state == .processing ? 4 : 6
        let amplitude: CGFloat = state == .processing ? 2 : 10
        let value = sin((phase + Double(index)) * 0.7) * Double(amplitude)
        return base + CGFloat(value.magnitude)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        RecordingHUDView(state: .listening)
    }
}
