# PubliSOS

PubliSOS é o cliente de suporte remoto da Publi. É uma **versão modificada do [RustDesk](https://github.com/rustdesk/rustdesk) 1.5.3**, com o nome, o logo e as cores da Publi.

Este repositório contém o **código-fonte correspondente** ao programa distribuído, como exige a licença **AGPL-3.0** (arquivo `LICENCE`).

## Origem e licença

- Código base: RustDesk, tag `1.5.3`, commit `95cca3f661f635b3cc85c04935fe8d96d8f432ef`, licenciado sob **GNU AGPL-3.0**.
- O submódulo `libs/hbb_common` (do RustDesk, commit `fae47e024dd83cef6aaecde0aa7d11731df11649`) está incluído como arquivos comuns.
- As nossas alterações também estão sob **AGPL-3.0**.
- Avisos de copyright e de licença do RustDesk foram **mantidos**. O texto original do README está em `README-RUSTDESK.md`.
- RustDesk é nome e marca dos seus titulares. O PubliSOS não é afiliado nem endossado pelo projeto RustDesk. O nome e o logo da Publi são da Publi.

## O que foi alterado em relação ao RustDesk 1.5.3

O histórico do Git mostra exatamente isso:

1. **Commit `Upstream RustDesk 1.5.3 (snapshot)`:** o código original, sem alterações.
2. **Commit `PubliSOS: nome, logo e cores da Publi`:** só aparência.
   - nome do app (`APP_NAME`) e metadados do executável;
   - ícones e logo da tela inicial;
   - cores de destaque.
3. **Commit seguinte:** scripts de compilação (`build-local`), este README e o aviso de código aberto. As workflows de CI do projeto original foram removidas, porque dependem da infraestrutura deles, e os dois arquivos de certificado e chave **de teste** do upstream (libs/hbb_common/tests/data/websocket-*.pem) foram removidos para que o repositório não contenha nenhuma chave. Eles são usados só pelos testes automatizados do hbb_common, não pela compilação do programa.

O comando `git diff` entre o primeiro e o segundo commit lista todas as alterações no código.

## O que este repositório não contém

- **Nenhum servidor, chave, senha ou token da Publi.** O cliente compilado a partir deste código usa o servidor padrão do RustDesk, a menos que você informe o seu (veja abaixo).
- O servidor de suporte é o **RustDesk Server** (`hbbs` e `hbbr`), software separado, também AGPL-3.0. A Publi executa a imagem oficial, sem modificações.

## Como compilar (Windows x64)

Os scripts ficam em `build-local`. São escritos para PowerShell 5.1 e seguem o workflow oficial do RustDesk para Windows.

1. **Ambiente:** `build-local\instalar-ambiente.ps1` instala as ferramentas (Visual Studio Build Tools com C++, Rust 1.75, Flutter 3.24.5, LLVM 15.0.6, vcpkg, Python 3.12, entre outras) em `F:\rustdesk-build` por padrão. Rode primeiro com `-SomenteVerificar` e depois como administrador.
2. **Código-fonte:** coloque este repositório em `F:\rustdesk-build\src\rustdesk` (ou ajuste o parâmetro `-Fonte`).
3. **Marca e servidor:** `build-local\marca\aplicar-marca.ps1`. Para apontar o cliente para o seu servidor, crie `build-local\marca\servidor.local.json` (ignorado pelo Git):
   ```json
   { "Servidor": "suporte.exemplo.com.br", "Chave": "<chave publica do seu servidor, 44 caracteres>" }
   ```
   Use somente o nome do servidor, sem `https://` e sem porta. A chave é a **pública** do seu `hbbs` (`id_ed25519.pub`). **Nunca use a chave privada.**
4. **Compilação:** `build-local\compilar.ps1 -Etapa <etapa>`, nesta ordem: `bridge`, `engine`, `vcpkg`, `build` e, se quiser um executável único, `unico`.

Observações:
- A etapa `engine` baixa o engine do Flutter do projeto `rustdesk/engine` (release `main`, sem versão fixa), como faz o CI oficial. O hash fica no log.
- O ícone e o logo são gerados a partir de `build-local\marca\fonte\publi-original.png`.

## Aviso de código aberto

Veja `AVISO-OPEN-SOURCE.md`.
