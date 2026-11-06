import Foundation

extension Locale {
    /// Locale do idioma em que a interface está rodando. Datas e horas seguem o idioma escolhido
    /// nas Configurações, não a região do macOS: quem usa o app em inglês vê `9/25/26`, quem usa em
    /// português vê `25/09/26`. Lê do bundle, e não das Configurações, porque a troca de idioma só
    /// vale depois do relaunch — o bundle é o que está de fato na tela.
    static var voizInterface: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "pt-BR")
    }
}
