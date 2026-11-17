#Requires -Version 5.1
<#
.SYNOPSIS
    Aplica a marca PubliSOS (nome, logo e azul da Publi) no codigo do RustDesk.

.DESCRIPTION
    Altera, no clone do RustDesk, SOMENTE aparencia: nome do app, icones, logo da tela
    inicial e cores. Nao mexe em servidor, chave, licenca nem em avisos de copyright.
    Pode rodar de novo: o que ja foi trocado e ignorado. O git do clone guarda o antes e o
    depois (git diff).

    Rode com:  powershell -STA -ExecutionPolicy Bypass -File .\aplicar-marca.ps1
    So mostrar o que faria:  ... -SomenteVerificar

    Arquivo so ASCII (sem acentos) para o PowerShell 5.1 ler sem BOM.
#>
[CmdletBinding()]
param(
    [string]$Fonte = 'F:\rustdesk-build\src\rustdesk',
    # Vazio = usa fonte\publi-original.png (ao lado deste script).
    [string]$Logo = '',
    [string]$Nome = 'PubliSOS',
    [string]$Azul = '28A8E0',
    [string]$AzulClaro = '5FC1EC',
    [switch]$SomenteVerificar,
    [switch]$PularImagens,
    # Servidor (so o nome, sem https:// e sem porta) e chave PUBLICA do RustDesk server.
    # NAO ficam neste repositorio. Vazio = le marca\servidor.local.json (ignorado pelo git), com
    # {"Servidor": "suporte.exemplo.com.br", "Chave": "<chave publica de 44 caracteres>"}.
    # Sem nenhum dos dois, o cliente continua com o servidor padrao do RustDesk.
    [string]$Servidor = '',
    [string]$Chave = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase
if (-not $Logo) {
    # Prefere o logo PubliSOS (com o SOS); senao, o logo da Publi original.
    $Logo = Join-Path $PSScriptRoot 'fonte\logo-publisos.png'
    if (-not (Test-Path -LiteralPath $Logo)) { $Logo = Join-Path $PSScriptRoot 'fonte\publi-original.png' }
}
if (-not $Servidor -and -not $Chave) {
    $cfgLocal = Join-Path $PSScriptRoot 'servidor.local.json'
    if (Test-Path -LiteralPath $cfgLocal) {
        $j = Get-Content -LiteralPath $cfgLocal -Raw | ConvertFrom-Json
        $Servidor = [string]$j.Servidor; $Chave = [string]$j.Chave
    }
}

function Log([string]$m, [string]$cor = 'White') { Write-Host $m -ForegroundColor $cor }

if (-not (Test-Path -LiteralPath (Join-Path $Fonte 'Cargo.toml'))) { throw "Nao achei o RustDesk em $Fonte" }
if (-not (Test-Path -LiteralPath $Logo)) { throw "Nao achei o logo em $Logo" }
if ($Azul -notmatch '^[0-9A-Fa-f]{6}$' -or $AzulClaro -notmatch '^[0-9A-Fa-f]{6}$') { throw 'Azul deve ter 6 digitos hexadecimais' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Log 'AVISO: rode com "powershell -STA" para o desenho dos icones funcionar de forma confiavel.' 'Yellow'
}
if ($SomenteVerificar) { Log 'MODO -SomenteVerificar: nada sera gravado.' 'Cyan' }

$AzulU = $Azul.ToUpper()
$AzulClaroU = $AzulClaro.ToUpper()
$latin1 = [Text.Encoding]::GetEncoding(28591)

# ---------------------------------------------------------------------------
# Edicoes de texto (preserva os bytes do arquivo: le e grava como Latin-1)
# ---------------------------------------------------------------------------
function Edit-Texto {
    param([string]$Rel, [string]$Padrao, [string]$Troca, [string]$Rotulo, [int]$Esperado = 1)
    $caminho = Join-Path $Fonte $Rel
    if (-not (Test-Path -LiteralPath $caminho)) { throw "Arquivo nao existe: $caminho" }
    $txt = $latin1.GetString([IO.File]::ReadAllBytes($caminho))
    $rx = New-Object Text.RegularExpressions.Regex($Padrao, [Text.RegularExpressions.RegexOptions]::Multiline)
    $n = $rx.Matches($txt).Count
    if ($n -eq 0) { Log ("  [pulou] {0} (padrao nao encontrado: ja aplicado ou o codigo mudou)" -f $Rotulo) 'Yellow'; return }
    if ($n -ne $Esperado) { Log ("  [aviso] {0}: {1} ocorrencias, esperado {2}" -f $Rotulo, $n, $Esperado) 'Yellow' }
    if ($SomenteVerificar) { Log ("  [faria] {0} em {1}" -f $Rotulo, $Rel) 'Cyan'; return }
    $novo = $rx.Replace($txt, $Troca)
    [IO.File]::WriteAllBytes($caminho, $latin1.GetBytes($novo))
    Log ("  [ok]    {0} em {1}" -f $Rotulo, $Rel) 'Green'
}

Log "`n== Texto e cores ==" 'Cyan'
Edit-Texto 'libs\hbb_common\src\config.rs' '(APP_NAME: RwLock<String> = RwLock::new\(")RustDesk(")' ('${1}' + $Nome + '${2}') 'nome do app (APP_NAME)'
Edit-Texto 'Cargo.toml' '^(ProductName = ")RustDesk(")' ('${1}' + $Nome + '${2}') 'ProductName do .exe'
Edit-Texto 'Cargo.toml' '^(FileDescription = ")RustDesk Remote Desktop(")' ('${1}' + $Nome + ' Suporte Remoto${2}') 'FileDescription do .exe'
Edit-Texto 'Cargo.toml' '(\[package\.metadata\.bundle\]\r?\nname = ")RustDesk(")' ('${1}' + $Nome + '${2}') 'nome do bundle'
Edit-Texto 'libs\portable\Cargo.toml' '^(ProductName = ")RustDesk(")' ('${1}' + $Nome + '${2}') 'ProductName do executavel unico'
Edit-Texto 'libs\portable\Cargo.toml' '^(FileDescription = ")RustDesk Remote Desktop(")' ('${1}' + $Nome + ' Suporte Remoto${2}') 'FileDescription do executavel unico'
Edit-Texto 'libs\portable\Cargo.toml' '^(OriginalFilename = ")rustdesk\.exe(")' ('${1}' + $Nome + '.exe${2}') 'OriginalFilename do executavel unico'
Edit-Texto 'flutter\windows\runner\Runner.rc' '(VALUE "FileDescription", ")RustDesk Remote Desktop(")' ('${1}' + $Nome + ' Suporte Remoto${2}') 'FileDescription (Runner.rc)'
Edit-Texto 'flutter\windows\runner\Runner.rc' '(VALUE "ProductName", ")RustDesk(")' ('${1}' + $Nome + '${2}') 'ProductName (Runner.rc)'
Edit-Texto 'flutter\windows\runner\main.cpp' '(std::wstring app_name = L")RustDesk(")' ('${1}' + $Nome + '${2}') 'nome padrao da janela'
Edit-Texto 'flutter\lib\common.dart' '(?i)0xFF(?:0071FF|1CA5DE|28A8E0)' ('0xFF' + $AzulU) 'azul principal (accent)'
Edit-Texto 'flutter\lib\common.dart' '(?i)0x77(?:0071FF|1CA5DE|28A8E0)' ('0x77' + $AzulU) 'azul 50% (accent50)'
Edit-Texto 'flutter\lib\common.dart' '(?i)0xAA(?:0071FF|1CA5DE|28A8E0)' ('0xAA' + $AzulU) 'azul 80% (accent80)'
Edit-Texto 'flutter\lib\common.dart' 'primary: Colors\.blue, secondary: accent' 'primary: accent, secondary: accent' 'cor primaria do tema claro'
Edit-Texto 'flutter\lib\common.dart' '(ColorScheme\.dark\(\s*)primary: Colors\.blue,' '${1}primary: accent,' 'cor primaria do tema escuro'
Edit-Texto 'flutter\lib\desktop\pages\server_page.dart' '(?i)Color\(0xff(?:00bfe1|4dbbe8|5fc1ec)\)' ('Color(0xff' + $AzulClaroU.ToLower() + ')') 'gradiente (claro)'
Edit-Texto 'flutter\lib\desktop\pages\server_page.dart' '(?i)Color\(0xff(?:0071ff|1ca5de|28a8e0)\)' ('Color(0xff' + $AzulU.ToLower() + ')') 'gradiente (azul Publi)'

# Servidor e chave: o cliente passa a usar o servidor da Publi sem precisar configurar nada.
if ($Servidor -and $Chave) {
    if ($Servidor -notmatch '^[A-Za-z0-9.-]+$') { throw 'Servidor invalido (so letras, numeros, ponto e hifen, sem https:// nem porta).' }
    if ($Chave -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'Chave publica invalida (esperado base64 de 44 caracteres terminando em =).' }
    Edit-Texto 'libs\hbb_common\src\config.rs' '(pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[")[^"]*("\];)' ('${1}' + $Servidor + '${2}') 'servidor padrao (RENDEZVOUS_SERVERS)'
    # Tambem marca o servidor como proprio (sem o aviso de servidor publico) e com prioridade sobre configs antigas.
    Edit-Texto 'libs\hbb_common\src\config.rs' '(PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new\(")[^"]*("\.to_owned\(\)\))' ('${1}' + $Servidor + '${2}') 'servidor proprio (PROD_RENDEZVOUS_SERVER)'
    Edit-Texto 'libs\hbb_common\src\config.rs' '(pub const RS_PUB_KEY: &str = ")[^"]*(";)' ('${1}' + $Chave + '${2}') 'chave publica padrao (RS_PUB_KEY)'
}

# A pagina "Sobre" (creditos, copyright e licenca) fica exatamente como o RustDesk a fez.

# ---------------------------------------------------------------------------
# Imagens (WPF): icones quadrados e logo da tela inicial
# ---------------------------------------------------------------------------
# Desenha a imagem dentro de uma tela LxA transparente, sem distorcer, com margem.
function Render-Tela($src, [int]$L, [int]$A, [double]$Margem) {
    $dv = New-Object Windows.Media.DrawingVisual
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [Windows.Media.BitmapScalingMode]::HighQuality)
    $dc = $dv.RenderOpen()
    $dispL = $L * (1 - 2 * $Margem)
    $dispA = $A * (1 - 2 * $Margem)
    $esc = [Math]::Min($dispL / $src.PixelWidth, $dispA / $src.PixelHeight)
    $w = $src.PixelWidth * $esc
    $h = $src.PixelHeight * $esc
    $rect = New-Object Windows.Rect((($L - $w) / 2), (($A - $h) / 2), $w, $h)
    $dc.DrawImage($src, $rect)
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($L, $A, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    return $rtb
}

function Get-PngBytes($bmp) {
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = New-Object IO.MemoryStream
    $enc.Save($ms)
    return , $ms.ToArray()
}

function Get-Bgra($rtb) {
    $conv = New-Object Windows.Media.Imaging.FormatConvertedBitmap
    $conv.BeginInit()
    $conv.Source = $rtb
    $conv.DestinationFormat = [Windows.Media.PixelFormats]::Bgra32
    $conv.EndInit()
    $stride = $rtb.PixelWidth * 4
    $buf = New-Object byte[] ($stride * $rtb.PixelHeight)
    $conv.CopyPixels($buf, $stride, 0)
    return , $buf
}

function New-DibBytes([int]$tam, [byte[]]$bgra) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([uint32]40); $bw.Write([int32]$tam); $bw.Write([int32]($tam * 2))
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
    $bw.Write([uint32]($tam * $tam * 4)); $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $tam - 1; $y -ge 0; $y--) { $bw.Write($bgra, ($y * $tam * 4), ($tam * 4)) }
    $linhaMascara = [int]([Math]::Ceiling($tam / 32.0) * 4)
    $bw.Write((New-Object byte[] ($linhaMascara * $tam)))
    $bw.Flush()
    return , $ms.ToArray()
}

# ICO: quadros menores que 256 em BMP (32 bits), quadro de 256 em PNG.
function New-Ico($src, [int[]]$tamanhos, [double]$margem) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$tamanhos.Count)
    $offset = 6 + 16 * $tamanhos.Count
    $dados = @()
    foreach ($t in $tamanhos) {
        $rtb = Render-Tela $src $t $t $margem
        if ($t -ge 256) { $d = Get-PngBytes $rtb } else { $d = New-DibBytes $t (Get-Bgra $rtb) }
        $dados += , $d
        $dim = 0; if ($t -lt 256) { $dim = $t }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$d.Length); $bw.Write([uint32]$offset)
        $offset += $d.Length
    }
    foreach ($d in $dados) { $bw.Write($d) }
    $bw.Flush()
    return , $ms.ToArray()
}

function Save-Bytes([string]$Rel, [byte[]]$bytes) {
    $caminho = Join-Path $Fonte $Rel
    if ($SomenteVerificar) { Log ("  [faria] gravar {0} ({1} bytes)" -f $Rel, $bytes.Length) 'Cyan'; return }
    $pasta = Split-Path -Parent $caminho
    if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Force -Path $pasta | Out-Null }
    [IO.File]::WriteAllBytes($caminho, $bytes)
    Log ("  [ok]    {0} ({1} bytes)" -f $Rel, $bytes.Length) 'Green'
}

# Remove o fundo branco opaco do logo (o upscaled vem sem transparencia): apaga o branco ligado
# as bordas da imagem e recalcula a transparencia das bordas suavizadas a partir do azul da marca.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class FundoLogo {
    // Logo com transparencia e sombra projetada escura: apaga o que for escuro e devolve a area visivel.
    public static int[] TirarSombra(byte[] p, int w, int h) {
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int o = (y * w + x) * 4;
                if (p[o + 3] > 0 && p[o] < 70 && p[o + 1] < 70 && p[o + 2] < 70) { p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0; }
                if (p[o + 3] > 8) { if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
            }
        }
        return new int[] { x0, y0, x1, y1 };
    }
    // p: pixels BGRA (4 bytes). Devolve [x0,y0,x1,y1] da area visivel depois da limpeza.
    public static int[] Remover(byte[] p, int w, int h, byte ar, byte ag, byte ab, int limiar, int banda) {
        bool[] fora = new bool[w * h];
        Queue<int> q = new Queue<int>();
        Action<int, int> tenta = delegate(int x, int y) {
            if (x < 0 || y < 0 || x >= w || y >= h) return;
            int i = y * w + x;
            if (fora[i]) return;
            int o = i * 4;
            if (p[o] >= limiar && p[o + 1] >= limiar && p[o + 2] >= limiar) { fora[i] = true; q.Enqueue(i); }
        };
        for (int x = 0; x < w; x++) { tenta(x, 0); tenta(x, h - 1); }
        for (int y = 0; y < h; y++) { tenta(0, y); tenta(w - 1, y); }
        while (q.Count > 0) {
            int i = q.Dequeue(); int x = i % w, y = i / w;
            tenta(x + 1, y); tenta(x - 1, y); tenta(x, y + 1); tenta(x, y - 1);
        }
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        double span = 255.0 - ar;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int i = y * w + x; int o = i * 4;
                if (fora[i]) { p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0; continue; }
                bool perto = false;
                for (int dy = -banda; dy <= banda && !perto; dy++) {
                    for (int dx = -banda; dx <= banda; dx++) {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        if (fora[ny * w + nx]) { perto = true; break; }
                    }
                }
                if (perto) {
                    double a = (255.0 - p[o + 2]) / span;
                    if (a < 0) a = 0; if (a > 1) a = 1;
                    if (a < 0.04) { p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0; continue; }
                    p[o] = ab; p[o + 1] = ag; p[o + 2] = ar; p[o + 3] = (byte)Math.Round(a * 255);
                }
                if (p[o + 3] > 8) {
                    if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
                }
            }
        }
        return new int[] { x0, y0, x1, y1 };
    }
}
"@

function Get-Fonte([string]$Caminho) {
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.UriSource = New-Object Uri($Caminho)
    $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $bi.Freeze()
    # Converte para BGRA e, se o logo nao tiver transparencia, tira o fundo branco.
    $c = New-Object Windows.Media.Imaging.FormatConvertedBitmap
    $c.BeginInit(); $c.Source = $bi; $c.DestinationFormat = [Windows.Media.PixelFormats]::Bgra32; $c.EndInit()
    $w = $c.PixelWidth; $h = $c.PixelHeight; $stride = $w * 4
    $px = New-Object byte[] ($stride * $h)
    $c.CopyPixels($px, $stride, 0)
    $semAlfa = $true
    for ($i = 3; $i -lt $px.Length; $i += 4) { if ($px[$i] -ne 255) { $semAlfa = $false; break } }
    if (-not $semAlfa) {
        $bb = [FundoLogo]::TirarSombra($px, $w, $h)
        if ($bb[2] -lt 0) { throw 'Logo ficou vazio depois de tirar a sombra.' }
        $limpo = [Windows.Media.Imaging.BitmapSource]::Create($w, $h, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $px, $stride)
        $rect = New-Object Windows.Int32Rect($bb[0], $bb[1], ($bb[2] - $bb[0] + 1), ($bb[3] - $bb[1] + 1))
        $corte = New-Object Windows.Media.Imaging.CroppedBitmap($limpo, $rect)
        $corte.Freeze()
        Log ('  logo com transparencia: sombra removida; area {0}x{1}' -f $rect.Width, $rect.Height) 'Green'
        return $corte
    }
    $ar = [byte][Convert]::ToInt32($Azul.Substring(0, 2), 16)
    $ag = [byte][Convert]::ToInt32($Azul.Substring(2, 2), 16)
    $ab = [byte][Convert]::ToInt32($Azul.Substring(4, 2), 16)
    $bb = [FundoLogo]::Remover($px, $w, $h, $ar, $ag, $ab, 235, 3)
    if ($bb[2] -lt 0) { throw 'Remocao de fundo apagou a imagem inteira. Confira o logo.' }
    $limpo = [Windows.Media.Imaging.BitmapSource]::Create($w, $h, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $px, $stride)
    $rect = New-Object Windows.Int32Rect($bb[0], $bb[1], ($bb[2] - $bb[0] + 1), ($bb[3] - $bb[1] + 1))
    $corte = New-Object Windows.Media.Imaging.CroppedBitmap($limpo, $rect)
    $corte.Freeze()
    Log ("  fundo removido; area do logo {0}x{1}" -f $rect.Width, $rect.Height) 'Green'
    return $corte
}

if ($PularImagens) { Log "`n-PularImagens: imagens nao alteradas." 'Cyan'; return }
Log "`n== Imagens ==" 'Cyan'
$origem = Get-Fonte $Logo
Log ("  logo de origem: {0} ({1}x{2})" -f $Logo, $origem.PixelWidth, $origem.PixelHeight)
if (-not $SomenteVerificar) {
    $guarda = Join-Path $PSScriptRoot 'fonte'
    New-Item -ItemType Directory -Force -Path $guarda | Out-Null
    Copy-Item -LiteralPath $Logo -Destination (Join-Path $guarda 'logo-publi.png') -Force
}

$margem = 0.06
$icoGrande = New-Ico $origem @(16, 24, 32, 48, 64, 128, 256) $margem
$icoBandeja = New-Ico $origem @(16, 24, 32, 48) $margem
Save-Bytes 'res\icon.ico' $icoGrande
Save-Bytes 'flutter\windows\runner\resources\app_icon.ico' $icoGrande
Save-Bytes 'res\tray-icon.ico' $icoBandeja

foreach ($t in @(@('res\icon.png', 1024), @('res\128x128@2x.png', 256), @('res\128x128.png', 128), @('res\64x64.png', 64), @('res\32x32.png', 32), @('flutter\assets\icon.png', 256))) {
    Save-Bytes $t[0] (Get-PngBytes (Render-Tela $origem $t[1] $t[1] $margem))
}

# Logo da tela inicial (o app mostra assets\logo.png em no maximo 300x60): sem margem, na proporcao original.
$altLogo = 240
$largLogo = [int][Math]::Round($altLogo * $origem.PixelWidth / $origem.PixelHeight)
Save-Bytes 'flutter\assets\logo.png' (Get-PngBytes (Render-Tela $origem $largLogo $altLogo 0.0))

Log "`nPronto. Veja o que mudou com:  git -C `"$Fonte`" status  e  git -C `"$Fonte`" diff --stat" 'Cyan'
Log 'Nao foram alterados: servidor, chave, licenca, copyright (CompanyName/LegalCopyright) nem o nome do arquivo rustdesk.exe.' 'Cyan'
