# Voiz

Voiz é um app nativo de macOS para gravar, transcrever e organizar conversas, com identificação de falantes, histórico, chat, tradução e exportação. Este candidato privado prepara a edição sem conta Voiz, ativação comercial, sincronização hospedada ou IA fornecida pelo Voiz. A licença do código e o endereço público ainda estão em definição; este material não anuncia um lançamento.

A transcrição e a identificação de falantes usam modelos locais. O primeiro uso pode precisar baixar modelos. Recursos de IA usam o provedor e a chave configurados por você; o conteúdo enviado a esse provedor é processado de acordo com a sua configuração. MCP permite integrar ferramentas locais. O aplicativo inteiro não é descrito como offline.

## Compilar e testar

O alvo do app é Apple Silicon com macOS 26 ou posterior. É necessário Xcode com SDK de macOS 26 e Swift 6.2 ou posterior. Veja [instruções de build](docs/build.md), [contribuição](CONTRIBUTING.md) e [segurança](SECURITY.md).

```sh
VOIZ_DEV_TEAM=SEU_TEAM_ID make dev-build
VOIZ_DEV_TEAM=SEU_TEAM_ID make test
```

Use um certificado Apple Development válido da sua equipe. O build Development usa identidade e dados separados do app oficial, com o atualizador oficial desabilitado. Credenciais da distribuição oficial não são necessárias ao desenvolvimento.

## Dados e dependências

Bibliotecas locais e cópias já baixadas de bibliotecas antigas precisam permanecer separadas; uma cópia local não comprova que todo o conteúdo remoto foi baixado. Veja [migração de dados](docs/data-migration.md). Nenhum backend de conta, sincronização, pagamentos ou administração de nuvem faz parte desta exportação.

As licenças dos componentes de terceiros e dos modelos são independentes da licença do Voiz. Veja [avisos de terceiros](THIRD_PARTY_NOTICES.md) e [estado da licença](LICENSE-PENDING.md).
