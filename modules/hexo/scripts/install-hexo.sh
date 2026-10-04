#!/usr/bin/env bash
# 全局安装 hexo-cli。
# npm -g 需要写入系统目录 (/usr/lib/node_modules, /usr/bin):
# - root (含无 sudo 二进制的容器, 生成器的 sudo 垫片在父 shell, 传不进本子进程): 直接装;
# - 普通用户: 经 sudo 提权。
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
  npm install -g hexo-cli
else
  sudo npm install -g hexo-cli
fi
