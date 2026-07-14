[CmdletBinding()]
param(
    [string]$InnoCompiler
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $projectRoot 'Create-Icon.ps1')
& (Join-Path $projectRoot 'Build.ps1')

$candidates = @(
    $InnoCompiler,
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ }

$compiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    throw '找不到 Inno Setup 6 编译器。请先安装 Inno Setup 6，或通过 -InnoCompiler 指定 ISCC.exe。'
}

$scriptPath = Join-Path $projectRoot 'installer\TailMount.iss'
& $compiler $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "安装包构建失败，退出代码：$LASTEXITCODE"
}

$installer = Get-Item (Join-Path $projectRoot 'dist\TailMount-Setup-0.3.0.exe')
Write-Host "安装包构建完成：$($installer.FullName)" -ForegroundColor Green
Write-Host "文件大小：$($installer.Length) bytes"
