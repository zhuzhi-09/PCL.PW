#!/usr/bin/env bash
# 安装 CI 需要的系统包。
# GitHub 的 Ubuntu 镜像默认用 azure.archive.ubuntu.com，它偶尔完全不响应，apt 默认不超时，会一直等到任务超时。
# 这里给每次请求加超时，整次 update / install 也限时；默认源不通时依次换成其他官方镜像再试。
set -uo pipefail

opts=(-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o DPkg::Lock::Timeout=60)
# 第一项为空：先用系统默认的源
mirrors=("" "http://mirrors.edge.kernel.org/ubuntu" "http://mirrors.mit.edu/ubuntu")
# ARM 机器的软件源是 ubuntu-ports，上面的镜像只有 x86；只用默认源，多试几次
if [ "$(dpkg --print-architecture)" != amd64 ]; then mirrors=("" "" ""); fi

# 把 Ubuntu 官方源（含 Azure 镜像列表与安全更新源）替换成指定镜像；第三方源（如 packages.microsoft.com）不动
current=""
use_mirror() {
  local mirror=$1
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    # 上一轮换上的镜像也要换掉
    [ -n "$current" ] && sudo sed -i "s#${current}#${mirror}#g" "$f"
    sudo sed -i -E \
      -e "s#mirror\+file:/etc/apt/apt-mirrors\.txt#${mirror}#g" \
      -e "s#https?://(azure\.)?archive\.ubuntu\.com/ubuntu/?#${mirror}#g" \
      -e "s#https?://security\.ubuntu\.com/ubuntu/?#${mirror}#g" \
      "$f"
  done
  current=$mirror
  echo "改用镜像：${mirror}"
}

for mirror in "${mirrors[@]}"; do
  [ -n "$mirror" ] && use_mirror "$mirror"
  if timeout 180 sudo apt-get "${opts[@]}" update &&
    timeout 600 sudo DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "$@"; then
    exit 0
  fi
  echo "::warning::安装系统包失败（源：${mirror:-默认}），换一个源重试"
done
echo "::error::安装系统包失败：$*"
exit 1
