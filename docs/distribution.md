# Distribuição macOS

O fluxo oficial permanece separado dos builds de contribuidores. Um build Development não precisa das credenciais do mantenedor e mantém o atualizador oficial desabilitado. A preparação deste candidato privado não autoriza distribuir o app ou publicar um feed.

## Pré-requisitos do mantenedor

Para produzir artefatos oficiais são necessários: certificado **Developer ID Application** com chave privada no Keychain, equipe correspondente, perfil de autenticação de notarização e a chave privada Sparkle do canal. Os exemplos de configuração não contêm essas credenciais. Nunca exporte chaves para o repositório, argv ou logs.

O canal oficial existente é `https://voiz.dev/updates/appcast.xml`. A chave pública Sparkle e a identidade do aplicativo preservam a continuidade das instalações oficiais; a chave pública não dá autorização para assinar atualizações. Distribuições independentes precisam de identidade e canal próprios, sem reutilizar o canal oficial automaticamente.

```sh
cp Config/distribution.env.example Config/distribution.env
# Preencha somente sua configuração não secreta; autenticação fica no Keychain.
source Config/distribution.env
make distribution-check
```

`distribution-check` confere pré-requisitos. O mantenedor deve conferir a fonte integrada, versão/build e autorização antes de preparar um pacote.

## Preparar sem publicar

```sh
source Config/distribution.env
make distribution
```

`scripts/distribute.sh` prepara um archive Release, valida Developer ID/Hardened Runtime, submete à notarização Apple e exige aprovação. Depois anexa o ticket, valida Gatekeeper, cria ZIP, assina o catálogo Sparkle e verifica as assinaturas. `scripts/package_dmg.py` prepara um DMG assinado e notarizado com `Config/dmg/settings.py`. O resultado fica em um diretório novo de `build/Distribution/`.

A notarização comunica-se com a Apple; ela não publica o app. Os scripts de empacotamento não instalam sobre o app oficial nem enviam arquivos ao site. Não há fallback para assinatura ad hoc, retirada da quarentena ou desativação de verificação.

Antes de qualquer distribuição, registre fonte, versão/build, resultados da assinatura/notarização/Gatekeeper e assinatura do appcast. Teste instalação e atualização em ambiente separado com dados sintéticos, incluindo preservação de dados/permissões e recusa de pacotes adulterados. Validar um ZIP ou gerar um feed não comprova o funcionamento da atualização.

Publicação, upload, alteração de visibilidade do repositório e encerramento de serviços exigem escopo explícito separado. A infraestrutura e os procedimentos administrativos privados não fazem parte desta exportação.
