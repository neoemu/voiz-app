# Segurança

Não inclua tokens, transcrições reais, gravações, arquivos de biblioteca, cookies ou credenciais em issues, logs ou exemplos. Ao relatar um problema, use a versão/build, passos com dados sintéticos e os arquivos de código relevantes.

Enquanto o repositório permanecer privado, reporte ao mantenedor pelo canal privado já usado para o projeto. Não abra issues ou PRs com detalhes de uma vulnerabilidade: essas conversas podem se tornar públicas quando o repositório for aberto.

O canal previsto para a abertura é o **Private vulnerability reporting do GitHub**, em [Security → Advisories](https://github.com/neoemu/voiz-app/security/advisories). O mantenedor deverá habilitar e conferir o botão **Report a vulnerability** na abertura. Segundo a [documentação do GitHub](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository), esse recurso é disponibilizado para repositórios públicos; ele ainda não está habilitado no repositório privado. Se o botão não estiver disponível, solicite um contato privado ao mantenedor sem revelar a vulnerabilidade publicamente.

Um relato deve informar a versão/build ou commit, passos de reprodução com dados sintéticos, comportamento observado e impacto esperado. Envie somente o mínimo necessário; não inclua chaves ou dados reais de terceiros. Ainda não há prazo de resposta garantido ou programa de recompensas anunciado.

O app guarda dados localmente. Os provedores de IA escolhidos pelo usuário podem receber conteúdo enviado para processamento. Downloads de modelos e integrações externas usam rede. O servidor MCP deve continuar restrito ao loopback com as proteções de acesso configuradas.

Builds de contribuidores usam seu próprio certificado de desenvolvimento e não recebem automaticamente o canal oficial. Atualizações oficiais exigem assinatura, notarização e validação Sparkle; desabilitar essas verificações não é um procedimento de recuperação.
