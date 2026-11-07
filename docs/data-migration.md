# Bibliotecas locais e dados de versões anteriores

O Voiz abre a biblioteca selecionada neste Mac sem autenticação. Gravações, textos e histórico permanecem locais; esta edição não envia novas alterações para o antigo serviço de Sync.

## Escolher uma biblioteca

Abra **Perfil → Bibliotecas neste Mac**. A lista mostra as bibliotecas registradas, seus diretórios e qual está **Em uso**.

- Use **Abrir** para selecionar uma biblioteca existente, incluindo cópias já baixadas de uma conta anterior.
- Em **Biblioteca local independente**, use **Abrir ou criar** para selecionar a biblioteca local independente ou criá-la se ainda não existir.
- Use **Consultar…** na linha **Lixeira e conflitos** para consultar os registros preservados da biblioteca selecionada.

A troca fica bloqueada durante gravação, processamento ou edição. Espere essas operações terminarem antes de selecionar outra biblioteca. A seleção não junta bibliotecas, não copia conteúdo entre contas e mantém IDs e referências de áudio nos diretórios originais. Uma biblioteca nova não importa silenciosamente o histórico global de outra biblioteca.

O **Voiz Dev** e o app oficial têm armazenamento separado. Um build Dev não abre automaticamente os dados do app oficial; não copie dados pessoais para um ambiente de teste apenas para validar o código.

## O que é preservado

A preparação do índice local é repetível e mantém JSON, áudios, lixeira, conflitos e registros de escrita anteriores. Escritas interrompidas são recuperadas por um registro local durável. Novas edições ficam na biblioteca local, sem entrar na fila antiga de uploads.

Preferências atuais e chaves dos provedores continuam no armazenamento existente. Abrir uma biblioteca antiga não substitui idioma, aparência ou provedor pelas preferências históricas daquela conta; essas preferências antigas permanecem nos arquivos de compatibilidade.

O marcador de migração só é salvo após conferir os arquivos necessários. Em caso de erro, os arquivos de origem são preservados e novas operações ficam bloqueadas até a recuperação. Dados legíveis continuam disponíveis para consulta e exportação. Não apague a biblioteca nem seus registros de recuperação para tentar eliminar um erro.

## Exportar os textos disponíveis

Em **Perfil → Bibliotecas neste Mac**, use **Exportar…** na linha **Exportar textos disponíveis neste Mac** e escolha uma pasta de destino. O app cria uma subpasta nova `Voiz-export-…`, com JSON dos itens disponíveis, lixeira e versões de conflitos preservadas.

Essa exportação **não inclui áudio** e não substitui um backup dos dados do app. Mantenha uma cópia recuperável dos arquivos originais, incluindo gravações. Os diretórios exibidos na lista ajudam a identificar as bibliotecas, mas não incluem necessariamente todos os dados e preferências do aplicativo.

## Conteúdo que ainda está na nuvem antiga

Uma biblioteca de conta anterior contém somente o que já estava disponível neste Mac. Não é possível concluir, apenas pela sua presença, que todas as reuniões, mensagens ou gravações remotas foram baixadas.

Os antigos serviços de Sync foram desativados em 7 de novembro de 2026. Esta edição não busca arquivos remotos. Preserve sua cópia local até conferir os itens e os áudios necessários. Não presuma que os arquivos exclusivamente remotos estejam presentes na biblioteca local. Não publique gravações ou credenciais em issues.

Uma atualização oficial também precisa preservar a identidade do aplicativo e o acesso aos dados existentes. O ensaio de atualização a partir da versão distribuída é separado do build Dev e está descrito no [guia de distribuição](distribution.md).
