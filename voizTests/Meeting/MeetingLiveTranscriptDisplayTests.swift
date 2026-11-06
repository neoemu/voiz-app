import Testing

@Suite("Transcript ao vivo — volátil por canal")
struct MeetingLiveTranscriptDisplayTests {

    @Test("Voláteis intercalados de canais diferentes não se sobrescrevem")
    func interleavedVolatilesKeepBothChannels() {
        var state = MeetingLiveVolatileState()

        state.apply(text: "fala do mic", channel: .microphone)
        state.apply(text: "fala do sistema", channel: .systemAudio)

        #expect(state.text(for: .microphone) == "fala do mic")
        #expect(
            state.text(for: .systemAudio) == "fala do sistema",
            "o defeito antigo (um único liveCurrentParagraph) apagaria o mic com o volátil do sistema"
        )

        state.apply(text: "mic de novo", channel: .microphone)
        #expect(state.text(for: .microphone) == "mic de novo")
        #expect(state.text(for: .systemAudio) == "fala do sistema")
    }

    @Test("Final de um canal não apaga o volátil do outro")
    func clearingOneChannelLeavesTheOther() {
        var state = MeetingLiveVolatileState()
        state.apply(text: "você", channel: .microphone)
        state.apply(text: "eles", channel: .systemAudio)
        state.clear(.microphone)

        #expect(state.text(for: .microphone).isEmpty)
        #expect(state.text(for: .systemAudio) == "eles")
    }

    @Test("Chegada fora de ordem rende feed ordenado por startTime")
    func outOfOrderArrivalSortsByStartTime() {
        let lateMic = MeetingLiveFeedEntry(
            text: "você",
            channel: .microphone,
            startTime: 4
        )
        let earlyThem = MeetingLiveFeedEntry(
            text: "eles",
            channel: .systemAudio,
            startTime: 1
        )
        var feed: [MeetingLiveFeedEntry] = []
        feed = MeetingLiveFeedEntry.inserting(lateMic, into: feed)
        feed = MeetingLiveFeedEntry.inserting(earlyThem, into: feed)
        #expect(feed.map(\.text) == ["eles", "você"])
        #expect(feed.map(\.channel) == [.systemAudio, .microphone])

        // O defeito: append por chegada deixaria [você, eles] e o transcript
        // final (ordenado por startTime) inverteria os canais.
        let arrivalOrder = [lateMic, earlyThem].map(\.text)
        #expect(arrivalOrder == ["você", "eles"])
        #expect(feed.map(\.text) != arrivalOrder)
    }

    @Test("Você à esquerda, Eles à direita")
    func youLeadsAndThemTrails() {
        #expect(MeetingLiveTranscriptSide.forChannel(.microphone) == .you)
        #expect(MeetingLiveTranscriptSide.forChannel(.systemAudio) == .them)
        #expect(MeetingLiveTranscriptSide.forChannel(nil) == .fill)

        // Convenção antiga (Você à direita) faria microphone.isLeading == false.
        #expect(MeetingLiveTranscriptSide.forChannel(.microphone).isLeading)
        #expect(MeetingLiveTranscriptSide.forChannel(.systemAudio).isLeading == false)
        #expect(MeetingLiveTranscriptSide.forChannel(nil).isLeading)
    }

}
