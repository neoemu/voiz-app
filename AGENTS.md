# Instruções para contribuidores e agentes

- Leia `README.md`, `CONTRIBUTING.md` e `docs/build.md`. Preserve alterações locais e dados do usuário. Trabalhe em uma branch própria; não use reset, clean ou stash como preparação automática.
- O app deve funcionar sem conta Voiz, licença comercial, cobrança, Sync hospedado ou gateway de IA Voiz. Provedores configurados pelo usuário, downloads de modelos e atualizações oficiais são caminhos distintos.
- Preserve leitura, exportação, IDs, referências de áudio e isolamento entre bibliotecas. Migrações devem ser idempotentes, recuperáveis e não apagar a origem antes de verificar a cópia. Nunca usar dados pessoais em fixtures ou logs.
- Para compilar e testar, use sua equipe e certificado Apple Development: `VOIZ_DEV_TEAM=SEU_TEAM_ID make dev-build` e `VOIZ_DEV_TEAM=SEU_TEAM_ID make test`. Não usar assinatura ad hoc nem `CODE_SIGNING_ALLOWED=NO`.
- O Dev tem nome, bundle ID e dados separados. Não substituir o app oficial, instalar no Desktop ou habilitar o canal oficial em builds de contribuidores. `make dev-build` compila sem instalar; a instalação Dev é uma ação separada. Respeite gravações em andamento e locks de instalação.
- Agrupe mudanças e execute verificações pertinentes no fechamento; repita apenas testes afetados por correções posteriores. Diferencie build, teste, validação funcional, integração e publicação no relatório.
- Nunca incluir certificados, chaves de API, arquivos de ambiente reais, sessões, gravações, históricos, dumps ou artefatos de build no Git. Exemplos devem conter somente valores sintéticos.
- Distribuição oficial exige Developer ID, notarização, Gatekeeper e assinatura Sparkle; nenhum build, teste ou merge autoriza publicação. Credenciais e operação de release ficam privadas.
- Preserve avisos de copyright e licenças de terceiros. A licença principal é MIT, conforme `LICENSE`. A abertura do repositório depende de autorização explícita do mantenedor.
