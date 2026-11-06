# Componentes de terceiros

As licenças abaixo pertencem aos respectivos componentes e não definem a licença principal do Voiz. Os textos originais foram preservados em `ThirdPartyNotices/`; não remova copyrights ou avisos ao redistribuir. A exportação contém o código do app e as referências de pacotes, sem pesos de modelos.

| Componente | Versão e revisão auditadas | Licença e avisos |
| --- | --- | --- |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit/tree/25c62997041c134b03ca82731ce2f6fd2cae1eb9) | 1.0.0 · `25c62997041c134b03ca82731ce2f6fd2cae1eb9` | MIT, copyright Argmax; partes de swift-transformers sob Apache-2.0, copyright Hugging Face. Textos em `WhisperKit-LICENSE.txt` e `WhisperKit-NOTICES.txt`. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/19600a485baa4998812e4654b70d2bab8f2c9949) | 0.15.5 · `19600a485baa4998812e4654b70d2bab8f2c9949` | Apache-2.0; avisos de VBx (Apache-2.0) e fastcluster (BSD de duas cláusulas, Daniel Müllner/Google). Textos `FluidAudio-*`. |
| [Sparkle](https://github.com/sparkle-project/Sparkle/tree/eef1a539a373c1f1a320624b1130fc5de7b2e100) | 2.10.0 · `eef1a539a373c1f1a320624b1130fc5de7b2e100` | Licença permissiva de estilo MIT; o arquivo inclui copyrights e licenças de bsdiff, sais-lite e demais componentes incorporados. Texto `Sparkle-LICENSE.txt`. |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) | 1.8.2 · `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 com Swift Runtime Library Exception. Texto `ArgumentParser-LICENSE.txt`. |

Esses textos foram obtidos dos checkouts exatamente nas revisões acima. Ao atualizar um pacote, confira novamente sua licença, componentes incorporados e avisos. A distribuição binária precisa carregar os avisos exigidos, além de preservar os presentes em frameworks.

## Modelos baixados separadamente

Os pesos seguem os termos próprios, sem serem relicenciados pelo app:

- [WhisperKit Core ML](https://huggingface.co/argmaxinc/whisperkit-coreml): metadados MIT; conversões publicadas pela Argmax de modelos Whisper.
- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): NVIDIA, CC-BY-4.0. A [conversão Core ML da FluidInference](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) conserva a origem NVIDIA. O model card declara CC-BY-4.0 nos metadados e tem um rodapé divergente sobre Apache-2.0; preserve a atribuição do modelo original e confira o snapshot utilizado antes de redistribuir pesos.
- [Parakeet pt-BR Core ML](https://huggingface.co/neoemu/parakeet-tdt-0.6b-v3-ptBR-coreml): CC-BY-4.0; modelo base NVIDIA, [fine-tune pt-BR de alexandreacff](https://huggingface.co/alexandreacff/parakeet-tdt-0.6b-v3-ptBR) e conversão com [FluidInference/mobius](https://github.com/FluidInference/mobius). A conversão não retreinou os pesos.
- [Speaker Diarization Core ML](https://huggingface.co/FluidInference/speaker-diarization-coreml): o conjunto Community-1 usado pelo diarizador offline tem escopo CC-BY-4.0 e atribuição ao pyannote; os artefatos legados têm termos distintos. Consulte `NOTICE.md` e `PROVENANCE.md` no repositório dos modelos para a relação exata de arquivos e origens.
- [Silero VAD Core ML](https://huggingface.co/FluidInference/silero-vad-coreml), usado pela detecção local de fala da tradução: MIT; Silero Team, conversão FluidInference.

Os downloads atuais usam referências mutáveis de upstream. Este inventário não atesta a procedência de qualquer peso já presente no cache de um usuário. Antes de distribuir modelos junto ao app, registre revisão/hash, autores, alterações e termos do snapshot exato. Veja também [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

## Código e assets do Voiz

Os cabeçalhos de copyright existentes no código foram preservados. O ícone do app (waveform branca sobre fundo roxo/índigo) veio do histórico do projeto; a confirmação de direitos para publicação é responsabilidade do mantenedor antes da abertura. Os elementos de interface do sistema usam SF Symbols via APIs da Apple; não há pacote de fontes ou conjunto de símbolos da Apple redistribuído nesta exportação.
