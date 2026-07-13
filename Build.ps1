[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    throw '请使用 Windows PowerShell 5.1（powershell.exe）运行 Build.ps1。'
}

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourcePath = Join-Path $projectRoot 'TailMount.Launcher.cs'
$outputPath = Join-Path $projectRoot 'TailMount.exe'
$iconPath = Join-Path $projectRoot 'assets\TailMount.ico'

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "找不到启动器源码：$sourcePath"
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    throw '找不到 .NET Framework C# 编译器，请启用 Windows 的 .NET Framework 4.x 功能。'
}

$automationAssembly = [System.Management.Automation.PowerShell].Assembly.Location
$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    '/reference:System.Windows.Forms.dll',
    "/reference:$automationAssembly",
    "/out:$outputPath"
)
if (Test-Path -LiteralPath $iconPath) {
    $compilerArguments += "/win32icon:$iconPath"
}
$compilerArguments += $sourcePath

& $compiler $compilerArguments

if ($LASTEXITCODE -ne 0) {
    throw "启动器编译失败，退出代码：$LASTEXITCODE"
}

$result = Get-Item -LiteralPath $outputPath
Write-Host "构建完成：$($result.FullName)" -ForegroundColor Green
Write-Host "文件大小：$($result.Length) bytes"

