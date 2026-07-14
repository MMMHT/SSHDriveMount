#!/bin/zsh
set -e

echo "TailMount macOS 依赖检查"
echo "======================"
if [[ -d /Library/Filesystems/macfuse.fs ]]; then
  echo "✓ macFUSE 已安装"
else
  echo "✗ 缺少 macFUSE，正在打开官方下载页面"
  open "https://macfuse.github.io/"
fi

if [[ -x /usr/local/bin/sshfs || -x /opt/homebrew/bin/sshfs || -x /Library/Filesystems/sshfs.fs/Contents/Resources/sshfs ]]; then
  echo "✓ SSHFS 已安装"
else
  echo "✗ 缺少 SSHFS，请在 macFUSE 官方页面下载 SSHFS 3.7.5 或更新版本"
  open "https://macfuse.github.io/"
fi

echo "安装结束后，请重新打开 TailMount。"
read -k 1 "?按任意键关闭…"
