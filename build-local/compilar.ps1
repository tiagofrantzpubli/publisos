#Requires -Version 5.1
<#
.SYNOPSIS
    Compila o cliente PubliSOS (RustDesk 1.5.3, Flutter, Windows x64) neste PC.

.DESCRIPTION
    Segue os passos do workflow oficial do RustDesk (.github\workflows\flutter-build.yml e
    bridge.yml, tag 1.5.3), na ordem: bridge, engine, vcpkg, build.
    Pre-requisito: instalar-ambiente.ps1 ja executado. Nao precisa de Administrador.

    Etapas (-Etapa):
      bridge  Gera as pontes Rust<->Dart (flutter_rust_bridge) com Flutter 3.22.3, numa COPIA
              do codigo, e traz so os arquivos gerados para o codigo principal.
      engine  Troca o engine do Flutter pelo do projeto rustdesk/engine e aplica o patch do
              Flutter (como o CI faz).
      vcpkg   Compila as dependencias nativas (ffmpeg, libvpx, opus...). Demora.
      build   cargo build + flutter build windows, e copia o resultado para a pasta de saida.
      unico   Empacota a pasta compilada num unico executavel (empacotador portatil do RustDesk).
      todas   Todas as etapas, na ordem (bridge, engine, vcpkg, build).

    -SomenteVerificar mostra o que cada etapa faria e confere os pre-requisitos, sem executar.

    Arquivo so ASCII (sem acentos) para o PowerShell 5.1 ler sem BOM.
#>
[CmdletBinding()]
param(
    [ValidateSet('bridge', 'engine', 'vcpkg', 'build', 'unico', 'todas')]
    [string]$Etapa = 'todas',
    [string]$Base = 'F:\rustdesk-build',
    [string]$NomeSaida = 'PubliSOS',
    [switch]$SomenteVerificar
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Src        = Join-Path $Base 'src\rustdesk'
$BridgeWork = Join-Path $Base 'src\bridge-work'
$Flutter    = Join-Path $Base 'flutter'
$Flutter322 = Join-Path $Base 'flutter-3.22.3'
$Downloads  = Join-Path $Base 'downloads'
$Saida      = Join-Path $Base ('saida\' + $NomeSaida)
$Logs       = Join-Path $Base 'logs'
$Triplet    = 'x64-windows-static'
$EngineUrl  = 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip'
$PatchNome  = 'flutter_3.24.4_dropdown_menu_enableFilter.diff'
$CargoExpandVer = '1.0.95'
$BridgeVer      = '1.80.1'
$FlutterRepo    = 'https://github.com/flutter/flutter.git'

function Log([string]$m, [string]$nivel = 'INFO') {
    $cor = 'White'
    if ($nivel -eq 'OK') { $cor = 'Green' } elseif ($nivel -eq 'AVISO') { $cor = 'Yellow' } elseif ($nivel -eq 'ERRO') { $cor = 'Red' } elseif ($nivel -eq 'FARIA') { $cor = 'Cyan' }
    Write-Host ('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $nivel, $m) -ForegroundColor $cor
}

# Recarrega PATH e variaveis do registro (o terminal pode ter sido aberto antes da instalacao).
function Update-Ambiente {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($k) {
        foreach ($n in $k.GetValueNames()) {
            if ($n -ieq 'Path' -or $n -ieq 'TEMP' -or $n -ieq 'TMP') { continue }
            [Environment]::SetEnvironmentVariable($n, [Environment]::ExpandEnvironmentVariables([string]$k.GetValue($n)), 'Process')
        }
        $k.Close()
    }
}

# Roda um programa nativo; mostra a saida; falha se o codigo de saida for diferente de 0.
function Rodar {
    param([string]$Exe, [string[]]$Argumentos = @(), [string]$Pasta = '', [switch]$PodeFalhar)
    $txt = $Exe + ' ' + ($Argumentos -join ' ')
    if ($SomenteVerificar) { Log ("executaria: $txt") 'FARIA'; return 0 }
    Log ("> $txt")
    $ant = Get-Location
    if ($Pasta) { Set-Location -LiteralPath $Pasta }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Argumentos 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
        Set-Location -LiteralPath $ant
    }
    if ($codigo -ne 0 -and -not $PodeFalhar) { throw ("Falhou (codigo {0}): {1}" -f $codigo, $txt) }
    return $codigo
}

# Importa o ambiente do compilador da Microsoft (INCLUDE, LIB, PATH do MSVC), como o
# "Developer Command Prompt". Sem isso, o bindgen (libclang) nao acha stdlib.h e inttypes.h.
function Import-Vcvars {
    $vc = Join-Path $Base 'vs\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vc)) { Log "vcvars64.bat nao encontrado em $vc" 'AVISO'; return }
    # O vcvars define VCPKG_ROOT apontando para o vcpkg embutido no Visual Studio, o que esconderia
    # as bibliotecas que instalamos. Guarda o valor nosso e restaura depois.
    $vcpkgNosso = $env:VCPKG_ROOT
    $linhas = & cmd.exe /c ('"' + $vc + '" >nul 2>&1 && set')
    foreach ($l in $linhas) {
        if ($l -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
    if ($vcpkgNosso) { [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $vcpkgNosso, 'Process') }
    if (-not $env:INCLUDE) { Log 'vcvars64 nao definiu INCLUDE. O bindgen pode falhar.' 'AVISO' } else { Log 'Ambiente do MSVC (vcvars64) carregado.' 'OK' }
}

function Exigir-Comando([string]$nome) {
    if (-not (Get-Command $nome -ErrorAction SilentlyContinue)) { throw "Comando nao encontrado no PATH: $nome. Rode instalar-ambiente.ps1 e abra um terminal novo." }
}

# ---------------------------------------------------------------------------
function Etapa-Preflight {
    Log '== Pre-requisitos ==' 'INFO'
    if (-not (Test-Path -LiteralPath (Join-Path $Src 'Cargo.toml'))) { throw "Codigo do RustDesk nao encontrado em $Src" }
    foreach ($c in @('git', 'cargo', 'rustc', 'flutter', 'python')) { Exigir-Comando $c }
    $v = (& rustc --version) 2>&1 | Select-Object -First 1
    if ($v -notmatch 'rustc 1\.75\.') { throw "Rust deve ser 1.75.x, achei: $v" }
    $fv = (& flutter --version 2>&1 | Select-Object -First 1)
    if ($fv -notmatch 'Flutter 3\.24\.5') { throw "Flutter do PATH deve ser 3.24.5, achei: $fv" }
    if (-not $env:VCPKG_ROOT) { throw 'VCPKG_ROOT nao definida.' }
    if (-not $env:LIBCLANG_PATH) { throw 'LIBCLANG_PATH nao definida.' }
    $dev = $null
    try { $dev = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense } catch { }
    if ($dev -ne 1) { Log 'Modo de Desenvolvedor do Windows esta DESATIVADO. O flutter build windows vai falhar sem ele (symlinks). Ative em Configuracoes > Sistema > Para desenvolvedores.' 'AVISO' }
    $livre = [math]::Round((New-Object IO.DriveInfo($Base.Substring(0, 2))).AvailableFreeSpace / 1GB, 1)
    Log ("Espaco livre em {0}: {1} GB" -f $Base.Substring(0, 2), $livre)
    if ($livre -lt 25) { Log 'Pouco espaco livre. O build pode precisar de 20 GB ou mais.' 'AVISO' }
    Log ("rustc: $v") 'OK'
    Log ("flutter: $fv") 'OK'
}

# ---------------------------------------------------------------------------
function Etapa-Bridge {
    Log '== Etapa bridge ==' 'INFO'
    $arquivos = @('src\bridge_generated.rs', 'src\bridge_generated.io.rs', 'flutter\lib\generated_bridge.dart', 'flutter\lib\generated_bridge.freezed.dart')
    $faltam = @($arquivos | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Src $_)) })
    if ($faltam.Count -eq 0) { Log 'Arquivos do bridge ja existem no codigo principal: pulando.' 'OK'; return }

    # 1) Flutter 3.22.3 separado
    if (-not (Test-Path -LiteralPath (Join-Path $Flutter322 '.git'))) {
        Rodar 'git' @('clone', '-b', 'stable', $FlutterRepo, $Flutter322) | Out-Null
    }
    $tag = ''
    if (-not $SomenteVerificar) { $tag = (& git -C $Flutter322 describe --tags --exact-match HEAD 2>$null) }
    if ($tag -ne '3.22.3') {
        Rodar 'git' @('-C', $Flutter322, 'fetch', '--tags', 'origin') | Out-Null
        Rodar 'git' @('-C', $Flutter322, 'checkout', '-B', 'stable', 'refs/tags/3.22.3') | Out-Null
    }
    if (-not $SomenteVerificar) { Rodar 'git' @('config', '--global', '--add', 'safe.directory', ($Flutter322 -replace '\\', '/')) -PodeFalhar | Out-Null }

    # 2) Ferramentas do bridge (instaladas em CARGO_HOME, no F:)
    $lista = ''
    if (-not $SomenteVerificar) { $lista = (& cargo install --list 2>&1 | Out-String) }
    if ($lista -notmatch ('cargo-expand v' + [regex]::Escape($CargoExpandVer))) {
        Rodar 'cargo' @('install', 'cargo-expand', '--version', $CargoExpandVer, '--locked') | Out-Null
    }
    if ($lista -notmatch ('flutter_rust_bridge_codegen v' + [regex]::Escape($BridgeVer))) {
        Rodar 'cargo' @('install', 'flutter_rust_bridge_codegen', '--version', $BridgeVer, '--features', 'uuid', '--locked') | Out-Null
    }

    # 3) Copia de trabalho (para nao alterar o pubspec do codigo principal)
    if ($SomenteVerificar) { Log "copiaria $Src para $BridgeWork e geraria o bridge la" 'FARIA'; return }
    if (Test-Path -LiteralPath $BridgeWork) { Remove-Item -LiteralPath $BridgeWork -Recurse -Force }
    Rodar 'robocopy' @($Src, $BridgeWork, '/E', '/XD', 'target', 'build', '.dart_tool', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -PodeFalhar | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE)" }
    $pub = Join-Path $BridgeWork 'flutter\pubspec.yaml'
    $t = [IO.File]::ReadAllText($pub)
    [IO.File]::WriteAllText($pub, $t.Replace('extended_text: 14.0.0', 'extended_text: 13.0.0'))

    # 4) pub get e codegen, com o Flutter 3.22.3 na frente do PATH (so neste processo)
    $pathAnt = $env:Path
    $env:Path = (Join-Path $Flutter322 'bin') + ';' + $env:Path
    try {
        Rodar 'flutter' @('--version') | Out-Null
        Rodar 'flutter' @('pub', 'get') -Pasta (Join-Path $BridgeWork 'flutter') | Out-Null
        # O ffigen procura bin\libclang.dll dentro da pasta raiz do LLVM (pai de LIBCLANG_PATH).
        $llvmRaiz = Split-Path -Parent $env:LIBCLANG_PATH
        Rodar 'flutter_rust_bridge_codegen' @('--rust-input', './src/flutter_ffi.rs', '--dart-output', './flutter/lib/generated_bridge.dart', '--c-output', './flutter/macos/Runner/bridge_generated.h', '--llvm-path', $llvmRaiz) -Pasta $BridgeWork | Out-Null

        # No Windows o ffigen gera "typedef bool = ..." (o clang nao resolve o bool do stdbool.h), o que
        # esconde o bool do Dart e contamina o generated_bridge.freezed.dart. No Linux (CI) essa linha nao
        # existe. Remove a linha e gera o freezed de novo a partir do arquivo limpo.
        $gb = Join-Path $BridgeWork 'flutter\lib\generated_bridge.dart'
        $gt = [IO.File]::ReadAllText($gb)
        $gx = [regex]'(?m)^typedef bool = ffi\.NativeFunction<[^\r\n]*;\r?\n(\r?\n)?'
        if ($gx.IsMatch($gt)) {
            [IO.File]::WriteAllText($gb, $gx.Replace($gt, ''))
            Log 'Removido typedef bool do generated_bridge.dart.' 'OK'
            Rodar 'flutter' @('pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs') -Pasta (Join-Path $BridgeWork 'flutter') | Out-Null
        }
        $fz = [IO.File]::ReadAllText((Join-Path $BridgeWork 'flutter\lib\generated_bridge.freezed.dart'))
        if ($fz -match 'NativeFunction<Int Function\(Pointer<Int>\)>') { throw 'generated_bridge.freezed.dart ainda contem o tipo contaminado (NativeFunction<Int ...>).' }
    } finally { $env:Path = $pathAnt }
    Copy-Item (Join-Path $BridgeWork 'flutter\macos\Runner\bridge_generated.h') (Join-Path $BridgeWork 'flutter\ios\Runner\bridge_generated.h') -Force

    # 5) Traz os arquivos gerados
    foreach ($a in ($arquivos + @('flutter\macos\Runner\bridge_generated.h', 'flutter\ios\Runner\bridge_generated.h'))) {
        $o = Join-Path $BridgeWork $a
        if (-not (Test-Path -LiteralPath $o)) { throw "Bridge nao gerou: $a" }
        Copy-Item -LiteralPath $o -Destination (Join-Path $Src $a) -Force
        Log "copiado: $a" 'OK'
    }
}

# ---------------------------------------------------------------------------
function Etapa-Engine {
    Log '== Etapa engine + patch do Flutter ==' 'INFO'
    $marca = Join-Path $Flutter '.engine-rustdesk-ok'
    $alvo = Join-Path $Flutter 'bin\cache\artifacts\engine\windows-x64-release'
    if (-not (Test-Path -LiteralPath $marca)) {
        Rodar 'flutter' @('doctor', '-v') -PodeFalhar | Out-Null
        Rodar 'flutter' @('precache', '--windows') | Out-Null
        if ($SomenteVerificar) { Log "baixaria $EngineUrl e sobrescreveria $alvo" 'FARIA' }
        else {
            if (-not (Test-Path -LiteralPath $alvo)) { throw "Engine padrao nao encontrado em $alvo (precache falhou?)" }
            New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
            $zip = Join-Path $Downloads 'windows-x64-release.zip'
            Log "ATENCAO: o engine vem de $EngineUrl, uma release 'main' sem versao fixa e sem hash oficial (o CI do RustDesk faz o mesmo). O SHA256 fica no log." 'AVISO'
            Rodar 'curl.exe' @('-L', '--fail', '--retry', '3', '--silent', '--show-error', '-o', $zip, $EngineUrl) | Out-Null
            Log ("SHA256 do engine: " + (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
            $tmp = Join-Path $Downloads 'engine-extraido'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            Copy-Item -Path (Join-Path $tmp '*') -Destination $alvo -Recurse -Force
            Set-Content -LiteralPath $marca -Value (Get-Date -Format s)
            Log 'Engine do RustDesk instalado.' 'OK'
        }
    } else { Log 'Engine do RustDesk ja instalado: pulando.' 'OK' }

    $patch = Join-Path $Src ('.github\patches\' + $PatchNome)
    if (-not (Test-Path -LiteralPath $patch)) { throw "Patch nao encontrado: $patch" }
    if ($SomenteVerificar) { Log "aplicaria $PatchNome no Flutter 3.24.5" 'FARIA'; return }
    Copy-Item -LiteralPath $patch -Destination (Join-Path $Flutter $PatchNome) -Force
    $rev = Rodar 'git' @('-C', $Flutter, 'apply', '--reverse', '--check', $PatchNome) -PodeFalhar
    if ($rev -eq 0) { Log 'Patch do Flutter ja aplicado: pulando.' 'OK' }
    else {
        Rodar 'git' @('-C', $Flutter, 'apply', $PatchNome) | Out-Null
        Log 'Patch do Flutter aplicado.' 'OK'
    }
}

# ---------------------------------------------------------------------------
function Etapa-Vcpkg {
    Log '== Etapa vcpkg (dependencias nativas, pode levar bastante tempo) ==' 'INFO'
    $exe = Join-Path $env:VCPKG_ROOT 'vcpkg.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "vcpkg.exe nao encontrado em $exe" }
    $env:VCPKG_DEFAULT_HOST_TRIPLET = $Triplet
    $r = Rodar $exe @('install', '--triplet', $Triplet, ('--x-install-root=' + $env:VCPKG_ROOT + '\installed')) -Pasta $Src -PodeFalhar
    if ($r -ne 0) {
        Log 'vcpkg falhou. Logs em buildtrees (procure *.log com "error").' 'ERRO'
        throw "vcpkg install falhou (codigo $r)"
    }
    Log 'Dependencias do vcpkg instaladas.' 'OK'
}

# ---------------------------------------------------------------------------
function Etapa-Build {
    Log '== Etapa build ==' 'INFO'
    foreach ($a in @('src\bridge_generated.rs', 'flutter\lib\generated_bridge.dart')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Src $a)) -and -not $SomenteVerificar) { throw "Falta $a. Rode a etapa bridge antes." }
    }
    $env:VCPKG_DEFAULT_HOST_TRIPLET = $Triplet
    Rodar 'python' @('build.py', '--portable', '--flutter', '--skip-portable-pack', '--hwcodec', '--vram') -Pasta $Src | Out-Null
    if ($SomenteVerificar) { Log "copiaria flutter\build\windows\x64\runner\Release para $Saida" 'FARIA'; return }
    $rel = Join-Path $Src 'flutter\build\windows\x64\runner\Release'
    if (-not (Test-Path -LiteralPath $rel)) { throw "Saida do build nao encontrada: $rel" }
    if (Test-Path -LiteralPath $Saida) { Remove-Item -LiteralPath $Saida -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Saida | Out-Null
    Copy-Item -Path (Join-Path $rel '*') -Destination $Saida -Recurse -Force
    # O executavel sai como rustdesk.exe: renomeia para o nome do produto.
    $exeOrig = Join-Path $Saida 'rustdesk.exe'
    if (Test-Path -LiteralPath $exeOrig) { Rename-Item -LiteralPath $exeOrig -NewName 'PubliSOS.exe' }
    Log ("Pronto. Arquivos em: $Saida") 'OK'
    Get-ChildItem -LiteralPath $Saida -File | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
function Etapa-Unico {
    Log '== Etapa unico (um so executavel) ==' 'INFO'
    $exe = Join-Path $Saida 'PubliSOS.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Nao achei $exe. Rode a etapa build antes." }
    $portable = Join-Path $Src 'libs\portable'
    Rodar 'python' @('-m', 'pip', 'install', '-r', 'requirements.txt') -Pasta $portable | Out-Null
    # generate.py comprime a pasta num data.bin e compila o empacotador (cargo build) com ele embutido.
    Rodar 'python' @('generate.py', '-f', $Saida, '-o', '.', '-e', 'PubliSOS.exe') -Pasta $portable | Out-Null
    if ($SomenteVerificar) { Log 'copiaria o empacotador para saida\unico\PubliSOS.exe' 'FARIA'; return }
    # libs\portable faz parte do workspace do RustDesk: o resultado sai no target da raiz.
    $pk = Join-Path $Src 'target\release\rustdesk-portable-packer.exe'
    if (-not (Test-Path -LiteralPath $pk)) { throw "Empacotador nao encontrado: $pk" }
    $dest = Join-Path $Base 'saida\unico'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -LiteralPath $pk -Destination (Join-Path $dest 'PubliSOS.exe') -Force
    $i = Get-Item (Join-Path $dest 'PubliSOS.exe')
    Log ("Pronto: {0} ({1:N1} MB)" -f $i.FullName, ($i.Length / 1MB)) 'OK'
}

Update-Ambiente
Import-Vcvars
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$logArq = Join-Path $Logs ('compilar-{0}-{1}.log' -f $Etapa, (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (-not $SomenteVerificar) { Start-Transcript -LiteralPath $logArq | Out-Null }
$inicio = Get-Date
$codigo = 0
try {
    Etapa-Preflight
    $etapas = @($Etapa)
    if ($Etapa -eq 'todas') { $etapas = @('bridge', 'engine', 'vcpkg', 'build') }
    foreach ($e in $etapas) {
        switch ($e) {
            'bridge' { Etapa-Bridge }
            'engine' { Etapa-Engine }
            'vcpkg'  { Etapa-Vcpkg }
            'build'  { Etapa-Build }
            'unico'  { Etapa-Unico }
        }
    }
    Log ('Concluido em {0:hh\:mm\:ss}.' -f ((Get-Date) - $inicio)) 'OK'
} catch {
    Log ('FALHOU: ' + $_.Exception.Message) 'ERRO'
    $codigo = 1
} finally {
    if (-not $SomenteVerificar) { Stop-Transcript | Out-Null; Write-Host "Log: $logArq" }
}
exit $codigo
