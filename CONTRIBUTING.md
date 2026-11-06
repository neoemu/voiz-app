# Contribuir

Este candidato ainda está em preparação privada. O código do Voiz usa a [licença MIT](LICENSE). Antes da abertura para contribuições públicas, o mantenedor deve confirmar os direitos sobre código e assets existentes.

Prepare um ambiente conforme [build](docs/build.md), crie uma branch e descreva o problema e o comportamento esperado. Use dados sintéticos. Não copie bibliotecas, gravações, preferências, chaves ou sessões pessoais para o projeto ou para testes.

Preserve compatibilidade de arquivos: IDs de reuniões e chats, referências de áudio e separação das bibliotecas não devem mudar silenciosamente. Se o trabalho altera persistência ou migração, inclua casos de interrupção, repetição, arquivo ausente e recuperação. Restrições de integridade e operações em andamento devem continuar protegidas.

Antes de enviar uma alteração, execute os testes pertinentes e `git diff --check`; registre comandos, resultado e limitações. Alterações de interface ou áudio também precisam de verificação com dados sintéticos no Dev. Não confunda compilação com teste funcional.

Não inclua serviços comerciais ou hospedados do Voiz, credenciais de publicação, históricos privados ou binários de modelos no repositório. Preserve atribuições e avisos de terceiros. Publicar um PR ou integrar código não publica uma versão macOS.
