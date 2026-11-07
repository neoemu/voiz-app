# Contribuir

O Voiz usa a [licença MIT](LICENSE). Contribuições devem preservar o funcionamento local do app, a compatibilidade dos dados existentes e os avisos de terceiros. Inclua apenas material que você possa contribuir sob esses termos; identifique dependências ou conteúdo de terceiros e suas licenças.

## Preparar uma alteração

1. Configure o ambiente conforme [build e testes](docs/build.md), com sua própria equipe Apple Development.
2. Crie uma branch a partir da base atual, preservando alterações locais já existentes.
3. Descreva o problema e o comportamento esperado. Use dados sintéticos para reproduzir o caso.
4. Agrupe as mudanças e execute as verificações pertinentes no fechamento. No PR, registre o que mudou, como foi validado e eventuais limitações.

Não copie bibliotecas, gravações, preferências, chaves ou sessões pessoais para o projeto ou para testes. Relatos de vulnerabilidade seguem [SECURITY.md](SECURITY.md).

## Compatibilidade e escopo

IDs de reuniões e chats, referências de áudio e separação das bibliotecas devem ser preservados. Se a alteração modifica persistência ou migração, cubra interrupção, repetição, arquivo ausente e recuperação. Proteções contra edição ou troca de biblioteca durante operações precisam continuar ativas.

O app funciona sem conta Voiz, licença comercial, cobrança, Sync hospedado ou IA fornecida pelo Voiz. Provedores configurados pelo usuário, integrações opcionais e downloads de modelos permanecem disponíveis. Alguns arquivos e tipos ainda usam nomes com `Sync` para ler formatos antigos: preserve essa compatibilidade e avalie o comportamento antes de remover código pelo nome.

## Validação

Execute `git diff --check` e os testes relacionados à alteração. Para selecionar uma suíte:

```sh
VOIZ_DEV_TEAM=SEU_TEAM_ID make test TEST_ONLY=voizTests/NomeDaSuite
```

Alterações de interface ou áudio precisam de verificação com dados sintéticos no **Voiz Dev**. Compilar não comprova o funcionamento desses fluxos. Mudanças somente de documentação não exigem reinstalar o app nem repetir a suíte Swift completa.

A CI executa verificações de fonte e scripts sem credenciais de produção. Ela não substitui os testes Swift, o build assinado ou o ensaio funcional pertinentes à mudança.

Não inclua serviços hospedados antigos do Voiz, credenciais de publicação, históricos privados ou pesos de modelos no repositório. Preserve atribuições e avisos de terceiros; o bundle do app deve levar os arquivos de licença da fonte. Um PR ou merge não publica uma versão macOS. A distribuição oficial permanece separada, conforme [o guia de distribuição](docs/distribution.md).
