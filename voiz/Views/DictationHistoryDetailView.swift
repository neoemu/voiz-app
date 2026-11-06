import SwiftUI
import AVFoundation
import Combine

@MainActor
private final class DictationPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var message: String?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying { stop(); return }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self
            guard audio.play() else { throw CocoaError(.fileReadUnknown) }
            player = audio
            isPlaying = true
            message = nil
        } catch {
            message = String(localized: "Não foi possível abrir o áudio.")
        }
    }

    func stop() { player?.stop(); player = nil; isPlaying = false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.isPlaying = false }
    }
}

struct HomeTranscriptionDetailContent: View {
    let initialEntry: TranscriptionEntry
    @ObservedObject var viewModel: TranscriptionViewModel
    @ObservedObject private var history: TranscriptionHistoryStore
    @StateObject private var playback = DictationPlayback()

    init(entry: TranscriptionEntry, viewModel: TranscriptionViewModel) {
        initialEntry = entry
        self.viewModel = viewModel
        history = viewModel.historyStore
    }

    private var entry: TranscriptionEntry { history.entries.first { $0.id == initialEntry.id } ?? initialEntry }
    private var isProcessing: Bool { viewModel.processingEntryID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.displayTitle)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundStyle(VoizTheme.primaryText)
                    .lineLimit(3)
                // The engine name is a detail for the curious; it lives in the tooltip.
                Text("\(entry.formattedDate) • \(entry.language.displayName)")
                    .font(.system(size: 13))
                    .foregroundStyle(VoizTheme.mutedText)
                    .help(Text(verbatim: engineName ?? ""))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            if isProcessing {
                ProgressView("Transcrevendo o áudio salvo…")
                    .font(.system(size: 13))
            } else if let message = entry.processingMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(VoizTheme.mutedText)
            }
            if let message = playback.message {
                Text(message).font(.system(size: 13)).foregroundStyle(.orange)
            }
            if let message = history.storageError {
                Text(message).font(.system(size: 13)).foregroundStyle(.orange)
            }
            HomeDetailSection(title: "Texto") { transcript(entry.text) }
            if let raw = entry.rawText, raw != entry.text {
                DisclosureGroup("Texto reconhecido antes das correções") {
                    VStack(alignment: .leading, spacing: 10) {
                        transcript(raw)
                        Button("Copiar original") { copy(raw) }
                            .buttonStyle(GranolaPillButtonStyle())
                    }.padding(.top, 8)
                }
            }
            if let previous = entry.previousText, previous != entry.text {
                DisclosureGroup("Resultado anterior") {
                    VStack(alignment: .leading, spacing: 10) {
                        transcript(previous)
                        Button("Copiar resultado anterior") { copy(previous) }
                            .buttonStyle(GranolaPillButtonStyle())
                    }.padding(.top, 8)
                }
            }
        }
        .onDisappear { playback.stop() }
        .onChange(of: initialEntry.id) { _, _ in playback.stop() }
    }

    @ViewBuilder private var actions: some View {
        Button { copy(entry.text) } label: { Label("Copiar", systemImage: "doc.on.doc") }
            .buttonStyle(GranolaPillButtonStyle()).disabled(entry.text.isEmpty)
        if let id = entry.audioID, history.audioStore.exists(id) {
            Button { playback.toggle(history.audioStore.url(for: id)) } label: {
                Label(playback.isPlaying ? "Parar áudio" : "Ouvir áudio", systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(GranolaPillButtonStyle())
        }
        if viewModel.canRetranscribe(entry) {
            Button {
                playback.stop()
                Task { await viewModel.retranscribe(entry) }
            } label: { Label("Transcrever novamente", systemImage: "arrow.clockwise") }
                .help(Text("Usa o motor e o vocabulário atuais. O resultado anterior continua disponível."))
                .buttonStyle(GranolaPillButtonStyle())
                .disabled(viewModel.state == .listening || viewModel.state == .processing)
        }
    }

    private var engineName: String? {
        guard let provenance = entry.provenance else { return nil }
        return provenance.recognizer ?? TranscriptionCatalog.shipping.descriptor(for: provenance.engine)?.model(provenance.model)?.productName ?? provenance.model.rawValue
    }

    private func transcript(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(VoizTheme.primaryText)
            .textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
