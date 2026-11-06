# Bibliotecas locais durante a transição

O app abre a biblioteca selecionada no registro local, sem autenticação. Em **Perfil → Bibliotecas**, você pode escolher a biblioteca local ou uma cópia já baixada de uma conta anterior. A troca é bloqueada durante gravação, processamento ou edição. Bibliotecas não são juntadas; IDs e referências de áudio permanecem nos diretórios originais.

A preparação do índice local é repetível. Ela preserva JSON, áudios, lixeira, conflitos e journals anteriores. Escritas interrompidas são recuperadas por um registro local durável; novas edições não entram na fila antiga de uploads. O marcador de migração só é salvo após conferir os arquivos necessários. Em caso de erro, os arquivos são preservados e novas operações ficam bloqueadas até a recuperação; os dados legíveis continuam disponíveis para consulta e exportação.

Preferências atuais e chaves dos provedores permanecem no armazenamento existente. Selecionar uma biblioteca antiga não substitui idioma, aparência ou provedor pelas preferências históricas daquela conta. As preferências antigas permanecem nos arquivos de compatibilidade. Uma biblioteca nova não importa silenciosamente o histórico global de outra biblioteca.

A opção **Exportar textos** cria uma pasta nova com JSON dos itens disponíveis, lixeira e versões de conflitos preservadas. Essa exportação não inclui áudio nem comprova que todo o conteúdo remoto esteja neste Mac. Preserve uma cópia recuperável dos arquivos originais antes de usar qualquer candidato com dados importantes.

Conteúdo que exista apenas no servidor deve ser baixado ou exportado pelo fluxo anterior enquanto o serviço estiver disponível. Remover o cliente de Sync não baixa arquivos remotos nem desliga os serviços antigos.

Os testes desta preparação usam dados sintéticos e cobrem arquivos ausentes, interrupção, repetição, isolamento e recuperação. O ensaio funcional de gravação/reprodução e atualização a partir de uma instalação anterior continua sendo uma etapa própria antes de uma distribuição oficial.
