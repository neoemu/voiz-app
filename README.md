# Voiz

Voiz é um app nativo de macOS para gravar, transcrever e organizar conversas. Reúne ditado, reuniões com identificação de falantes, histórico, chat, tradução e exportação, com dados armazenados no seu Mac.

Esta edição funciona sem conta Voiz, ativação comercial, assinatura, sincronização hospedada ou gateway de IA do Voiz. O código usa a [licença MIT](LICENSE). A fonte está em [neoemu/voiz-app](https://github.com/neoemu/voiz-app); o acesso ao repositório ainda está restrito durante a preparação da abertura.

## O que você pode fazer

- **Reuniões:** gravar microfone e áudio do sistema, transcrever, identificar falantes, rever trechos e organizar notas.
- **Ditado:** falar pelo atalho configurado e inserir o texto no aplicativo em uso, com histórico local.
- **Tradução:** escolher os idiomas, gravar e acompanhar a transcrição e a tradução por trechos de fala.
- **Chat e resumos:** trabalhar com suas notas usando um provedor de IA configurado por você.
- **Bibliotecas:** manter reuniões, chats e áudios locais, consultar lixeira e conflitos e exportar os textos disponíveis.

A transcrição e a identificação de falantes usam modelos locais; alguns precisam ser baixados antes do primeiro uso. Chat, resumos e tradução usam o provedor escolhido em Configurações, com sua própria chave ou endpoint compatível. Provedores externos recebem o conteúdo enviado para processamento e podem cobrar pelo uso. Downloads de modelos, integrações externas e o canal oficial de atualização também usam rede.

## Começar pelo código

Requisitos: **Mac com Apple Silicon**, **macOS 26 ou posterior**, Xcode com SDK de macOS 26 e Swift 6.2 ou posterior, Python 3 e certificado **Apple Development** da sua equipe no Keychain.

Com acesso ao repositório:

```sh
git clone https://github.com/neoemu/voiz-app.git
cd voiz-app
export VOIZ_DEV_TEAM=SEU_TEAM_ID
make dev
```

`make dev` compila, verifica a assinatura, instala em `/Applications/Voiz Dev.app` e abre o app. O Dev tem identidade, permissões e dados separados do app oficial; seu atualizador oficial fica desabilitado. Você não precisa de credenciais da infraestrutura Voiz ou da distribuição oficial. Para compilar sem instalar, use `make dev-build`.

Veja [build e testes](docs/build.md) para configurar a assinatura, escolher testes e atualizar sua instalação Dev.

## Primeiro uso

1. Conclua a apresentação e informe o nome do seu perfil local.
2. Em **Configurações → Ditado**, escolha o idioma. Em **Transcrição**, escolha o motor e, quando disponível, o modelo. Aguarde os downloads necessários.
3. Em **Reuniões**, use **Iniciar gravação**. Autorize o microfone quando solicitado; para capturar os participantes de uma chamada, conceda a permissão de **Gravação de Tela** indicada pelo app. Ao terminar, use **Parar** e aguarde o processamento.
4. Para ditar em outro aplicativo, siga o atalho exibido na tela **Ditado**. Os atalhos podem ser ajustados em **Configurações → Ditado**; a inserção de texto também exige **Acessibilidade**.
5. Para usar chat, resumos ou tradução, configure **Configurações → IA & Tradução**. Escolha o provedor e informe sua chave; para um serviço compatível, preencha endpoint e nome do modelo. Em **Tradução**, escolha os idiomas e use **Gravar**; ao parar, o resultado vai para **Recentes**.

O macOS concede permissões separadamente ao Voiz Dev e ao app oficial. A tradução prepara seu detector local de fala antes de abrir o microfone e processa trechos delimitados por pausas; o provedor escolhido continua responsável pela tradução.

## Dados, contribuição e distribuição

Em **Perfil → Bibliotecas neste Mac**, selecione uma biblioteca existente ou use **Abrir ou criar** para a biblioteca local independente. Uma cópia antiga já baixada continua acessível sem login, mas não comprova que todo o conteúdo remoto esteja neste Mac. Leia [bibliotecas e migração](docs/data-migration.md) antes de trabalhar com dados de uma instalação anterior.

O repositório contém o cliente macOS, seus testes e ferramentas de build. Backend de conta, Sync, pagamentos e administração da nuvem antiga não fazem parte desta edição. Mantenha uma cópia de segurança dos seus dados locais.

Para contribuir, veja [CONTRIBUTING.md](CONTRIBUTING.md) e a [política de segurança](SECURITY.md). Dependências e modelos têm termos próprios, preservados nos [avisos de terceiros](THIRD_PARTY_NOTICES.md). O empacotamento oficial segue o guia de [distribuição macOS](docs/distribution.md); compilar a fonte não publica uma versão do aplicativo.
