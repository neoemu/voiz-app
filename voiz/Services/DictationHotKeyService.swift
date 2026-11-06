import AppKit
import Combine
import CoreGraphics
import Carbon.HIToolbox
import os

/// Motor de atalhos de ditado estilo Wispr Flow, baseado em **`CGEventTap`** (e não em Carbon).
///
/// Por que CGEventTap: o Carbon `RegisterEventHotKey` não enxerga a tecla **Fn/🌐** nem o **key-up**
/// — ambos necessários para "segurar pra falar". O event tap vê `keyDown`/`keyUp`/`flagsChanged`
/// globalmente (exige Acessibilidade, que o app já tem) e ainda permite **engolir** (swallow) a tecla
/// pra ela não disparar o emoji picker (Fn) nem digitar espaço (hands-free).
///
/// Dois gatilhos configuráveis:
/// - **Push-to-talk** (padrão: Fn): segura → grava; solta → para e cola.
/// - **Hands-free** (padrão: Fn+Espaço): toca → alterna gravar/parar.
///
/// Conflito Fn-only PTT × Fn+Espaço hands-free é resolvido por *takeover*: ao apertar Fn, o PTT começa;
/// se o Espaço completar o combo hands-free durante o mesmo Fn, a sessão é **reclassificada** para
/// hands-free (gravação contínua, sem cortar) e o soltar do Fn não para mais.
///
/// O estado interno (`mode`, teclas pressionadas, Fn físico) é **derivado de eventos**, e evento se
/// perde: o sistema desabilita o tap quando o callback demora (transcrição pesada no main thread),
/// e nesse intervalo um key-up some. Por isso o motor se reconcilia continuamente com a verdade —
/// a gravação real do app (`updateSessionActive`) e as flags que todo evento carrega — em vez de
/// confiar no que ele achava que estava valendo.
final class DictationHotKeyService: ObservableObject {
    static let shared = DictationHotKeyService()

    /// O event tap existe e está ativo? Espelhado nas Configurações para diagnóstico.
    @Published private(set) var isEngineActive = false
    /// Último motivo de o motor não estar funcionando (`nil` = tudo certo).
    @Published private(set) var lastIssue: String?

    /// Disparado ao engatar o push-to-talk (começar a gravar).
    var onPushToTalkStart: (() -> Void)?
    /// Disparado ao soltar o push-to-talk (parar e colar).
    var onPushToTalkStop: (() -> Void)?
    /// Disparado a cada toque do hands-free (alternar gravar/parar).
    var onHandsFreeToggle: (() -> Void)?

    private let log = Logger(subsystem: "com.rmb.voiz", category: "dictation-hotkey")

    private var pushToTalk: KeyboardShortcut = .fnPushToTalk
    private var handsFree: KeyboardShortcut = .fnSpaceHandsFree
    private var enabled = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    private enum Mode { case idle, pushToTalk, handsFree }
    private var mode: Mode = .idle

    private var pressedKeys = Set<UInt16>()
    private var lastPushToTalkSatisfied = false
    /// Estado da tecla **física** Fn/🌐 (keyCode 63). Distinto da *flag* `.maskSecondaryFn`, que as
    /// teclas de seta/nav/F também setam de tabela — por isso Cmd+Shift+Seta NÃO pode contar como Fn.
    private var physicalFnDown = false
    private var lastPhysicalFnDown = false

    /// Há gravação de ditado rolando *de verdade* (espelho de `TranscriptionViewModel.state`).
    private var sessionActive = false
    /// Instante do último callback emitido — janela de graça antes de reconciliar (o start/stop é
    /// despachado async pra main e o estado do app só muda depois).
    private var lastEmitAt: CFAbsoluteTime = 0

    private init() {}

    // MARK: - Configuração

    /// (Re)configura os gatilhos e liga/desliga o motor. Idempotente — pode ser chamado a cada
    /// mudança nas Configurações.
    func configure(pushToTalk: KeyboardShortcut, handsFree: KeyboardShortcut, enabled: Bool) {
        self.pushToTalk = pushToTalk
        self.handsFree = handsFree
        self.enabled = enabled

        if enabled {
            startTapIfNeeded()
            startWatchdog()
            // O tap pode já existir (reconfiguração): o `tick` é quem sabe se ele segue vivo.
            tick()
        } else {
            resetState()
            isEngineActive = false
            lastIssue = String(localized: "Atalhos de ditado desligados nas Configurações")
        }
    }

    /// Espelha o estado real de gravação do app. É a **fonte de verdade** contra a qual o motor se
    /// reconcilia — sem isso, uma gravação encerrada por fora (HUD, menu, erro) deixava o `mode`
    /// preso em `.handsFree` e matava o push-to-talk até o app reiniciar.
    func updateSessionActive(_ active: Bool) {
        sessionActive = active
        if active { mode = mode == .idle ? .handsFree : mode }
    }

    private func startTapIfNeeded() {
        guard eventTap == nil else { return }
        guard AccessibilityPermissionService.shared.isTrusted else {
            if lastIssue == nil {
                log.error("Sem permissão de Acessibilidade — event tap não criado")
            }
            isEngineActive = false
            lastIssue = String(localized: "Permissão de Acessibilidade ausente")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<DictationHotKeyService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Falha ao criar o CGEventTap (Acessibilidade revogada?)")
            isEngineActive = false
            lastIssue = String(localized: "Falha ao criar o event tap (reconceda a Acessibilidade)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isEngineActive = true
        lastIssue = nil
        log.info("CGEventTap de ditado criado e ativo")
    }

    /// Vigia periódica: o tap morre calado (timeout do sistema quando o main thread trava na
    /// transcrição, ou Acessibilidade revogada) e antes disso ninguém percebia — os atalhos
    /// simplesmente paravam de responder até reiniciar o app.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func tick() {
        guard enabled else { return }

        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.error("Event tap estava desabilitado — reabilitando")
                CGEvent.tapEnable(tap: tap, enable: true)
                resetState()
            }
            let active = CGEvent.tapIsEnabled(tap: tap)
            if active != isEngineActive { isEngineActive = active }
            if active { lastIssue = nil }
        } else {
            // Acessibilidade pode ter sido concedida depois do launch: tenta de novo.
            startTapIfNeeded()
        }

        reconcileModeWithSession()
    }

    /// Se o motor acha que uma sessão está rolando mas o app não está gravando, volta pra `idle`.
    /// Sem isso o `mode` ficava preso e o push-to-talk (que só engata a partir de `.idle`) morria.
    private func reconcileModeWithSession() {
        guard mode != .idle, !sessionActive else { return }
        guard CFAbsoluteTimeGetCurrent() - lastEmitAt > 0.6 else { return }
        log.info("Sessão encerrada fora do atalho — motor volta pra idle")
        mode = .idle
    }

    private func resetState() {
        pressedKeys.removeAll()
        lastPushToTalkSatisfied = false
        physicalFnDown = false
        lastPhysicalFnDown = false
        // Se há gravação rolando, é o estado de *teclado* que virou lixo, não a sessão: mantém como
        // mãos livres. Zerar pra `.idle` faria o próximo toque no push-to-talk parar a gravação alheia.
        mode = sessionActive ? .handsFree : .idle
    }

    // MARK: - Núcleo do tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // O sistema desabilita o tap se ele demorar demais; reabilita. Os eventos do intervalo foram
        // perdidos, então tudo que era estado de tecla virou lixo — zera antes de continuar, senão um
        // key-up faltante deixa o Fn "preso" e todos os atalhos passam a se comportar de forma errática.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("Event tap desabilitado pelo sistema — reabilitando e zerando estado")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            resetState()
            return Unmanaged.passUnretained(event)
        }

        guard enabled else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Só a tecla **física** Fn/🌐 gera um flagsChanged com keyCode 63. As setas/nav/F-keys carregam
        // a flag `.maskSecondaryFn` no próprio keyDown delas, mas não disparam esse flagsChanged —
        // então rastrear por keyCode isola o Fn de verdade.
        if type == .flagsChanged && keyCode == UInt16(kVK_Function) {
            physicalFnDown = flags.contains(.maskSecondaryFn)
        } else if physicalFnDown && !flags.contains(.maskSecondaryFn) {
            // Todo evento carrega as flags do momento. Setas/F-keys ADICIONAM `.maskSecondaryFn` sem o
            // Fn estar apertado, mas nada a REMOVE indevidamente — logo, a ausência é prova de que o Fn
            // subiu. Conserta o "Fn preso" quando o flagsChanged de soltura se perdeu.
            physicalFnDown = false
        }

        // Mantém o conjunto de teclas pressionadas (para chords com tecla normal).
        switch type {
        case .keyDown: pressedKeys.insert(keyCode)
        case .keyUp: pressedKeys.remove(keyCode)
        default: break
        }

        // Antes de decidir qualquer coisa, alinha o motor com a gravação real do app.
        reconcileModeWithSession()

        // --- Push-to-talk (nível: enquanto o chord estiver satisfeito) ---
        let ptSatisfied = chordHeld(pushToTalk, flags: flags)
        if ptSatisfied && !lastPushToTalkSatisfied && mode == .idle && !sessionActive {
            mode = .pushToTalk
            emit { self.onPushToTalkStart?() }
        } else if !ptSatisfied && lastPushToTalkSatisfied && mode == .pushToTalk {
            mode = .idle
            emit { self.onPushToTalkStop?() }
        }
        lastPushToTalkSatisfied = ptSatisfied

        // --- Hands-free (borda: ativação discreta do combo) ---
        if isHandsFreeActivation(type: type, keyCode: keyCode, autorepeat: autorepeat, flags: flags) {
            switch mode {
            case .handsFree:
                mode = .idle
                emit { self.onHandsFreeToggle?() }   // desliga (para + cola)
            case .pushToTalk where sessionActive || justStartedPushToTalk:
                // Takeover: a gravação que o PTT começou vira hands-free, sem cortar.
                mode = .handsFree
                log.info("Push-to-talk reclassificado como mãos livres")
            case .pushToTalk, .idle:
                // Sem gravação de fato rolando (o PTT não engatou), então isto é uma ativação normal.
                mode = .handsFree
                emit { self.onHandsFreeToggle?() }   // liga (começa a gravar)
            }
        }

        lastPhysicalFnDown = physicalFnDown

        return shouldSwallow(type: type, keyCode: keyCode, flags: flags)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func emit(_ block: @escaping () -> Void) {
        lastEmitAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async(execute: block)
    }

    /// O start acabou de ser emitido e o app ainda não reportou a gravação? Dentro dessa janela o
    /// `sessionActive` ainda é `false` mesmo estando tudo certo — não dá pra concluir que falhou.
    private var justStartedPushToTalk: Bool {
        CFAbsoluteTimeGetCurrent() - lastEmitAt < 0.6
    }

    // MARK: - Matching de chord

    /// O chord está "segurado" agora? (modificadores + Fn satisfeitos e, se houver tecla, ela pressionada)
    private func chordHeld(_ sc: KeyboardShortcut, flags: CGEventFlags) -> Bool {
        guard sc.usesFn || sc.modifiers != 0 || sc.hasKey else { return false }
        guard chordModifiersSatisfied(sc, flags: flags) else { return false }
        if sc.hasKey {
            return pressedKeys.contains(sc.keyCode)
        }
        return true
    }

    /// Só os modificadores/Fn do chord (ignora a tecla normal). Usa o estado **físico** do Fn —
    /// não a flag `.maskSecondaryFn`, que as setas/nav setam de tabela.
    private func chordModifiersSatisfied(_ sc: KeyboardShortcut, flags: CGEventFlags) -> Bool {
        if sc.usesFn && !physicalFnDown { return false }
        let m = sc.modifiers
        if (m & UInt32(cmdKey)) != 0 && !flags.contains(.maskCommand) { return false }
        if (m & UInt32(optionKey)) != 0 && !flags.contains(.maskAlternate) { return false }
        if (m & UInt32(controlKey)) != 0 && !flags.contains(.maskControl) { return false }
        if (m & UInt32(shiftKey)) != 0 && !flags.contains(.maskShift) { return false }
        return true
    }

    /// É o instante de ativação do hands-free? (keyDown da tecla com mods/Fn ok, ou Fn subindo se for Fn-only)
    private func isHandsFreeActivation(
        type: CGEventType,
        keyCode: UInt16,
        autorepeat: Bool,
        flags: CGEventFlags
    ) -> Bool {
        guard handsFree.usesFn || handsFree.modifiers != 0 || handsFree.hasKey else { return false }
        guard chordModifiersSatisfied(handsFree, flags: flags) else { return false }

        if handsFree.hasKey {
            return type == .keyDown && !autorepeat && keyCode == handsFree.keyCode
        } else {
            // Fn-only (ou modificador-only) hands-free: ativa na subida da tecla física Fn.
            return type == .flagsChanged && keyCode == UInt16(kVK_Function) && physicalFnDown && !lastPhysicalFnDown
        }
    }

    // MARK: - Swallow

    /// Engole o evento quando ele pertence a um chord configurado, pra não disparar emoji (Fn) nem
    /// digitar espaço (hands-free). Fora dos chords, deixa passar.
    private func shouldSwallow(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        // Tecla do hands-free enquanto os modificadores/Fn dele estão satisfeitos.
        if handsFree.hasKey,
           (type == .keyDown || type == .keyUp),
           keyCode == handsFree.keyCode,
           chordModifiersSatisfied(handsFree, flags: flags) {
            return true
        }
        // Tecla do push-to-talk (quando ele tem tecla, ex.: ⌥Espaço).
        if pushToTalk.hasKey,
           (type == .keyDown || type == .keyUp),
           keyCode == pushToTalk.keyCode,
           chordModifiersSatisfied(pushToTalk, flags: flags) {
            return true
        }
        // Fn sozinho do push-to-talk: engole só o flagsChanged da tecla física Fn (keyCode 63) — mata o
        // emoji picker, mas NÃO as setas/F-keys (que só carregam a flag), então fn+seta segue funcionando.
        if pushToTalk.usesFn, !pushToTalk.hasKey, pushToTalk.modifiers == 0,
           type == .flagsChanged, keyCode == UInt16(kVK_Function),
           isPureFnChange(flags: flags) {
            return true
        }
        return false
    }

    /// O flagsChanged mexeu só no Fn (sem ⌘⌥⌃⇧ junto)? Evita engolir, p.ex., um ⌘ legítimo.
    private func isPureFnChange(flags: CGEventFlags) -> Bool {
        !flags.contains(.maskCommand) &&
        !flags.contains(.maskAlternate) &&
        !flags.contains(.maskControl) &&
        !flags.contains(.maskShift)
    }
}
