#Requires -Version 5.1
<#
.SYNOPSIS
    Prepara um PC Windows 11 para compilar o cliente RustDesk (Flutter) para Windows x64.

.DESCRIPTION
    Instala e configura, de forma idempotente, as ferramentas que o workflow oficial do
    RustDesk usa no build Windows x64:
      - Visual Studio 2022 Build Tools (carga VCTools, MSVC x64, Windows SDK) via winget
      - Python 3.12, Strawberry Perl, ImageMagick e PowerShell 7 via winget
      - Git Bash no PATH (usa o Git for Windows ja instalado)
      - NuGet (nuget.exe oficial da Microsoft)
      - LLVM 15.0.6 (instalador oficial do GitHub) e a variavel LIBCLANG_PATH
      - Rust 1.75 (rustup-init, toolchain pinada, target x86_64-pc-windows-msvc, rustfmt)
      - Flutter 3.24.5 (git clone, tag 3.24.5, canal stable)
      - vcpkg no commit 9e593bb18ea69cc5095e012465dcd675a822ed0d e a variavel VCPKG_ROOT

    Tudo que e pesado fica em -Base (padrao F:\rustdesk-build). Os caches (CARGO_HOME,
    RUSTUP_HOME, PUB_CACHE, VCPKG_DEFAULT_BINARY_CACHE, VCPKG_DOWNLOADS) apontam para la
    via variaveis de ambiente do Usuario (e do processo atual).

    Cada etapa verifica se a ferramenta ja esta na versao certa e pula se estiver.
    O script NAO compila o RustDesk.

    Este arquivo e propositalmente so ASCII (sem acentos) para ser lido corretamente
    pelo Windows PowerShell 5.1 sem BOM.

.PARAMETER SomenteVerificar
    Nao instala nem altera nada: nao cria pastas, nao grava log em arquivo, nao mexe em
    variaveis de ambiente nem no PATH. Mostra o estado atual, o que falta e o que seria
    feito. Pode rodar sem ser Administrador. -WhatIf tem o mesmo efeito.

.PARAMETER Base
    Pasta base de tudo. Padrao: F:\rustdesk-build. Nao pode conter espacos.

.PARAMETER MinGbLivres
    Espaco livre minimo (GB) exigido na unidade de -Base. Padrao: 60.

.PARAMETER PularVS
    Nao instala nem modifica o Visual Studio (use quando ja instalou manualmente).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\instalar-ambiente.ps1 -SomenteVerificar

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\instalar-ambiente.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\instalar-ambiente.ps1 -Base D:\rd -MinGbLivres 50 -PularVS
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SomenteVerificar,
    [string]$Base = 'F:\rustdesk-build',
    [ValidateRange(1, 4000)]
    [int]$MinGbLivres = 60,
    [switch]$PularVS
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -WhatIf vira o modo -SomenteVerificar (nenhuma acao e executada).
if ($WhatIfPreference) { $SomenteVerificar = [switch]$true }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ============================================================================
# Versoes pinadas (extraidas do workflow oficial do RustDesk)
# ============================================================================
$RustVersao    = '1.75'
$RustTarget    = 'x86_64-pc-windows-msvc'
$FlutterTag    = '3.24.5'
$FlutterRepo   = 'https://github.com/flutter/flutter.git'
$LlvmVersao    = '15.0.6'
$LlvmArquivo   = "LLVM-$LlvmVersao-win64.exe"
$LlvmUrl       = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersao/$LlvmArquivo"
$VcpkgRepo     = 'https://github.com/microsoft/vcpkg.git'
$VcpkgCommit   = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$RustupUrl     = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
$NugetUrl      = 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe'
$VsWingetId    = 'Microsoft.VisualStudio.2022.BuildTools'
$VsComponentes = @(
    'Microsoft.VisualStudio.Workload.VCTools',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.CMake.Project',
    'Microsoft.VisualStudio.Component.Windows11SDK.22621'
)

# ============================================================================
# Pastas (nao usar a variavel $dir em funcoes: PowerShell nao diferencia maiusculas)
# ============================================================================
$Base = [IO.Path]::GetFullPath($Base).TrimEnd('\')
$Caminhos = [ordered]@{
    Logs           = Join-Path $Base 'logs'
    Downloads      = Join-Path $Base 'downloads'
    Temp           = Join-Path $Base 'temp'
    Cargo          = Join-Path $Base 'cargo'
    Rustup         = Join-Path $Base 'rustup'
    PubCache       = Join-Path $Base 'pub-cache'
    Flutter        = Join-Path $Base 'flutter'
    LLVM           = Join-Path $Base 'llvm'
    Vcpkg          = Join-Path $Base 'vcpkg'
    VcpkgCache     = Join-Path $Base 'vcpkg-binary-cache'
    VcpkgDownloads = Join-Path $Base 'vcpkg-downloads'
    VS             = Join-Path $Base 'vs\BuildTools'
    VSShared       = Join-Path $Base 'vs\shared'
    Python         = Join-Path $Base 'python312'
    NuGet          = Join-Path $Base 'nuget'
}
$script:CargoBin = Join-Path $Caminhos.Cargo 'bin'

# ============================================================================
# Estado global
# ============================================================================
$script:Resultados       = New-Object System.Collections.Generic.List[object]
$script:ResultadoAtual   = $null
$script:LogFile          = $null
$script:PathAlterado     = $false
$script:PrecisaReiniciar = $false
$script:Abortar          = $false
$script:DevModeAtivo     = $true
$script:UsuarioAtual     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:EhAdmin          = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:TemWinget        = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
$script:TemCurl          = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
$script:TemGit           = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)

# ============================================================================
# Log e utilitarios
# ============================================================================
function Write-Log {
    param([string]$Mensagem = '', [string]$Nivel = 'INFO')
    $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensagem
    $cor = 'White'
    switch ($Nivel) {
        'OK'    { $cor = 'Green' }
        'AVISO' { $cor = 'Yellow' }
        'ERRO'  { $cor = 'Red' }
        'FARIA' { $cor = 'Cyan' }
        'CMD'   { $cor = 'DarkGray' }
        'SAIDA' { $cor = 'Gray' }
    }
    Write-Host $linha -ForegroundColor $cor
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $linha -Encoding UTF8 -WhatIf:$false } catch { }
    }
}

function Format-Comando {
    param([string]$Exe, [string[]]$Argumentos)
    $partes = @($Exe)
    foreach ($x in $Argumentos) {
        if ($x -match '\s') { $partes += ('"' + $x + '"') } else { $partes += $x }
    }
    return ($partes -join ' ')
}

# Executa um programa nativo, captura stdout+stderr, registra no log e devolve o codigo.
# ErrorActionPreference local = Continue: no PS 5.1, stderr redirecionado com Stop vira excecao.
function Invoke-Nativo {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Argumentos = @(),
        [switch]$Silencioso,
        [switch]$SemLog,
        [string]$IgnorarRegex = ''
    )
    $ErrorActionPreference = 'Continue'
    if (-not $SemLog) { Write-Log (Format-Comando $Exe $Argumentos) 'CMD' }
    $saida = New-Object System.Collections.Generic.List[string]
    $global:LASTEXITCODE = 0
    $codigo = 0
    try {
        & $Exe @Argumentos 2>&1 | ForEach-Object {
            $t = ([string]$_).TrimEnd()
            if ($t.Trim()) {
                $ignorar = ($IgnorarRegex -and ($t -match $IgnorarRegex))
                if (-not $ignorar) {
                    $saida.Add($t)
                    if (-not $Silencioso) { Write-Log $t 'SAIDA' }
                }
            }
        }
        $codigo = $global:LASTEXITCODE
    } catch {
        $saida.Add($_.Exception.Message)
        if (-not $SemLog) { Write-Log ("Falha ao executar {0}: {1}" -f $Exe, $_.Exception.Message) 'ERRO' }
        $codigo = -1
    }
    return [pscustomobject]@{ Codigo = $codigo; Saida = $saida.ToArray() }
}

# Primeira linha de saida de um comando de versao (ou a primeira que casa com $Padrao).
function Get-VersaoLinha {
    param([string]$Exe, [string[]]$Argumentos = @('--version'), [string]$Padrao = '')
    if (-not $Exe) { return $null }
    if ($Exe -match '[\\/]') { $existe = Test-Path -LiteralPath $Exe }
    else { $existe = [bool](Get-Command $Exe -ErrorAction SilentlyContinue) }
    if (-not $existe) { return $null }
    $r = Invoke-Nativo -Exe $Exe -Argumentos $Argumentos -Silencioso -SemLog
    $linhas = @($r.Saida | Where-Object { $_ -and $_.Trim() })
    if ($linhas.Count -eq 0) { return $null }
    if ($Padrao) {
        $m = @($linhas | Where-Object { $_ -match $Padrao })
        if ($m.Count -gt 0) { return $m[0].Trim() }
    }
    return $linhas[0].Trim()
}

# Primeiro candidato existente; senao, o que o PATH resolver para $Nome.
function Find-Exe {
    param([string[]]$Candidatos = @(), [string]$Nome = '', [switch]$IgnorarWindowsApps)
    foreach ($c in $Candidatos) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    if ($Nome) {
        $gs = @(Get-Command $Nome -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($g in $gs) {
            if ($IgnorarWindowsApps -and ($g.Source -like '*\Microsoft\WindowsApps\*')) { continue }
            return $g.Source
        }
    }
    return $null
}

function Set-Resultado {
    param([string]$Status, [string]$Detalhe = '')
    $script:ResultadoAtual = @{ Status = $Status; Detalhe = $Detalhe }
    $nivel = 'INFO'
    if ($Status -eq 'OK' -or $Status -eq 'PULOU') { $nivel = 'OK' }
    if ($Status -eq 'FARIA') { $nivel = 'FARIA' }
    Write-Log ("Resultado: {0} - {1}" -f $Status, $Detalhe) $nivel
}

function Invoke-Etapa {
    param([string]$Nome, [scriptblock]$Bloco)
    Write-Host ''
    Write-Log ('==================== {0} ====================' -f $Nome)
    $inicio = Get-Date
    $script:ResultadoAtual = $null
    $res = $null
    try {
        & $Bloco | Out-Null
        $res = $script:ResultadoAtual
        if (-not $res) { $res = @{ Status = 'OK'; Detalhe = '' } }
    } catch {
        $res = @{ Status = 'FALHOU'; Detalhe = $_.Exception.Message }
        Write-Log ("Etapa '{0}' FALHOU: {1}" -f $Nome, $_.Exception.Message) 'ERRO'
        if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERRO' }
    }
    $dur = (Get-Date) - $inicio
    $script:Resultados.Add([pscustomobject]@{
        Etapa   = $Nome
        Status  = $res.Status
        Duracao = ('{0:hh\:mm\:ss}' -f $dur)
        Detalhe = $res.Detalhe
    })
}

function Get-GbLivres {
    param([string]$Raiz)
    try {
        $d = New-Object System.IO.DriveInfo($Raiz)
        if ($d.IsReady) { return [math]::Round($d.AvailableFreeSpace / 1GB, 1) }
    } catch { }
    return $null
}

function Assert-Winget {
    if (-not $script:TemWinget) {
        throw 'winget nao esta disponivel. Instale ou atualize o "Instalador de Aplicativo" (App Installer) pela Microsoft Store e rode o script de novo.'
    }
}

function Assert-Git {
    if (-not $script:TemGit) { throw 'git nao encontrado no PATH. Instale o Git for Windows e rode de novo.' }
}

function New-Pasta {
    param([string]$Caminho)
    if (Test-Path -LiteralPath $Caminho) { return $false }
    if ($SomenteVerificar) { Write-Log "Criaria a pasta $Caminho" 'FARIA'; return $true }
    New-Item -ItemType Directory -Force -Path $Caminho | Out-Null
    Write-Log "Pasta criada: $Caminho"
    return $true
}

# ============================================================================
# Variaveis de ambiente e PATH (escopo Usuario + processo atual)
# ============================================================================
function Get-UserEnv {
    param([string]$Nome)
    return [Environment]::GetEnvironmentVariable($Nome, 'User')
}

# Devolve $true se precisou (ou precisaria) mudar algo.
function Set-UserEnv {
    param([string]$Nome, [string]$Valor)
    $atual = Get-UserEnv $Nome
    if ($atual -eq $Valor) {
        Write-Log "Variavel de usuario $Nome ja vale $Valor"
        if (-not $SomenteVerificar) { [Environment]::SetEnvironmentVariable($Nome, $Valor, 'Process') }
        return $false
    }
    if ($atual) { Write-Log ("Variavel de usuario {0} sera trocada: '{1}' -> '{2}'" -f $Nome, $atual, $Valor) 'AVISO' }
    if ($SomenteVerificar) { Write-Log "Definiria $Nome=$Valor (escopo Usuario e processo)" 'FARIA'; return $true }
    [Environment]::SetEnvironmentVariable($Nome, $Valor, 'User')
    [Environment]::SetEnvironmentVariable($Nome, $Valor, 'Process')
    Write-Log "Definida $Nome=$Valor (escopo Usuario e processo)" 'OK'
    return $true
}

# Le o PATH do usuario sem expandir %VARIAVEIS% (para nao estragar entradas existentes).
function Get-UserPathRaw {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $k) { return '' }
    try { return [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $k.Close() }
}

function Add-ProcessPath {
    param([string]$Pasta, [bool]$NoInicio = $false)
    foreach ($p in @($env:Path -split ';')) {
        if ($p -and ($p.Trim().TrimEnd('\') -ieq $Pasta)) { return }
    }
    if ($NoInicio) { $env:Path = "$Pasta;$env:Path" } else { $env:Path = "$env:Path;$Pasta" }
}

# Adiciona uma pasta ao PATH do usuario sem duplicar. Devolve $true se mudou (ou mudaria).
function Add-UserPath {
    param([string]$Pasta, [switch]$NoInicio)
    $alvo = $Pasta.Trim().TrimEnd('\')
    $itens = @((Get-UserPathRaw) -split ';' | Where-Object { $_ -and $_.Trim() })
    foreach ($it in $itens) {
        if ([Environment]::ExpandEnvironmentVariables($it).Trim().TrimEnd('\') -ieq $alvo) {
            Write-Log "PATH do usuario ja contem $alvo"
            if (-not $SomenteVerificar) { Add-ProcessPath -Pasta $alvo -NoInicio $NoInicio.IsPresent }
            return $false
        }
    }
    if ($SomenteVerificar) { Write-Log "Adicionaria ao PATH do usuario: $alvo" 'FARIA'; return $true }
    if ($NoInicio) { $novos = @($alvo) + $itens } else { $novos = $itens + @($alvo) }
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try { $k.SetValue('Path', ($novos -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $k.Close() }
    $script:PathAlterado = $true
    Add-ProcessPath -Pasta $alvo -NoInicio $NoInicio.IsPresent
    Write-Log "Adicionado ao PATH do usuario: $alvo" 'OK'
    return $true
}

# Recarrega no processo o PATH de Maquina + Usuario (depois de instaladores que mexem no PATH).
function Update-ProcessPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

# Evita o erro "dubious ownership" do git em pastas criadas por um processo elevado.
function Add-GitSafeDirectory {
    param([string]$Pasta)
    if (-not $script:TemGit) { return }
    $valor = $Pasta -replace '\\', '/'
    $r = Invoke-Nativo -Exe 'git' -Argumentos @('config', '--global', '--get-all', 'safe.directory') -Silencioso -SemLog
    if (($r.Saida -contains $valor) -or ($r.Saida -contains '*')) { return }
    if ($SomenteVerificar) { Write-Log "Executaria: git config --global --add safe.directory $valor" 'FARIA'; return }
    Invoke-Nativo -Exe 'git' -Argumentos @('config', '--global', '--add', 'safe.directory', $valor) | Out-Null
}

function Get-GitTag {
    param([string]$Repo)
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return $null }
    $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $Repo, 'describe', '--tags', '--exact-match', 'HEAD') -Silencioso -SemLog
    if ($r.Codigo -eq 0 -and $r.Saida.Count -gt 0) { return $r.Saida[0].Trim() }
    return $null
}

function Get-GitHead {
    param([string]$Repo)
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return $null }
    $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $Repo, 'rev-parse', 'HEAD') -Silencioso -SemLog
    if ($r.Codigo -eq 0 -and $r.Saida.Count -gt 0) { return $r.Saida[0].Trim() }
    return $null
}

# ============================================================================
# Downloads e integridade
# ============================================================================
function Get-TextoUrl {
    param([string]$Url)
    Write-Log "Lendo: $Url"
    if ($script:TemCurl) {
        $r = Invoke-Nativo -Exe 'curl.exe' -Argumentos @('-sSL', '--fail', $Url) -Silencioso -SemLog
        if ($r.Codigo -eq 0) { return ($r.Saida -join "`n") }
        Write-Log ("Nao foi possivel ler {0} (curl codigo {1})" -f $Url, $r.Codigo) 'AVISO'
        return $null
    }
    try { return [string](Invoke-WebRequest -Uri $Url -UseBasicParsing).Content }
    catch { Write-Log ("Nao foi possivel ler {0}: {1}" -f $Url, $_.Exception.Message) 'AVISO'; return $null }
}

# SHA256 que o GitHub publica para assets de release (campo "digest"). Releases antigas podem nao ter.
function Get-GitHubDigest {
    param([string]$Repo, [string]$Tag, [string]$Arquivo)
    $api = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    Write-Log "Consultando checksum publicado pelo GitHub: $api"
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'instalar-ambiente-ps1'; 'Accept' = 'application/vnd.github+json' }
        $asset = @($rel.assets | Where-Object { $_.name -eq $Arquivo }) | Select-Object -First 1
        if ($asset -and $asset.digest -and ([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) { return $Matches[1] }
        Write-Log "A API do GitHub nao trouxe SHA256 para $Arquivo." 'AVISO'
    } catch {
        Write-Log ("Nao foi possivel consultar a API do GitHub: {0}" -f $_.Exception.Message) 'AVISO'
    }
    return $null
}

function Save-Download {
    param(
        [string]$Url,
        [string]$Destino,
        [string]$Sha256Esperado = '',
        [string]$AssinanteEsperado = ''
    )
    Write-Log "Baixando URL: $Url"
    Write-Log "Destino: $Destino"
    $tmp = "$Destino.parcial"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    if ($script:TemCurl) {
        $r = Invoke-Nativo -Exe 'curl.exe' -Argumentos @('-L', '--fail', '--retry', '3', '--silent', '--show-error', '-o', $tmp, $Url)
        if ($r.Codigo -ne 0) { throw ("Falha no download (curl codigo {0}): {1}" -f $r.Codigo, $Url) }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    }
    if (-not (Test-Path -LiteralPath $tmp)) { throw "Download nao gerou arquivo: $Url" }
    Move-Item -LiteralPath $tmp -Destination $Destino -Force
    $hash = (Get-FileHash -LiteralPath $Destino -Algorithm SHA256).Hash
    Write-Log "SHA256 calculado: $hash"
    if ($Sha256Esperado) {
        if ($hash -ine $Sha256Esperado) {
            Remove-Item -LiteralPath $Destino -Force
            throw ("SHA256 NAO confere para {0}. Esperado {1}, obtido {2}. Arquivo apagado." -f $Url, $Sha256Esperado, $hash)
        }
        Write-Log 'Integridade verificada: SHA256 confere com o valor oficial publicado.' 'OK'
    } else {
        Write-Log 'Nao ha checksum oficial disponivel para este arquivo: NAO foi possivel verificar a integridade. O SHA256 acima fica registrado para conferencia manual.' 'AVISO'
    }
    if ($Destino -match '\.(exe|msi|dll)$') {
        $sig = Get-AuthenticodeSignature -LiteralPath $Destino
        $quem = '(sem certificado)'
        if ($sig.SignerCertificate) { $quem = $sig.SignerCertificate.Subject }
        Write-Log ("Assinatura Authenticode: {0} | {1}" -f $sig.Status, $quem)
        if ([string]$sig.Status -eq 'HashMismatch') {
            Remove-Item -LiteralPath $Destino -Force
            throw "Assinatura Authenticode invalida (HashMismatch) em $Destino. Arquivo apagado."
        }
        if ($AssinanteEsperado) {
            if (([string]$sig.Status -ne 'Valid') -or ($quem -notmatch [regex]::Escape($AssinanteEsperado))) {
                Remove-Item -LiteralPath $Destino -Force
                throw ("Assinatura esperada de '{0}' nao confirmada (status {1}, assinante {2}). Arquivo apagado." -f $AssinanteEsperado, $sig.Status, $quem)
            }
            Write-Log "Assinatura digital valida de $AssinanteEsperado." 'OK'
        }
    }
}

# ============================================================================
# winget
# ============================================================================
function Get-WingetComando {
    param([string]$Id, [string[]]$Extra = @())
    return @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $Extra
}

function Invoke-Winget {
    param([string]$Id, [string[]]$Extra = @())
    Assert-Winget
    $a = Get-WingetComando -Id $Id -Extra $Extra
    # Ignora linhas que sao so barra de progresso / spinner do winget.
    $r = Invoke-Nativo -Exe 'winget.exe' -Argumentos $a -IgnorarRegex '^\s*[-\\|/]\s*$|[\u2580-\u259F]'
    $c = [int]$r.Codigo
    $hex = '0x{0:X8}' -f $c
    Write-Log ("winget terminou com codigo {0} ({1})" -f $c, $hex)
    switch ($hex) {
        '0x8A150109' { $script:PrecisaReiniciar = $true; Write-Log 'winget informou que e preciso reiniciar para concluir a instalacao.' 'AVISO' }
        '0x8A15002B' { Write-Log 'winget: nenhuma atualizacao aplicavel (pacote provavelmente ja instalado).' 'AVISO' }
        '0x8A150061' { Write-Log 'winget: pacote ja instalado.' 'AVISO' }
    }
    if ($c -eq 3010 -or $c -eq 1641) { $script:PrecisaReiniciar = $true; Write-Log 'O instalador pediu reinicio do Windows.' 'AVISO' }
    return $c
}

# Etapa generica: detecta; se faltar, instala via winget; depois verifica de novo.
# $Detectar deve devolver um texto de versao quando a ferramenta certa esta no PATH, senao $null.
function Install-ViaWinget {
    param([string]$Id, [scriptblock]$Detectar, [string[]]$Extra = @(), [scriptblock]$PosInstalacao = $null)
    $v = & $Detectar
    if ($v) { Set-Resultado 'PULOU' "ja instalado: $v"; return }
    $txt = Format-Comando 'winget' (Get-WingetComando -Id $Id -Extra $Extra)
    if ($SomenteVerificar) {
        Write-Log "Executaria: $txt" 'FARIA'
        Set-Resultado 'FARIA' "instalar $Id via winget"
        return
    }
    $codigo = Invoke-Winget -Id $Id -Extra $Extra
    Update-ProcessPath
    if ($PosInstalacao) { & $PosInstalacao | Out-Null }
    $v = & $Detectar
    if (-not $v) { throw ("{0} nao foi detectado no PATH depois do winget (codigo {1}). Veja o log." -f $Id, $codigo) }
    Set-Resultado 'OK' $v
}

# ============================================================================
# Visual Studio
# ============================================================================
function Get-VsWhere {
    $vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vsw) { return $vsw }
    return $null
}

function Get-VSComCpp {
    $vsw = Get-VsWhere
    if (-not $vsw) { return $null }
    $r = Invoke-Nativo -Exe $vsw -Argumentos @('-latest', '-products', '*', '-version', '[17.0,18.0)',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath') -Silencioso -SemLog
    $p = @($r.Saida | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
    return $p
}

function Get-VSInstancia {
    $vsw = Get-VsWhere
    if (-not $vsw) { return $null }
    $r = Invoke-Nativo -Exe $vsw -Argumentos @('-latest', '-products', '*', '-version', '[17.0,18.0)', '-property', 'installationPath') -Silencioso -SemLog
    $p = @($r.Saida | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
    return $p
}

function Get-WindowsSdkVersoes {
    $inc = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
    if (-not (Test-Path -LiteralPath $inc)) { return @() }
    return @(Get-ChildItem -LiteralPath $inc -Directory |
        Where-Object { $_.Name -match '^10\.' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'um\windows.h')) } |
        ForEach-Object { $_.Name })
}

# ============================================================================
# ETAPAS
# ============================================================================
function Step-Preflight {
    $avisos = 0
    Write-Log ("Windows: {0}" -f [Environment]::OSVersion.VersionString)
    Write-Log ("PowerShell: {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-Log ("Usuario deste processo: {0}" -f $script:UsuarioAtual)
    Write-Log ("Pasta base: {0}" -f $Base)

    if ($script:EhAdmin) { Write-Log 'Executando como Administrador.' 'OK' }
    else { Write-Log 'NAO esta como Administrador (permitido somente no modo -SomenteVerificar).' 'AVISO'; $avisos++ }

    $console = $null
    try { $console = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName } catch { }
    if ($console -and ($console -ine $script:UsuarioAtual)) {
        Write-Log ("O usuario logado no console ({0}) e diferente do usuario deste processo ({1}). Variaveis e PATH do Usuario irao para {1}. Rode elevado com a MESMA conta que vai compilar." -f $console, $script:UsuarioAtual) 'AVISO'
        $avisos++
    }

    # Espaco em disco
    $raizBase = [IO.Path]::GetPathRoot($Base)
    $livreBase = Get-GbLivres $raizBase
    if ($null -eq $livreBase) { throw "Nao foi possivel ler o espaco livre de $raizBase" }
    Write-Log ("Espaco livre em {0}: {1} GB (minimo exigido: {2} GB)" -f $raizBase, $livreBase, $MinGbLivres)
    if ($livreBase -lt $MinGbLivres) {
        $msg = ("Espaco insuficiente em {0}: {1} GB livres, minimo {2} GB. Libere espaco ou ajuste -MinGbLivres." -f $raizBase, $livreBase, $MinGbLivres)
        if ($SomenteVerificar) { Write-Log $msg 'AVISO'; $avisos++ }
        else { $script:Abortar = $true; throw $msg }
    } else {
        Write-Log 'Espaco na unidade base suficiente.' 'OK'
    }

    $raizSistema = $env:SystemDrive + '\'
    $livreC = Get-GbLivres $raizSistema
    Write-Log ("Espaco livre em {0}: {1} GB" -f $raizSistema, $livreC)
    Write-Log 'ATENCAO: mesmo com --installPath no F:, o Visual Studio Installer, parte dos componentes e o Windows SDK (C:\Program Files (x86)\Windows Kits) ficam no C: e podem ocupar alguns GB (estimativa 3 a 6 GB). Strawberry Perl, ImageMagick e PowerShell 7 usam o local padrao no C: (estimativa 1 a 1,5 GB).' 'AVISO'
    if ($null -ne $livreC -and $livreC -lt 25) {
        Write-Log ("O C: tem so {0} GB livres. Acompanhe o espaco durante a instalacao do Visual Studio." -f $livreC) 'AVISO'
        $avisos++
    }

    # Ferramentas basicas
    if ($script:TemWinget) {
        $v = Get-VersaoLinha 'winget.exe' @('--version')
        Write-Log "winget encontrado: $v" 'OK'
    } else {
        Write-Log 'winget NAO encontrado. Instale/atualize o "Instalador de Aplicativo" (App Installer) pela Microsoft Store. As etapas via winget vao falhar.' 'AVISO'
        $avisos++
    }
    if ($script:TemCurl) { Write-Log 'curl.exe encontrado.' 'OK' }
    else { Write-Log 'curl.exe nao encontrado; downloads usarao Invoke-WebRequest.' 'AVISO' }
    if ($script:TemGit) { Write-Log ("git encontrado: {0}" -f (Get-VersaoLinha 'git' @('--version'))) 'OK' }
    else { Write-Log 'git NAO encontrado: Flutter e vcpkg vao falhar.' 'AVISO'; $avisos++ }

    # Avisos que o script NAO altera (configuracoes de sistema)
    $dev = $null
    try { $dev = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense } catch { }
    if ($dev -eq 1) { Write-Log 'Modo de Desenvolvedor do Windows ativo (necessario para symlinks dos plugins Flutter).' 'OK' }
    else {
        $script:DevModeAtivo = $false
        Write-Log 'Modo de Desenvolvedor do Windows parece DESATIVADO. O "flutter build windows" com plugins exige suporte a symlink. Ative manualmente em Configuracoes > Sistema > Para desenvolvedores (comando: start ms-settings:developers). O script NAO altera isso.' 'AVISO'
        $avisos++
    }
    $lp = $null
    try { $lp = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled } catch { }
    if ($lp -eq 1) { Write-Log 'Caminhos longos (LongPathsEnabled) ativos.' 'OK' }
    else { Write-Log 'LongPathsEnabled nao esta ativo. A pasta base curta ajuda, mas se aparecerem erros de caminho longo, avalie ativar. O script NAO altera isso.' 'AVISO' }

    foreach ($d in @((Join-Path $env:USERPROFILE '.cargo'), (Join-Path $env:USERPROFILE '.rustup'))) {
        if (Test-Path -LiteralPath $d) { Write-Log "Existe $d de uma instalacao anterior do Rust. Este script usa $Base; a pasta antiga nao sera usada nem apagada." 'AVISO' }
    }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'LLVM\bin\clang.exe')) {
        Write-Log "Existe outro LLVM em $env:ProgramFiles\LLVM. Se ele estiver no PATH de Maquina, pode ter prioridade sobre o LLVM 15.0.6 deste script." 'AVISO'
    }

    Set-Resultado 'OK' ("{0} aviso(s); {1} livres: {2} GB; C: livres: {3} GB" -f $avisos, $raizBase, $livreBase, $livreC)
}

function Step-Variaveis {
    $mud = 0
    foreach ($p in @($Caminhos.Logs, $Caminhos.Downloads, $Caminhos.Temp, $Caminhos.Cargo, $Caminhos.Rustup,
            $Caminhos.PubCache, $Caminhos.VcpkgCache, $Caminhos.VcpkgDownloads)) {
        if (New-Pasta $p) { $mud++ }
    }
    $vars = [ordered]@{
        RUSTDESK_BUILD_BASE        = $Base
        CARGO_HOME                 = $Caminhos.Cargo
        RUSTUP_HOME                = $Caminhos.Rustup
        PUB_CACHE                  = $Caminhos.PubCache
        VCPKG_DEFAULT_BINARY_CACHE = $Caminhos.VcpkgCache
        VCPKG_DOWNLOADS            = $Caminhos.VcpkgDownloads
    }
    foreach ($k in $vars.Keys) { if (Set-UserEnv $k $vars[$k]) { $mud++ } }

    # TEMP/TMP so neste processo: instaladores (VS, LLVM, rustup) extraem no F: e nao no C:.
    # Nao alteramos o TEMP do usuario para nao afetar outros programas.
    if ($SomenteVerificar) {
        Write-Log ("Usaria TEMP/TMP={0} apenas dentro deste processo (nao altera o TEMP do usuario)." -f $Caminhos.Temp) 'FARIA'
    } else {
        $env:TEMP = $Caminhos.Temp
        $env:TMP = $Caminhos.Temp
        Write-Log ("TEMP/TMP deste processo = {0} (o TEMP do usuario nao foi alterado)." -f $Caminhos.Temp)
    }

    if ($mud -eq 0) { Set-Resultado 'PULOU' 'pastas e variaveis ja configuradas' }
    elseif ($SomenteVerificar) { Set-Resultado 'FARIA' "$mud ajuste(s) de pastas/variaveis" }
    else { Set-Resultado 'OK' "$mud ajuste(s) de pastas/variaveis" }
}

function Step-VisualStudio {
    $vsCpp = Get-VSComCpp
    $sdks = @(Get-WindowsSdkVersoes)
    if ($vsCpp) { Write-Log "Visual Studio 2022 com MSVC x64 encontrado em: $vsCpp" 'OK' }
    else { Write-Log 'Visual Studio 2022 com MSVC x64 nao encontrado.' }
    if ($sdks.Count -gt 0) { Write-Log ("Windows SDK encontrado: {0}" -f ($sdks -join ', ')) 'OK' }
    else { Write-Log 'Windows 10/11 SDK nao encontrado.' }

    if ($vsCpp -and $sdks.Count -gt 0) { Set-Resultado 'PULOU' "ja instalado em $vsCpp"; return }
    if ($PularVS) {
        Write-Log '-PularVS informado: o Visual Studio nao sera instalado nem modificado, mas a deteccao acima indica que algo falta.' 'AVISO'
        Set-Resultado 'PULOU' '-PularVS (deteccao incompleta, confira manualmente)'
        return
    }

    $instancia = Get-VSInstancia
    $addArgs = @()
    foreach ($c in $VsComponentes) { $addArgs += @('--add', $c) }

    if ($instancia) {
        # Ja existe um VS 2022 (provavelmente sem C++ ou sem SDK): modificar a instancia existente.
        $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        $argTxt = ('modify --installPath "{0}" {1} --includeRecommended --quiet --norestart --nocache' -f $instancia, ($addArgs -join ' '))
        if ($SomenteVerificar) {
            Write-Log ("Executaria: `"{0}`" {1}" -f $setup, $argTxt) 'FARIA'
            Set-Resultado 'FARIA' "adicionar componentes C++/SDK na instancia existente $instancia"
            return
        }
        if (-not (Test-Path -LiteralPath $setup)) { throw "Instalador do VS nao encontrado em $setup" }
        Write-Log ("`"{0}`" {1}" -f $setup, $argTxt) 'CMD'
        $p = Start-Process -FilePath $setup -ArgumentList $argTxt -Wait -PassThru
        Write-Log ("Visual Studio Installer terminou com codigo {0}" -f $p.ExitCode)
        if ($p.ExitCode -eq 3010) { $script:PrecisaReiniciar = $true }
        elseif ($p.ExitCode -ne 0) { Write-Log 'Codigo diferente de 0; a verificacao abaixo decide se deu certo.' 'AVISO' }
    } else {
        $ov = @('--installPath', $Caminhos.VS) + $addArgs + @('--includeRecommended', '--quiet', '--wait', '--norestart', '--nocache')
        $installerJa = Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe')
        if (-not $installerJa) {
            # Componentes compartilhados no F:. So vale na primeira instalacao do VS na maquina.
            $ov += @('--path', ("shared=" + $Caminhos.VSShared))
        }
        $ovTxt = $ov -join ' '
        $extra = @('--override', $ovTxt)
        if ($SomenteVerificar) {
            Write-Log ("Executaria: {0}" -f (Format-Comando 'winget' (Get-WingetComando -Id $VsWingetId -Extra $extra))) 'FARIA'
            Set-Resultado 'FARIA' ("instalar {0} em {1}" -f $VsWingetId, $Caminhos.VS)
            return
        }
        Write-Log 'Instalando Visual Studio 2022 Build Tools. Pode levar de 15 a 60 minutos, sem muita saida no console.'
        Write-Log ("Logs do instalador do VS: {0}\dd_*.log" -f $env:TEMP)
        Invoke-Winget -Id $VsWingetId -Extra $extra | Out-Null
    }

    $vsCpp = Get-VSComCpp
    $sdks = @(Get-WindowsSdkVersoes)
    if (-not $vsCpp) { throw ("Visual Studio com MSVC x64 nao foi detectado depois da instalacao. Veja {0}\dd_*.log" -f $env:TEMP) }
    if ($sdks.Count -eq 0) { throw 'MSVC instalado, mas o Windows SDK nao foi detectado.' }
    Set-Resultado 'OK' ("{0}; SDK {1}" -f $vsCpp, ($sdks -join ', '))
}

function Step-Python {
    $detectar = {
        $l = Get-VersaoLinha 'python' @('--version') '^Python '
        if ($l -match '^Python 3\.12\.') { return ("{0} ({1})" -f $l, (Find-Exe -Nome 'python' -IgnorarWindowsApps)) }
        if ($l) { Write-Log "python no PATH nao e 3.12: $l" }
        return $null
    }
    $pos = {
        $py = Join-Path $Caminhos.Python 'python.exe'
        if ((Test-Path -LiteralPath $py) -and -not ((Get-VersaoLinha 'python' @('--version')) -match '^Python 3\.12\.')) {
            # O alias da Microsoft Store fica no PATH do usuario; por isso adiciona no inicio.
            Add-UserPath -Pasta (Join-Path $Caminhos.Python 'Scripts') -NoInicio | Out-Null
            Add-UserPath -Pasta $Caminhos.Python -NoInicio | Out-Null
        }
    }
    $override = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1 TargetDir=$($Caminhos.Python)"
    Install-ViaWinget -Id 'Python.Python.3.12' -Detectar $detectar -Extra @('--override', $override) -PosInstalacao $pos
}

function Step-GitBash {
    $cands = @()
    try {
        $ip = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\GitForWindows' -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
        if ($ip) { $cands += $ip }
    } catch { }
    $g = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { $cands += (Split-Path (Split-Path $g.Source -Parent) -Parent) }
    $cands += (Join-Path $env:ProgramFiles 'Git')
    $gitBin = $null
    foreach ($c in $cands) {
        $b = Join-Path $c 'bin'
        if (Test-Path -LiteralPath (Join-Path $b 'bash.exe')) { $gitBin = $b; break }
    }
    if (-not $gitBin) { throw 'Nao achei a pasta bin do Git for Windows (bash.exe). Confirme a instalacao do Git.' }
    Write-Log "Git Bash encontrado em $gitBin\bash.exe"

    $wsl = Join-Path $env:SystemRoot 'System32\bash.exe'
    if (Test-Path -LiteralPath $wsl) {
        Write-Log "Existe $wsl (bash do WSL). Como System32 vem antes no PATH de Maquina, 'bash' pode resolver para o WSL e nao para o Git Bash. Confira com 'where.exe bash' num terminal novo." 'AVISO'
    }
    $mudou = Add-UserPath $gitBin
    if (-not $mudou) { Set-Resultado 'PULOU' "$gitBin ja esta no PATH do usuario" }
    elseif ($SomenteVerificar) { Set-Resultado 'FARIA' "adicionar $gitBin ao PATH do usuario" }
    else { Set-Resultado 'OK' "$gitBin adicionado ao PATH do usuario" }
}

function Step-Perl {
    $detectar = {
        $g = @(Get-Command perl.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\Git\usr\bin\*' }) | Select-Object -First 1
        if (-not $g) { return $null }
        $l = Get-VersaoLinha $g.Source @('--version') 'perl 5'
        if ($l -match 'perl 5') { return ("{0} ({1})" -f $l, $g.Source) }
        return $null
    }
    $pos = {
        if (-not (Get-Command perl.exe -ErrorAction SilentlyContinue)) {
            foreach ($d in @('C:\Strawberry\perl\bin', 'C:\Strawberry\c\bin')) {
                if (Test-Path -LiteralPath $d) { Add-UserPath $d | Out-Null }
            }
        }
    }
    Install-ViaWinget -Id 'StrawberryPerl.StrawberryPerl' -Detectar $detectar -PosInstalacao $pos
}

function Step-ImageMagick {
    $detectar = {
        $l = Get-VersaoLinha 'magick' @('--version') 'ImageMagick'
        if ($l -match 'ImageMagick') { return $l }
        return $null
    }
    $pos = {
        if (-not (Get-Command magick.exe -ErrorAction SilentlyContinue)) {
            $d = Get-ChildItem -Path $env:ProgramFiles -Directory -Filter 'ImageMagick-*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($d -and (Test-Path -LiteralPath (Join-Path $d.FullName 'magick.exe'))) { Add-UserPath $d.FullName | Out-Null }
        }
    }
    Install-ViaWinget -Id 'ImageMagick.ImageMagick' -Detectar $detectar -PosInstalacao $pos
}

function Step-PowerShell7 {
    $detectar = {
        $l = Get-VersaoLinha 'pwsh' @('--version') '^PowerShell'
        if ($l -match '^PowerShell 7\.') { return $l }
        return $null
    }
    $pos = {
        if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
            $d = Join-Path $env:ProgramFiles 'PowerShell\7'
            if (Test-Path -LiteralPath (Join-Path $d 'pwsh.exe')) { Add-UserPath $d | Out-Null }
        }
    }
    Install-ViaWinget -Id 'Microsoft.PowerShell' -Detectar $detectar -PosInstalacao $pos
}

function Step-NuGet {
    $exe = Join-Path $Caminhos.NuGet 'nuget.exe'
    $atual = Find-Exe -Candidatos @($exe) -Nome 'nuget'
    if ($atual) {
        $v = Get-VersaoLinha $atual @('help') 'NuGet Version'
        if ($v) {
            if ($atual -ieq $exe) { Add-UserPath $Caminhos.NuGet | Out-Null }
            Set-Resultado 'PULOU' ("{0} ({1})" -f $v, $atual)
            return
        }
    }
    if ($SomenteVerificar) {
        Write-Log "Baixaria: $NugetUrl" 'FARIA'
        Write-Log "Salvaria em: $exe (e conferiria a assinatura digital da Microsoft)" 'FARIA'
        Add-UserPath $Caminhos.NuGet | Out-Null
        Set-Resultado 'FARIA' "baixar nuget.exe para $($Caminhos.NuGet)"
        return
    }
    New-Pasta $Caminhos.NuGet | Out-Null
    Write-Log 'O nuget.exe oficial nao tem SHA256 publicado; a integridade e conferida pela assinatura Authenticode da Microsoft.'
    Save-Download -Url $NugetUrl -Destino $exe -AssinanteEsperado 'Microsoft Corporation'
    Add-UserPath $Caminhos.NuGet | Out-Null
    $v = Get-VersaoLinha $exe @('help') 'NuGet Version'
    if (-not $v) { throw 'nuget.exe baixado, mas nao respondeu ao comando help.' }
    Set-Resultado 'OK' $v
}

function Step-LLVM {
    $llvmBin = Join-Path $Caminhos.LLVM 'bin'
    $clang = Join-Path $llvmBin 'clang.exe'
    $libclang = Join-Path $llvmBin 'libclang.dll'
    $v = Get-VersaoLinha $clang @('--version') 'clang version'
    $ok = ($v -match ('clang version ' + [regex]::Escape($LlvmVersao))) -and (Test-Path -LiteralPath $libclang)
    if ($ok) {
        Write-Log "LLVM ja instalado: $v" 'OK'
        Set-UserEnv 'LIBCLANG_PATH' $llvmBin | Out-Null
        Add-UserPath $llvmBin | Out-Null
        Set-Resultado 'PULOU' "ja instalado: $v"
        return
    }
    if ($v) { Write-Log "Versao diferente em ${clang}: $v. Sera instalado o $LlvmVersao por cima." 'AVISO' }

    $inst = Join-Path $Caminhos.Downloads $LlvmArquivo
    $instArgs = @('/S', ('/D=' + $Caminhos.LLVM))
    if ($SomenteVerificar) {
        Write-Log "Baixaria: $LlvmUrl" 'FARIA'
        Write-Log "Consultaria o SHA256 publicado em https://api.github.com/repos/llvm/llvm-project/releases/tags/llvmorg-$LlvmVersao (se existir)" 'FARIA'
        Write-Log ("Executaria: {0} {1}" -f $inst, ($instArgs -join ' ')) 'FARIA'
        Set-UserEnv 'LIBCLANG_PATH' $llvmBin | Out-Null
        Add-UserPath $llvmBin | Out-Null
        Set-Resultado 'FARIA' "instalar LLVM $LlvmVersao em $($Caminhos.LLVM)"
        return
    }

    New-Pasta $Caminhos.Downloads | Out-Null
    $sha = Get-GitHubDigest -Repo 'llvm/llvm-project' -Tag "llvmorg-$LlvmVersao" -Arquivo $LlvmArquivo
    if (-not $sha) {
        Write-Log 'Sem SHA256 oficial para o instalador do LLVM. Se a release tiver arquivo .sig (GPG), a conferencia precisa ser manual; este script nao verifica GPG.' 'AVISO'
    }
    Save-Download -Url $LlvmUrl -Destino $inst -Sha256Esperado $sha
    Write-Log ("{0} {1}" -f $inst, ($instArgs -join ' ')) 'CMD'
    $p = Start-Process -FilePath $inst -ArgumentList $instArgs -Wait -PassThru
    Write-Log ("Instalador do LLVM terminou com codigo {0}" -f $p.ExitCode)
    if ($p.ExitCode -ne 0) { throw "Instalador do LLVM retornou codigo $($p.ExitCode)" }

    $v = Get-VersaoLinha $clang @('--version') 'clang version'
    if ($v -notmatch ('clang version ' + [regex]::Escape($LlvmVersao))) { throw "clang $LlvmVersao nao detectado em $clang depois da instalacao (obtido: $v)" }
    if (-not (Test-Path -LiteralPath $libclang)) { throw "libclang.dll nao encontrado em $llvmBin" }
    Set-UserEnv 'LIBCLANG_PATH' $llvmBin | Out-Null
    Add-UserPath $llvmBin | Out-Null
    Set-Resultado 'OK' $v
}

function Get-RustEstado {
    $rustupExe = Join-Path $script:CargoBin 'rustup.exe'
    $estado = @{ Rustup = $false; Toolchain = $false; Default = $false; Target = $false; Rustfmt = $false; Rustc = $null }
    if (-not (Test-Path -LiteralPath $rustupExe)) { return $estado }
    $estado.Rustup = $true
    $antCargo = $env:CARGO_HOME
    $antRustup = $env:RUSTUP_HOME
    try {
        # So no processo e restaurado no finally (necessario para consultar o rustup do F:).
        [Environment]::SetEnvironmentVariable('CARGO_HOME', $Caminhos.Cargo, 'Process')
        [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $Caminhos.Rustup, 'Process')
        $tl = @((Invoke-Nativo -Exe $rustupExe -Argumentos @('toolchain', 'list') -Silencioso -SemLog).Saida)
        $padraoTc = '^' + [regex]::Escape($RustVersao) + '(\.\d+)?-' + [regex]::Escape($RustTarget)
        $linhasTc = @($tl | Where-Object { $_ -match $padraoTc })
        $estado.Toolchain = ($linhasTc.Count -gt 0)
        $estado.Default = (@($linhasTc | Where-Object { $_ -match 'default' }).Count -gt 0)
        if ($estado.Toolchain) {
            $tg = @((Invoke-Nativo -Exe $rustupExe -Argumentos @('target', 'list', '--installed', '--toolchain', $RustVersao) -Silencioso -SemLog).Saida)
            $estado.Target = ($tg -contains $RustTarget)
            $cp = @((Invoke-Nativo -Exe $rustupExe -Argumentos @('component', 'list', '--installed', '--toolchain', $RustVersao) -Silencioso -SemLog).Saida)
            $estado.Rustfmt = (@($cp | Where-Object { $_ -match '^rustfmt' }).Count -gt 0)
            $estado.Rustc = Get-VersaoLinha $rustupExe @('run', $RustVersao, 'rustc', '--version') '^rustc '
        }
    } finally {
        [Environment]::SetEnvironmentVariable('CARGO_HOME', $antCargo, 'Process')
        [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $antRustup, 'Process')
    }
    return $estado
}

function Step-Rust {
    $outro = Get-Command rustup.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($outro -and ($outro.Source -notlike ($script:CargoBin + '*'))) {
        Write-Log ("Ha outro rustup no PATH: {0}. Ele pode ter prioridade sobre {1}." -f $outro.Source, $script:CargoBin) 'AVISO'
    }
    $e = Get-RustEstado
    Write-Log ("Estado Rust: rustup={0} toolchain {1}={2} default={3} target={4} rustfmt={5} rustc='{6}'" -f $e.Rustup, $RustVersao, $e.Toolchain, $e.Default, $e.Target, $e.Rustfmt, $e.Rustc)
    if ($e.Rustup -and $e.Toolchain -and $e.Default -and $e.Target -and $e.Rustfmt) {
        Add-UserPath $script:CargoBin | Out-Null
        Set-Resultado 'PULOU' ("{0}, target {1}, rustfmt" -f $e.Rustc, $RustTarget)
        return
    }

    $initArgs = @('-y', '--no-modify-path', '--profile', 'minimal', '--default-host', $RustTarget,
        '--default-toolchain', $RustVersao, '--component', 'rustfmt', '--target', $RustTarget)
    $rustupExe = Join-Path $script:CargoBin 'rustup.exe'
    $cmds = New-Object System.Collections.Generic.List[object]
    $cmds.Add(@('toolchain', 'install', $RustVersao, '--profile', 'minimal', '--component', 'rustfmt', '--target', $RustTarget))
    $cmds.Add(@('default', $RustVersao))
    $cmds.Add(@('component', 'add', 'rustfmt', '--toolchain', $RustVersao))
    $cmds.Add(@('target', 'add', $RustTarget, '--toolchain', $RustVersao))

    if ($SomenteVerificar) {
        if (-not $e.Rustup) {
            Write-Log "Baixaria: $RustupUrl" 'FARIA'
            Write-Log "Conferiria o SHA256 oficial em $RustupUrl.sha256" 'FARIA'
            Write-Log ("Executaria (com CARGO_HOME={0} e RUSTUP_HOME={1}): rustup-init.exe {2}" -f $Caminhos.Cargo, $Caminhos.Rustup, ($initArgs -join ' ')) 'FARIA'
        } else {
            foreach ($c in $cmds) { Write-Log ("Executaria: rustup {0}" -f ($c -join ' ')) 'FARIA' }
        }
        Add-UserPath $script:CargoBin | Out-Null
        Set-Resultado 'FARIA' "instalar Rust $RustVersao ($RustTarget, rustfmt)"
        return
    }

    if (-not (Get-VSComCpp)) {
        throw 'MSVC (Visual Studio Build Tools com C++) nao encontrado. Sem ele o rustup-init tentaria instalar o Visual Studio Community por conta propria. Conclua a etapa do Visual Studio e rode o script de novo.'
    }
    [Environment]::SetEnvironmentVariable('CARGO_HOME', $Caminhos.Cargo, 'Process')
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $Caminhos.Rustup, 'Process')

    if (-not $e.Rustup) {
        New-Pasta $Caminhos.Downloads | Out-Null
        $init = Join-Path $Caminhos.Downloads 'rustup-init.exe'
        $sha = $null
        $txt = Get-TextoUrl "$RustupUrl.sha256"
        if ($txt -and ($txt -match '([0-9a-fA-F]{64})')) { $sha = $Matches[1]; Write-Log "SHA256 oficial do rustup-init: $sha" }
        Save-Download -Url $RustupUrl -Destino $init -Sha256Esperado $sha
        $r = Invoke-Nativo -Exe $init -Argumentos $initArgs
        if ($r.Codigo -ne 0) { throw "rustup-init falhou (codigo $($r.Codigo))" }
    } else {
        foreach ($c in $cmds) {
            $r = Invoke-Nativo -Exe $rustupExe -Argumentos $c
            if ($r.Codigo -ne 0) { throw ("rustup {0} falhou (codigo {1})" -f ($c -join ' '), $r.Codigo) }
        }
    }
    Add-UserPath $script:CargoBin | Out-Null

    $e = Get-RustEstado
    if (-not ($e.Rustup -and $e.Toolchain -and $e.Default -and $e.Target -and $e.Rustfmt)) {
        throw ("Rust incompleto depois da instalacao: toolchain={0} default={1} target={2} rustfmt={3}" -f $e.Toolchain, $e.Default, $e.Target, $e.Rustfmt)
    }
    Set-Resultado 'OK' ("{0}, target {1}, rustfmt" -f $e.Rustc, $RustTarget)
}

function Step-Flutter {
    $repo = $Caminhos.Flutter
    $flutterBin = Join-Path $repo 'bin'
    $bat = Join-Path $flutterBin 'flutter.bat'
    $dart = Join-Path $flutterBin 'cache\dart-sdk\bin\dart.exe'
    if ((-not $SomenteVerificar) -and (Test-Path -LiteralPath $repo)) { Add-GitSafeDirectory $repo }

    $tagAtual = Get-GitTag $repo
    $tagOk = ($tagAtual -eq $FlutterTag)
    $cacheOk = Test-Path -LiteralPath $dart
    Write-Log ("Flutter: pasta={0} tag atual='{1}' cache dart={2}" -f $repo, $tagAtual, $cacheOk)
    if ($tagOk -and $cacheOk) {
        Add-GitSafeDirectory $repo
        Add-UserPath $flutterBin | Out-Null
        Set-Resultado 'PULOU' "Flutter $FlutterTag ja presente em $repo"
        return
    }

    if ($SomenteVerificar) {
        if (-not (Test-Path -LiteralPath $repo)) { Write-Log ("Executaria: git clone -b stable {0} {1}" -f $FlutterRepo, $repo) 'FARIA' }
        elseif (-not $tagOk) { Write-Log ("Executaria: git -C {0} fetch --tags origin" -f $repo) 'FARIA' }
        if (-not $tagOk) { Write-Log ("Executaria: git -C {0} checkout -B stable refs/tags/{1}  (canal stable na tag {1})" -f $repo, $FlutterTag) 'FARIA' }
        Add-GitSafeDirectory $repo
        Add-UserPath $flutterBin | Out-Null
        Write-Log 'Executaria: flutter config --no-analytics; flutter config --enable-windows-desktop; flutter precache --windows; flutter --version' 'FARIA'
        Set-Resultado 'FARIA' "clonar/ajustar Flutter $FlutterTag em $repo"
        return
    }

    Assert-Git
    if (-not (Test-Path -LiteralPath $repo)) {
        Write-Log "Clonando $FlutterRepo"
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('clone', '-b', 'stable', $FlutterRepo, $repo)
        if ($r.Codigo -ne 0) { throw "git clone do Flutter falhou (codigo $($r.Codigo))" }
        Add-GitSafeDirectory $repo
    } elseif (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        throw "A pasta $repo existe mas nao e um repositorio git. Renomeie ou apague e rode de novo."
    } elseif (-not $tagOk) {
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'fetch', '--tags', 'origin')
        if ($r.Codigo -ne 0) { throw "git fetch do Flutter falhou (codigo $($r.Codigo))" }
    }
    if (-not $tagOk) {
        # Branch local "stable" (que segue origin/stable) posicionado na tag: o Flutter reporta canal stable e versao 3.24.5.
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'checkout', '-B', 'stable', "refs/tags/$FlutterTag")
        if ($r.Codigo -ne 0) { throw "git checkout da tag $FlutterTag falhou (codigo $($r.Codigo))" }
        $tagAtual = Get-GitTag $repo
        if ($tagAtual -ne $FlutterTag) { throw "Depois do checkout, a tag atual e '$tagAtual' e nao $FlutterTag" }
    }
    Add-UserPath $flutterBin | Out-Null
    [Environment]::SetEnvironmentVariable('PUB_CACHE', $Caminhos.PubCache, 'Process')

    Invoke-Nativo -Exe $bat -Argumentos @('config', '--no-analytics') | Out-Null
    Invoke-Nativo -Exe $bat -Argumentos @('config', '--enable-windows-desktop') | Out-Null
    $r = Invoke-Nativo -Exe $bat -Argumentos @('precache', '--windows')
    if ($r.Codigo -ne 0) { throw "flutter precache --windows falhou (codigo $($r.Codigo))" }
    $v = Get-VersaoLinha $bat @('--version') '^Flutter '
    if ($v -notmatch ('^Flutter ' + [regex]::Escape($FlutterTag) + '\b')) { throw "flutter --version nao mostrou $FlutterTag (obtido: $v)" }
    Set-Resultado 'OK' $v
}

function Step-Vcpkg {
    $repo = $Caminhos.Vcpkg
    $exe = Join-Path $repo 'vcpkg.exe'
    if ((-not $SomenteVerificar) -and (Test-Path -LiteralPath $repo)) { Add-GitSafeDirectory $repo }
    $head = Get-GitHead $repo
    $ok = ($head -eq $VcpkgCommit) -and (Test-Path -LiteralPath $exe)
    Write-Log ("vcpkg: pasta={0} HEAD='{1}' vcpkg.exe={2}" -f $repo, $head, (Test-Path -LiteralPath $exe))
    if ($ok) {
        Add-GitSafeDirectory $repo
        Set-UserEnv 'VCPKG_ROOT' $repo | Out-Null
        Add-UserPath $repo | Out-Null
        Set-Resultado 'PULOU' "vcpkg no commit $VcpkgCommit"
        return
    }

    if ($SomenteVerificar) {
        if (-not (Test-Path -LiteralPath $repo)) { Write-Log ("Executaria: git clone {0} {1}" -f $VcpkgRepo, $repo) 'FARIA' }
        else { Write-Log ("Executaria: git -C {0} fetch origin" -f $repo) 'FARIA' }
        Write-Log ("Executaria: git -C {0} checkout {1}" -f $repo, $VcpkgCommit) 'FARIA'
        Write-Log ("Executaria: {0}\bootstrap-vcpkg.bat -disableMetrics" -f $repo) 'FARIA'
        Add-GitSafeDirectory $repo
        Set-UserEnv 'VCPKG_ROOT' $repo | Out-Null
        Add-UserPath $repo | Out-Null
        Set-Resultado 'FARIA' "clonar vcpkg no commit $VcpkgCommit"
        return
    }

    Assert-Git
    if (-not (Test-Path -LiteralPath $repo)) {
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('clone', $VcpkgRepo, $repo)
        if ($r.Codigo -ne 0) { throw "git clone do vcpkg falhou (codigo $($r.Codigo))" }
        Add-GitSafeDirectory $repo
    } elseif (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        throw "A pasta $repo existe mas nao e um repositorio git. Renomeie ou apague e rode de novo."
    } elseif ($head -ne $VcpkgCommit) {
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'fetch', 'origin')
        if ($r.Codigo -ne 0) { throw "git fetch do vcpkg falhou (codigo $($r.Codigo))" }
    }
    if ($head -ne $VcpkgCommit) {
        $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'checkout', $VcpkgCommit)
        if ($r.Codigo -ne 0) {
            Write-Log 'Commit nao encontrado no clone; tentando buscar o commit diretamente.' 'AVISO'
            $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'fetch', 'origin', $VcpkgCommit)
            $r = Invoke-Nativo -Exe 'git' -Argumentos @('-C', $repo, 'checkout', $VcpkgCommit)
            if ($r.Codigo -ne 0) { throw "git checkout $VcpkgCommit falhou (codigo $($r.Codigo))" }
        }
        if ((Get-GitHead $repo) -ne $VcpkgCommit) { throw "HEAD do vcpkg nao ficou em $VcpkgCommit" }
    }
    $boot = Join-Path $repo 'bootstrap-vcpkg.bat'
    $r = Invoke-Nativo -Exe $boot -Argumentos @('-disableMetrics')
    if ($r.Codigo -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "bootstrap-vcpkg.bat falhou (codigo $($r.Codigo))" }
    Set-UserEnv 'VCPKG_ROOT' $repo | Out-Null
    Add-UserPath $repo | Out-Null
    $v = Get-VersaoLinha $exe @('version') 'version'
    Set-Resultado 'OK' ("{0} (commit {1})" -f $v, $VcpkgCommit)
}

# ============================================================================
# Resumo e verificacao final
# ============================================================================
function Write-Tabela {
    param($Objetos, [string[]]$Colunas)
    $txt = $Objetos | Format-Table -Property $Colunas -AutoSize -Wrap | Out-String -Width 220
    foreach ($l in ($txt -split "`r?`n")) { if ($l.Trim()) { Write-Log $l } }
}

function Show-Resumo {
    Write-Host ''
    Write-Log '============================== RESUMO =============================='
    Write-Tabela -Objetos $script:Resultados -Colunas @('Etapa', 'Status', 'Duracao', 'Detalhe')
    $grupos = $script:Resultados | Group-Object Status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
    Write-Log ('Totais: ' + ($grupos -join ', '))
}

function Show-Versoes {
    Write-Host ''
    Write-Log '======================= VERIFICACAO DE VERSOES ======================='
    Update-ProcessPath
    if (-not $SomenteVerificar) {
        foreach ($n in @('CARGO_HOME', 'RUSTUP_HOME', 'PUB_CACHE', 'LIBCLANG_PATH', 'VCPKG_ROOT')) {
            $v = Get-UserEnv $n
            if ($v) { [Environment]::SetEnvironmentVariable($n, $v, 'Process') }
        }
    }
    $flutterBat = Join-Path $Caminhos.Flutter 'bin\flutter.bat'
    $itens = @(
        @{ N = 'rustc';   E = '1.75.x';      X = (Find-Exe @((Join-Path $script:CargoBin 'rustc.exe')) 'rustc');     A = @('--version'); P = '^rustc ';       R = '^rustc 1\.75\.' },
        @{ N = 'cargo';   E = '1.75.x';      X = (Find-Exe @((Join-Path $script:CargoBin 'cargo.exe')) 'cargo');     A = @('--version'); P = '^cargo ';       R = '^cargo 1\.75\.' },
        @{ N = 'rustfmt'; E = 'presente';    X = (Find-Exe @((Join-Path $script:CargoBin 'rustfmt.exe')) 'rustfmt'); A = @('--version'); P = '^rustfmt';      R = '^rustfmt' },
        @{ N = 'flutter'; E = $FlutterTag;   X = $null;                                                               A = @();            P = '';              R = '' },
        @{ N = 'clang';   E = $LlvmVersao;   X = (Find-Exe @((Join-Path $Caminhos.LLVM 'bin\clang.exe')) 'clang');   A = @('--version'); P = 'clang version'; R = ('clang version ' + [regex]::Escape($LlvmVersao)) },
        @{ N = 'vcpkg';   E = 'commit 9e593bb'; X = (Find-Exe @((Join-Path $Caminhos.Vcpkg 'vcpkg.exe')) 'vcpkg');   A = @('version');   P = 'version';       R = 'version' },
        @{ N = 'python';  E = '3.12.x';      X = (Find-Exe -Nome 'python' -IgnorarWindowsApps);                     A = @('--version'); P = '^Python ';      R = '^Python 3\.12\.' },
        @{ N = 'magick';  E = '7.x';         X = (Find-Exe -Nome 'magick');                                          A = @('--version'); P = 'ImageMagick';   R = 'ImageMagick' },
        @{ N = 'perl';    E = '5.x';         X = (Find-Exe -Nome 'perl');                                            A = @('--version'); P = 'perl 5';        R = 'perl 5' },
        @{ N = 'bash';    E = 'Git Bash';    X = (Find-Exe -Nome 'bash');                                            A = @('--version'); P = 'GNU bash';      R = 'GNU bash' },
        @{ N = 'pwsh';    E = '7.x';         X = (Find-Exe @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) 'pwsh'); A = @('--version'); P = '^PowerShell'; R = '^PowerShell 7\.' },
        @{ N = 'git';     E = 'qualquer';    X = (Find-Exe -Nome 'git');                                             A = @('--version'); P = '^git version';  R = '^git version' },
        @{ N = 'nuget';   E = 'qualquer';    X = (Find-Exe @((Join-Path $Caminhos.NuGet 'nuget.exe')) 'nuget');      A = @('help');      P = 'NuGet Version'; R = 'NuGet Version' }
    )
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($i in $itens) {
        $encontrado = $null
        $caminho = $i.X
        $status = 'FALTA'
        if ($i.N -eq 'flutter') {
            # No modo -SomenteVerificar nao roda o flutter (o primeiro uso baixa o Dart SDK).
            if (Test-Path -LiteralPath $flutterBat) {
                $caminho = $flutterBat
                if ($SomenteVerificar) { $encontrado = 'tag git: ' + (Get-GitTag $Caminhos.Flutter) }
                else { $encontrado = Get-VersaoLinha $flutterBat @('--version') '^Flutter ' }
            } else {
                $caminho = Find-Exe -Nome 'flutter'
                if ($caminho -and -not $SomenteVerificar) { $encontrado = Get-VersaoLinha $caminho @('--version') '^Flutter ' }
                elseif ($caminho) { $encontrado = '(nao executado no modo -SomenteVerificar)' }
            }
            if ($encontrado) {
                if ($encontrado -match [regex]::Escape($FlutterTag)) { $status = 'OK' } else { $status = 'VER?' }
            }
        } elseif ($caminho) {
            $encontrado = Get-VersaoLinha $caminho $i.A $i.P
            if ($encontrado -and ($encontrado -match $i.R)) { $status = 'OK' } elseif ($encontrado) { $status = 'VER?' }
            if ($i.N -eq 'bash' -and $caminho -like "$env:SystemRoot\*") { $status = 'VER?'; $encontrado = "$encontrado (e o bash do WSL, nao o Git Bash)" }
            if ($i.N -eq 'vcpkg' -and $status -eq 'OK') {
                $h = Get-GitHead $Caminhos.Vcpkg
                if ($h -ne $VcpkgCommit) { $status = 'VER?'; $encontrado = "$encontrado (HEAD $h)" }
            }
        }
        $linhas.Add([pscustomobject]@{ Ferramenta = $i.N; Esperado = $i.E; Status = $status; Encontrado = $encontrado; Caminho = $caminho })
    }

    $vsCpp = Get-VSComCpp
    $st = 'FALTA'; if ($vsCpp) { $st = 'OK' }
    $linhas.Add([pscustomobject]@{ Ferramenta = 'MSVC (VS 2022)'; Esperado = 'VC.Tools.x86.x64'; Status = $st; Encontrado = $vsCpp; Caminho = (Get-VsWhere) })
    $sdks = @(Get-WindowsSdkVersoes)
    $st = 'FALTA'; if ($sdks.Count -gt 0) { $st = 'OK' }
    $linhas.Add([pscustomobject]@{ Ferramenta = 'Windows SDK'; Esperado = '10.0.x'; Status = $st; Encontrado = ($sdks -join ', '); Caminho = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10') })

    $esperadas = [ordered]@{
        CARGO_HOME                 = $Caminhos.Cargo
        RUSTUP_HOME                = $Caminhos.Rustup
        PUB_CACHE                  = $Caminhos.PubCache
        VCPKG_DEFAULT_BINARY_CACHE = $Caminhos.VcpkgCache
        VCPKG_DOWNLOADS            = $Caminhos.VcpkgDownloads
        LIBCLANG_PATH              = (Join-Path $Caminhos.LLVM 'bin')
        VCPKG_ROOT                 = $Caminhos.Vcpkg
    }
    foreach ($k in $esperadas.Keys) {
        $atual = Get-UserEnv $k
        $st = 'FALTA'
        if ($atual -eq $esperadas[$k]) { $st = 'OK' } elseif ($atual) { $st = 'VER?' }
        $linhas.Add([pscustomobject]@{ Ferramenta = "env $k"; Esperado = $esperadas[$k]; Status = $st; Encontrado = $atual; Caminho = '(Usuario)' })
    }
    Write-Tabela -Objetos $linhas -Colunas @('Ferramenta', 'Esperado', 'Status', 'Encontrado', 'Caminho')
}

# ============================================================================
# EXECUCAO
# ============================================================================
Write-Host ''
Write-Host '=== Preparacao do ambiente de build do RustDesk (Flutter, Windows x64) ===' -ForegroundColor Cyan

if (-not $script:EhAdmin -and -not $SomenteVerificar) {
    Write-Host ''
    Write-Host 'ERRO: este script precisa ser executado como Administrador.' -ForegroundColor Red
    Write-Host 'Abra o "Windows PowerShell" com "Executar como administrador" e rode de novo.' -ForegroundColor Red
    Write-Host 'Para apenas ver o que seria feito, sem instalar nada, use -SomenteVerificar.' -ForegroundColor Yellow
    exit 1
}
if ($Base -match '\s') {
    Write-Host "ERRO: a pasta base nao pode conter espacos: '$Base'" -ForegroundColor Red
    exit 2
}
$raizBaseMain = [IO.Path]::GetPathRoot($Base)
if (-not $raizBaseMain -or -not (Test-Path -LiteralPath $raizBaseMain)) {
    Write-Host "ERRO: a unidade de '$Base' nao existe." -ForegroundColor Red
    exit 2
}

if ($SomenteVerificar) {
    Write-Log 'MODO -SomenteVerificar: nada sera instalado, criado ou alterado, e nao ha log em arquivo. Linhas [FARIA] mostram o que seria feito.' 'AVISO'
} else {
    New-Item -ItemType Directory -Force -Path $Caminhos.Logs | Out-Null
    $script:LogFile = Join-Path $Caminhos.Logs ('instalar-ambiente-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Log "Log em arquivo: $script:LogFile"
}

Update-ProcessPath

Invoke-Etapa 'Preflight' { Step-Preflight }
if ($script:Abortar) {
    Show-Resumo
    Write-Log 'Abortado no preflight. Nada foi instalado.' 'ERRO'
    exit 1
}
Invoke-Etapa 'Pastas e variaveis de cache' { Step-Variaveis }
Invoke-Etapa 'Visual Studio 2022 Build Tools (C++)' { Step-VisualStudio }
Invoke-Etapa 'Python 3.12' { Step-Python }
Invoke-Etapa 'Git Bash no PATH' { Step-GitBash }
Invoke-Etapa 'Strawberry Perl' { Step-Perl }
Invoke-Etapa 'ImageMagick' { Step-ImageMagick }
Invoke-Etapa 'PowerShell 7' { Step-PowerShell7 }
Invoke-Etapa 'NuGet' { Step-NuGet }
Invoke-Etapa "LLVM $LlvmVersao" { Step-LLVM }
Invoke-Etapa "Rust $RustVersao" { Step-Rust }
Invoke-Etapa "Flutter $FlutterTag" { Step-Flutter }
Invoke-Etapa 'vcpkg' { Step-Vcpkg }

# Avisa os outros programas (Explorer etc.) que o ambiente do usuario mudou.
if ($script:PathAlterado -and -not $SomenteVerificar) {
    try { [Environment]::SetEnvironmentVariable('RUSTDESK_BUILD_BASE', $Base, 'User') } catch { }
}

Show-Resumo
try { Show-Versoes } catch { Write-Log ("Falha na verificacao de versoes: {0}" -f $_.Exception.Message) 'ERRO' }

Write-Host ''
if ($SomenteVerificar) {
    Write-Log 'Modo -SomenteVerificar: nada foi alterado. Rode sem o parametro, como Administrador, para instalar.' 'AVISO'
} else {
    Write-Log 'IMPORTANTE: abra um NOVO terminal (ou faca logoff/logon) para o PATH e as variaveis novas valerem.' 'AVISO'
    if ($script:PrecisaReiniciar) { Write-Log 'Um instalador pediu reinicio do Windows. Reinicie antes de compilar.' 'AVISO' }
    Write-Log "Log completo: $script:LogFile"
}
if (-not $script:DevModeAtivo) {
    Write-Log 'Lembrete: ative o Modo de Desenvolvedor (start ms-settings:developers) antes do flutter build windows.' 'AVISO'
}
Write-Log 'Este script nao compila o RustDesk.'

$falhas = @($script:Resultados | Where-Object { $_.Status -eq 'FALHOU' }).Count
if ($falhas -gt 0) { exit 1 }
exit 0
