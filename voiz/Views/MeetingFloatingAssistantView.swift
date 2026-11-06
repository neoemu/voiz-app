import SwiftUI

struct MeetingFloatingAssistantView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let onCollapse: () -> Void
    @State private var tab = 0
    @State private var notesCollapsed = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(viewModel.meetingPaused ? Color.orange : Color.red).frame(width: 7, height: 7)
                Text(viewModel.activeSession?.title ?? "Voiz").font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: viewModel.toggleMeetingPause) {
                    Image(systemName: viewModel.meetingPaused ? "play.fill" : "pause.fill")
                }.help(viewModel.meetingPaused ? "Retomar" : "Pausar")
                Button(action: viewModel.toggleRecording) { Image(systemName: "stop.fill") }.help("Parar gravação")
                Button(action: onCollapse) { Image(systemName: "rectangle.compress.vertical") }.help("Recolher assistente")
            }.buttonStyle(.plain)
            Picker("Painel", selection: $tab) {
                Text("Notas").tag(0)
                Text("Perguntar").tag(1)
                Text("Transcrição").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                switch tab {
                case 0: MeetingLiveNotes(collapsed: $notesCollapsed)
                case 1:
                    if viewModel.liveMeetingAssistantAvailable {
                        MeetingLiveAssistCard()
                    } else {
                        ContentUnavailableView("Assistência durante a gravação", systemImage: "sparkles",
                            description: Text("Disponível no modo Ao vivo."))
                    }
                default:
                    if viewModel.liveTranscriptCardVisible {
                        MeetingLivePreviewCard()
                    } else {
                        ContentUnavailableView("Transcrição após a reunião", systemImage: "waveform", description: Text("A transcrição fica pronta ao encerrar."))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VoizTheme.appBackground)
    }
}
