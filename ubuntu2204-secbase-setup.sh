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

# ---------- 3c. dsh 进程资源笼子（防内存/IO 搞崩整机） ----------
log "3c/8 配置 dsh 资源限制启动器"
cat > /usr/local/bin/dsh-web <<'LAUNCHER'
#!/usr/bin/env bash
# 在 cgroup 限制下启动 DSH Web：dsh 及其子进程内存合计超 6G、CPU 超 1.5 核
# 时由系统强制终止 dsh 本身，整机（8G 内存）不受影响。
# 用法：tmux new -s dsh 然后执行 dsh-web
exec systemd-run --scope -p MemoryMax=6G -p CPUQuota=150% --unit=dsh-guard dsh web
LAUNCHER
chmod +x /usr/local/bin/dsh-web

# ---------- 3d. HuggingFace 镜像（模型下载走国内，防超时反复重试拖垮磁盘） ----------
grep -q '^HF_ENDPOINT=' /etc/environment 2>/dev/null || echo 'HF_ENDPOINT="https://hf-mirror.com"' >> /etc/environment

# 启动方式：tmux new -s dsh && dsh-web（不要直接跑 dsh web，那样没有资源笼子）
# token 记录在 /root/dsh-work/url.log；DeepSeek 账号凭证存于 /root/.dsh/.credentials.yaml

# ---------- 3e. DSH 安全运行提示词（每次开任务时整段粘贴给 DSH） ----------
cat > /root/dsh-guard-prompt.md <<'PROMPT'
# DeepSeek Harness 安全运行约束提示词
# 用法：每次在 DSH 里开新任务/新会话时，把下面整段粘贴到任务提示的最前面。

【运行环境硬约束，任务开始前必须先读，每条都不可违反】
本机：2核 CPU / 8G 内存 / 40G 磁盘（已用约 8G）。这是长期运行的服务器，
/root 下还有 sshd、fail2ban、docker 等系统服务，你的任何失误都可能搞崩整机。

1. 内存红线：每个大步骤前跑 free -h。available < 2G 时禁止启动任何新任务；
   训练/推理时限制 batch size，DataLoader 的 num_workers ≤ 2，torch.set_num_threads(2)。
2. 磁盘红线：任务开始和结束时跑 df -h。任何超过 500MB 的下载，必须先停下向我报备，
   我同意才能下。所有数据和模型只允许放 /data 或 /root/dsh-work，磁盘用量超过 25G 立即停止并汇报。
3. 下载一律走镜像：pip 用已配置的阿里云源；HuggingFace 必须设置
   HF_ENDPOINT=https://hf-mirror.com；禁止从其他来源下载大文件。
4. 编译/安装限制并行度：make -j2。禁止执行：apt upgrade、apt autoremove、
   systemctl restart/stop、reboot、任何写 /etc 的操作。
5. 禁区：不得修改 /etc/ssh、/etc/fstab、fail2ban、docker 全局配置、systemd 服务；
   rm 只允许作用于 /root/dsh-work 和 /data 内你本次创建的文件；任何服务不得监听 0.0.0.0。
6. 单任务原则：同一时间只允许一个下载/训练/编译任务在跑，禁止并行。
7. 超时纪律：单条命令 10 分钟无输出视为卡死，终止并汇报；任务总时长超 1 小时先汇报进度。
8. 收尾：任务结束后执行 pip cache purge，并汇报三件事——磁盘/内存现状、产出文件路径
   （含大小）、哪些中间产物可以安全删除。

违反任何一条，立即停止当前操作并向我汇报，不要尝试自行"修复"系统。
PROMPT

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
echo -n "dsh 启动器  : "; [ -x /usr/local/bin/dsh-web ] && echo "dsh-web（含 6G 内存笼 + 1.5 核限额）" || echo 缺失
echo -n "HF 镜像     : "; grep -o '^HF_ENDPOINT=.*' /etc/environment 2>/dev/null || echo 未配置
echo -n "安全提示词  : "; [ -f /root/dsh-guard-prompt.md ] && echo "/root/dsh-guard-prompt.md（开任务时粘贴给 DSH）" || echo 缺失
echo -n "SSH 密码登录: "; sshd -T | grep -i '^passwordauthentication'
echo -n "swap        : "; free -h | awk '/Swap/{print $2}'
echo -n "磁盘        : "; df -h / | tail -1
echo -e "\n完成。安全组记得只放行 22/80/443。"
