#!/usr/bin/env bash
# ubuntu2204-secbase — 一键重建 ECS 基础环境
# 实测环境：Ubuntu 22.04 LTS / 2C4G / 中国香港 / root
# 用法：bash setup.sh
# 幂等：重复执行安全（已装的会跳过）

set -euo pipefail

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# ---------- 1. 系统更新 ----------
log "1/8 系统更新"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# 注意：升级 ssh 时若出现 sshd_config 配置选择，务必选 "keep the local version currently installed"
apt-get upgrade -y -qq

# ---------- 2. 时区与 swap ----------
log "2/8 时区 + swap 2G"
timedatectl set-timezone Asia/Shanghai
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------- 3. 工具链 ----------
log "3/8 安装工具链与 Docker"
apt-get install -y -qq \
  build-essential python3-pip python3-venv \
  git curl wget rsync unzip jq \
  vim nano htop tree net-tools dnsutils \
  docker.io docker-compose-v2 \
  nmap tcpdump netcat-openbsd whois \
  fail2ban unattended-upgrades
systemctl enable --now docker
systemctl enable --now fail2ban

# ---------- 3b. Node.js 22 + DeepSeek Harness ----------
log "3b/8 安装 Node.js 22 + DeepSeek Harness"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/^v//; s/\..*//')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi
echo "node $(node -v) / npm $(npm -v)"
npm install -g @deepseek-ai/dsh
mkdir -p /root/dsh-work
echo "dsh 已安装：$(command -v dsh)"
# 首次使用：cd /root/dsh-work && tmux new -s dsh && dsh web
# Web 界面地址与 token 记录在 /root/dsh-work/url.log；DeepSeek 账号凭证存于 /root/.dsh/.credentials.yaml

# ---------- 4. pip 镜像加速 ----------
log "4/8 配置 pip 阿里云镜像"
printf '[global]\nindex-url = https://mirrors.aliyun.com/pypi/simple/\ntrusted-host = mirrors.aliyun.com\n' \
  | tee /etc/pip.conf /root/.pip/pip.conf > /dev/null 2>&1 || true

# ---------- 5. 自动安全更新 ----------
log "5/8 开启自动安全更新"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades

# ---------- 6. 数据盘挂载点 ----------
log "6/8 创建 /data 挂载点"
mkdir -p /data

# ---------- 7. SSH 仅密钥登录 ----------
log "7/8 关闭 SSH 密码登录"
if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
  echo "!! 警告：/root/.ssh/authorized_keys 为空，跳过关闭密码登录（否则你会被锁在门外）"
  echo "!! 先把本地公钥追加进去：ssh-copy-id root@<IP> 或手动粘贴 id_ed25519.pub"
else
  cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  printf 'PasswordAuthentication no\n' > /etc/ssh/sshd_config.d/99-disable-password.conf
  sshd -t && systemctl reload ssh
  echo "已关闭密码登录，请保持当前会话并新开窗口验证：ssh root@<IP>"
fi

# ---------- 8. 验收 ----------
log "8/8 验收"
echo -n "docker      : "; docker --version
echo -n "compose     : "; docker compose version | head -1
echo -n "nmap        : "; nmap --version | head -1
echo -n "node        : "; node -v
echo -n "dsh         : "; dsh --version
echo -n "SSH 密码登录: "; sshd -T | grep -i '^passwordauthentication'
echo -n "swap        : "; free -h | awk '/Swap/{print $2}'
echo -n "磁盘        : "; df -h / | tail -1
echo -e "\n完成。安全组记得只放行 22/80/443。"
