import Foundation

/// Regras do seletor de comandos acionado por "/" no composer do chat.
///
/// Só a lógica de texto vive aqui — o que conta como "comando em andamento", como filtrar os comandos
/// pelo que foi digitado e como o comando escolhido entra no prompt. A parte visual fica em
/// `ChatSlashCommandPicker`, e a expansão do comando na hora de enviar continua em
/// `MeetingAIRecipe.expanded`.
enum ChatSlashCommand {
    /// O que está sendo digitado como comando, sem a barra. `nil` quando o prompt não é um comando
    /// em andamento: vazio, sem "/" inicial ou já com espaço depois do comando ("/riscos amanhã").
    static func query(in prompt: String) -> String? {
        guard prompt.hasPrefix("/") else { return nil }
        let rest = prompt.dropFirst()
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }

    /// Comandos que combinam com o texto digitado. Comandos que começam pelo texto vêm antes; depois
    /// entram os que o contêm no comando ou no nome. Sem texto, a lista inteira, na ordem do usuário.
    static func matches(_ recipes: [MeetingAIRecipe], query: String) -> [MeetingAIRecipe] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return recipes }

        let byPrefix = recipes.filter { $0.command.lowercased().hasPrefix(needle) }
        let byContent = recipes.filter { recipe in
            !byPrefix.contains(where: { $0.id == recipe.id })
                && (recipe.command.lowercased().contains(needle) || recipe.title.localizedStandardContains(needle))
        }
        return byPrefix + byContent
    }

    /// Prompt resultante ao escolher um comando. O comando substitui o primeiro token quando o prompt
    /// já começa com "/", e o resto do texto segue como complemento — assim trocar de comando não
    /// acumula "/decisoes /riscos". O espaço final fecha o seletor e deixa o cursor pronto para o
    /// complemento.
    static func apply(_ recipe: MeetingAIRecipe, to prompt: String) -> String {
        let command = "/" + recipe.command + " "
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimmed.hasPrefix("/") ? trimmed.drop(while: { !$0.isWhitespace }) : Substring(trimmed)
        let rest = remainder.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? command : command + rest
    }
}
