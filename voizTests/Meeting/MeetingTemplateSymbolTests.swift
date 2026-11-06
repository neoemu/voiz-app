import AppKit
import Testing

@Suite("Modelos de reunião — ícones do sistema no lugar de emoji")
struct MeetingTemplateSymbolTests {
    @Test("Cada modelo do Voiz tem um SF Symbol próprio que existe no sistema")
    func builtInsHaveSymbols() {
        for template in MeetingTemplate.defaults {
            #expect(template.symbol != "sparkles", "\(template.id) caiu no ícone padrão")
            #expect(NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil) != nil, "\(template.symbol)")
        }
    }

    @Test("A cópia de um modelo do Voiz mantém o ícone; um modelo novo usa o de documento")
    func copiesAndCustom() {
        var copy = MeetingTemplate.daily
        copy.id = "copy"
        copy.isBuiltIn = false
        #expect(copy.symbol == MeetingTemplate.daily.symbol)
        #expect(MeetingTemplate(name: "Meu", instructions: "", sections: []).symbol == "doc.text")
    }

    @Test("Menus mostram só o nome, sem emoji")
    func menuLabelIsName() {
        for template in MeetingTemplate.defaults {
            #expect(template.menuLabel == template.name)
        }
    }
}
