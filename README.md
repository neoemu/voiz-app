<div align="center">
  <img src="voiz/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="Ícone do Voiz">
  <h1>Voiz</h1>
  <p><strong>Sua voz, suas notas, no seu Mac.</strong></p>
  <p>Ditado, reuniões e tradução em um app nativo de macOS.<br>Transcrição local. Código aberto. Sem conta Voiz ou assinatura.</p>
  <p>
    <a href="https://github.com/neoemu/voiz-app/releases/latest">Baixar para macOS</a> ·
    <a href="#recursos">Recursos</a> ·
    <a href="#privacidade-e-ia">Privacidade</a> ·
    <a href="docs/build.md">Compilar o código</a> ·
    <a href="https://voizdev.mintlify.site/">Documentação</a>
  </p>
  <p><strong>Apple Silicon</strong> · macOS 26 ou posterior · <a href="LICENSE">MIT</a></p>
</div>

## Instalação

1. Baixe o arquivo **`.dmg`** na [página de releases](https://github.com/neoemu/voiz-app/releases/latest).
2. Abra o instalador e arraste **Voiz** para **Aplicativos**.
3. Abra o Voiz e conceda as permissões dos recursos que você quiser usar.

Os pacotes oficiais são assinados com **Developer ID** e notarizados pela Apple. Você não precisa de Xcode, Apple Developer ou ferramentas de programação para instalar o app. O primeiro uso de alguns motores de transcrição requer o download dos modelos.

O download também está em [voiz.dev](https://voiz.dev/). Instalações oficiais recebem as atualizações pelo canal integrado ao app.

**Compatibilidade:** Mac com chip M1 ou posterior e macOS 26 ou posterior. Esta edição não oferece suporte a Macs Intel.

> Já usa uma versão anterior? Preserve uma cópia de segurança dos seus dados e leia o [guia de migração](docs/data-migration.md). Esta edição abre os dados já baixados, mas não busca conteúdo que esteja somente no antigo serviço de Sync.

## Recursos

| | O que o Voiz faz |
| --- | --- |
| **Ditado** | Transcreva sua voz e insira o texto no aplicativo em uso pelo atalho configurado. |
| **Reuniões** | Grave microfone e áudio do sistema, identifique falantes e reveja a transcrição junto do áudio. |
| **Notas e resumos** | Organize conversas, capítulos e ações com ajuda do provedor de IA escolhido por você. |
| **Tradução** | Acompanhe a transcrição e a tradução em trechos delimitados por pausas na fala. |
| **Chat** | Consulte suas notas e reuniões em uma conversa com IA. |
| **Biblioteca local** | Mantenha histórico, gravações e textos no Mac, com consulta e exportação. |
| **Integrações** | Use calendários do macOS, exportação para Notion, importação do Granola e um servidor MCP local opcional. |

## Privacidade e IA

A transcrição e a identificação de falantes usam modelos locais. O Voiz não exige conta própria, ativação comercial ou assinatura, e não sincroniza suas bibliotecas com servidores Voiz.

**Chat, resumos e tradução usam sua própria configuração de IA.** Em **Configurações → IA & Tradução**, escolha OpenAI, Anthropic, Google Gemini, xAI ou um endpoint compatível. Esses serviços podem receber os textos enviados para processamento e cobrar pelo uso; suas chaves e custos pertencem à sua conta no provedor.

Downloads de modelos, integrações externas e a busca de atualizações também usam rede. O servidor MCP é opcional e restrito ao próprio Mac. As bibliotecas locais permanecem separadas e podem ser consultadas sem uma conta Voiz.

## Primeiros passos

- **Reuniões:** clique em **Iniciar gravação**. Autorize o microfone e, para captar os participantes de chamadas, a permissão de **Gravação de Tela** indicada pelo macOS. Use **Parar** ao concluir.
- **Ditado:** confira o atalho na tela **Ditado** e ajuste idioma e motor em **Configurações**. A inserção de texto em outros apps exige a permissão de **Acessibilidade**.
- **Tradução:** configure seu provedor de IA, selecione os idiomas e clique em **Gravar**. O resultado fica em **Recentes** depois de parar.
- **Bibliotecas:** em **Perfil → Bibliotecas neste Mac**, escolha uma biblioteca existente ou use **Abrir ou criar**. A exportação de textos não inclui os arquivos de áudio.

## Desenvolvimento

O código está disponível sob MIT. Para compilar, você precisa de Xcode com SDK de macOS 26, Swift 6.2 ou posterior, Python 3 e um certificado Apple Development da sua equipe.

```sh
git clone https://github.com/neoemu/voiz-app.git
cd voiz-app
export VOIZ_DEV_TEAM=SEU_TEAM_ID
make dev
```

Esse comando instala **Voiz Dev**, com identidade, permissões e dados separados do app oficial e atualizador desabilitado. Para apenas compilar, use `make dev-build`. Consulte o [guia de build e testes](docs/build.md) e as [instruções de contribuição](CONTRIBUTING.md).

## Documentação e suporte

- [Bibliotecas e migração de versões anteriores](docs/data-migration.md)
- [Build e testes](docs/build.md)
- [Distribuição assinada e notarizada](docs/distribution.md)
- [Relatar um problema](https://github.com/neoemu/voiz-app/issues)
- [Relatar uma vulnerabilidade em privado](SECURITY.md)

## Licença

O código e o ícone do Voiz usam a [licença MIT](LICENSE). Dependências e modelos mantêm suas próprias licenças e atribuições; consulte os [avisos de terceiros](THIRD_PARTY_NOTICES.md).
