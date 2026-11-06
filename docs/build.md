# Build e testes

O app requer Apple Silicon, macOS 26 ou posterior, Xcode com SDK de macOS 26 e Swift 6.2 ou posterior. Os pacotes Swift são fixados no projeto; mantenha `Package.resolved` coerente com o projeto Xcode e o `Package.swift`.

## Assinatura de desenvolvimento

Configure sua conta Apple no Xcode, sua equipe e um certificado **Apple Development** válido no Keychain. Passe o identificador da sua equipe por variável de ambiente, sem editar o projeto com dados do mantenedor:

```sh
VOIZ_DEV_TEAM=SEU_TEAM_ID make dev-build
VOIZ_DEV_TEAM=SEU_TEAM_ID make test
```

`make dev-build` compila e verifica o bundle sem instalá-lo. `make test` executa testes isolados. Para uma suíte específica:

```sh
VOIZ_DEV_TEAM=SEU_TEAM_ID make test TEST_ONLY=voizTests/NomeDaSuite
```

`make dev` compila, instala o **Voiz Dev** e o abre. A instalação Dev tem bundle ID `com.rmb.voiz.dev`, distinto do oficial `com.rmb.voiz`; usa dados separados e mantém o atualizador oficial desabilitado. Confira `make dev-status` para identificar a origem da instalação compartilhada entre checkouts. O script recusa substituir um Dev aberto; termine operações e encerre-o normalmente antes de instalar.

Não é necessário possuir certificados, chaves Sparkle, credenciais de notarização ou infraestrutura do mantenedor para desenvolver. Nunca use assinatura ad hoc ou `CODE_SIGNING_ALLOWED=NO`. Não instale builds de teste sobre o app oficial nem no Desktop.

## Validação e rede

Use dados sintéticos. Os testes não devem criar contas, cobranças ou dados remotos. Um clone limpo pode precisar de internet para resolver pacotes Swift; o app também pode baixar modelos no primeiro uso. Recursos de IA externos precisam da configuração do usuário.

Execute `git diff --check` e os testes pertinentes antes da revisão. A CI não recebe credenciais de produção; verificações estáticas não substituem build/testes assinados nem validação funcional de áudio e interface.

O fluxo de distribuição oficial é separado: Developer ID Application, notarização Apple, Gatekeeper, pacote e feed Sparkle assinados. Preparar artefatos não autoriza publicá-los. Nenhuma credencial de release acompanha este repositório.
