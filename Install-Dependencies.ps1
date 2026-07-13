[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'TailMount - 安装文件系统组件'

Write-Host ''
Write-Host '  TailMount 组件安装程序' -ForegroundColor Cyan
Write-Host '  ----------------------'
Write-Host ''

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host '未找到 WinGet。请先从 Microsoft Store 安装“应用安装程序”。' -ForegroundColor Red
    Read-Host '按回车关闭'
    exit 1
}

$packages = @(
    [pscustomobject]@{ Name = 'WinFsp'; Id = 'WinFsp.WinFsp' },
    [pscustomobject]@{ Name = 'SSHFS-Win'; Id = 'SSHFS-Win.SSHFS-Win' }
)

function Test-ComponentInstalled {
    param([string]$PackageId)

    if ($PackageId -eq 'WinFsp.WinFsp') {
        if (Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue) { return $true }
        if (Test-Path -LiteralPath "${env:ProgramFiles(x86)}\WinFsp") { return $true }
        if (Test-Path -LiteralPath "$env:ProgramFiles\WinFsp") { return $true }
        return $false
    }

    if ($PackageId -eq 'SSHFS-Win.SSHFS-Win') {
        if (Test-Path -LiteralPath "$env:ProgramFiles\SSHFS-Win\bin\sshfs-win.exe") { return $true }
        if (Test-Path -LiteralPath "${env:ProgramFiles(x86)}\SSHFS-Win\bin\sshfs-win.exe") { return $true }
        return $false
    }

    return $false
}

$failed = New-Object System.Collections.Generic.List[string]
foreach ($package in $packages) {
    Write-Host "正在检查 $($package.Name)..." -ForegroundColor Yellow
    if (Test-ComponentInstalled $package.Id) {
        Write-Host "$($package.Name) 已安装，跳过。" -ForegroundColor Green
        Write-Host ''
        continue
    }

    Write-Host "正在安装 $($package.Name)..." -ForegroundColor Yellow
    & winget.exe install --id $package.Id -e --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0 -or (Test-ComponentInstalled $package.Id)) {
        Write-Host "$($package.Name) 已就绪。" -ForegroundColor Green
    }
    else {
        $failed.Add("$($package.Name)（WinGet 代码 $LASTEXITCODE）")
        Write-Host "$($package.Name) 安装失败。" -ForegroundColor Red
    }
    Write-Host ''
}

if ($failed.Count -gt 0) {
    Write-Host '以下组件没有成功安装：' -ForegroundColor Red
    foreach ($item in $failed) { Write-Host "  - $item" -ForegroundColor Red }
    Write-Host ''
    Write-Host '请保留此窗口并把错误内容截图发给开发者。' -ForegroundColor Yellow
    Read-Host '按回车关闭'
    exit 1
}

Write-Host '所有组件安装完成。请关闭并重新打开 TailMount。' -ForegroundColor Green
Read-Host '按回车关闭'




