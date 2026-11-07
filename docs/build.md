# Build e testes

O app requer **Apple Silicon**, **macOS 26 ou posterior**, Xcode com SDK de macOS 26 e Swift 6.2 ou posterior, além de Python 3. Use o projeto Xcode pelos comandos `make` abaixo para obter o bundle macOS com recursos, permissões e assinatura configurados.

## Preparar o ambiente

1. Abra o Xcode e conclua a instalação de seus componentes. Em **Xcode → Settings → Locations**, selecione a instalação correspondente em **Command Line Tools**.
2. Em **Xcode → Settings → Accounts**, configure sua conta Apple e a equipe de desenvolvimento. Tenha um certificado **Apple Development** válido, com sua chave privada, no Keychain deste Mac.
3. Clone o código e configure o identificador da sua equipe no terminal:

```sh
git clone https://github.com/neoemu/voiz-app.git
cd voiz-app
export VOIZ_DEV_TEAM=SEU_TEAM_ID
```

Enquanto o repositório permanecer privado, o clone exige acesso concedido no GitHub. A configuração de equipe é local: não edite o projeto para inserir os dados do mantenedor. Os pacotes Swift são fixados no projeto; mantenha `Package.resolved`, o projeto Xcode e `Package.swift` coerentes quando atualizar dependências.

## Compilar e usar o Dev

```sh
make dev-build
```

Esse comando compila e verifica a assinatura, o bundle ID, o sandbox e o atualizador desabilitado. Não instala nem abre o app. O resultado fica em `build/Build/Products/Development/Voiz Dev.app`; o log está em `build/DevelopmentLogs/build.log`.

Para compilar, instalar e abrir:

```sh
make dev
```

A instalação fica em `/Applications/Voiz Dev.app`, com bundle ID `com.rmb.voiz.dev`. Ela usa dados, credenciais e permissões separados do app oficial `com.rmb.voiz`. Não recebe atualizações do canal oficial. O mesmo Dev instalado é compartilhado pelos checkouts do projeto.

Use `make dev-status` para identificar a instalação e sua origem. O script recusa substituir um Dev aberto: termine gravações, processamento e edições, depois use `make dev-stop` para solicitar saída normal. Execute `make dev` para atualizar e abrir. `make dev-open` abre a instalação existente sem compilar.

O build exige uma identidade Apple Development válida da sua equipe. Não é necessário possuir certificados Developer ID, chaves Sparkle, credenciais de notarização ou acesso à infraestrutura do mantenedor. Não use assinatura ad hoc ou `CODE_SIGNING_ALLOWED=NO`, nem substitua o app oficial por um build de teste.

## Testar a alteração

Os testes Swift rodam em um alvo isolado, sem abrir o app de uso. Concentre a validação no fechamento da alteração e selecione as suítes afetadas:

```sh
make test TEST_ONLY=voizTests/NomeDaSuite
```

Quando a abrangência da mudança justificar a suíte completa, use `make test`. O log fica em `build/DevelopmentLogs/tests.log`. Use dados sintéticos; os testes não devem criar contas, cobranças ou dados remotos.

Para os scripts de desenvolvimento e assinatura Sparkle com chaves sintéticas, `make dev-script-test` também requer `uv`. A CI executa checks de fonte e scripts, sem credenciais de distribuição. Ela não executa o build assinado nem a suíte Swift completa.

Antes de enviar a alteração, confira `git diff --check` e registre os comandos executados, o resultado e as limitações. Alterações de interface e áudio também precisam de um ensaio no Dev com dados sintéticos. Mudanças somente documentais não exigem testes do produto.

## Primeiro uso e rede

Um clone limpo pode precisar de internet para resolver pacotes Swift. O app também baixa modelos no primeiro uso. Configure o idioma em **Configurações → Ditado** e o motor em **Transcrição**. O motor escolhido nessa seção atende ao ditado e às reuniões no modo Qualidade.

A tradução prepara um modelo local Silero VAD antes de iniciar a captura. Depois de armazenado no cache, o detector de fala não precisa da rede; a tradução usa a conexão do provedor escolhido. Falha ao preparar o detector mantém o microfone fechado e permite tentar novamente.

Chat, resumos e tradução são configurados em **Configurações → IA & Tradução**, com sua própria chave ou endpoint compatível. Provedores externos podem receber o conteúdo solicitado e cobrar pelo uso. O app não depende de uma conta ou serviço de IA Voiz. Consulte o [README](../README.md#primeiro-uso) para os primeiros passos e permissões.

Para dados de uma instalação anterior, leia [bibliotecas e migração](data-migration.md). Para produzir um pacote oficial, siga [distribuição macOS](distribution.md): Developer ID Application, notarização, Gatekeeper e assinaturas Sparkle são etapas próprias, sem publicação automática.
