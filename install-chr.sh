#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# MikroTik CHR 最新 Stable 一键 DD 安装脚本
#
# 功能：
#   - 自动获取 MikroTik 最新 Stable 版本
#   - 从 MikroTik 官方 Stable changelog 提取 RouterOS 7.x 候选版本
#   - 自动验证 CHR IMG ZIP 下载地址
#   - 自动识别默认 IPv4 网卡
#   - 自动获取 IPv4 / Prefix / Gateway
#   - 自动识别系统硬盘 sda / vda / nvme 等
#   - 自动读取 CHR 分区 Start
#   - 自动计算 mount offset
#   - 自动写入 RouterOS autorun.scr
#   - 支持常见 /32 / onlink VPS 网络
#   - 自动生成随机 admin 密码
#   - 中文状态输出
#   - DD 前必须输入 YES 二次确认
#
# 重要：
#   此脚本最终会完整覆盖系统盘！
# ============================================================


# ============================================================
# 基本变量
# ============================================================

MIKROTIK_STABLE_CHANGELOG="https://mikrotik.com/download/changelogs?channelFilter=stable"

RAM_DIR="/dev/shm/chr-installer"
DOWNLOAD_DIR="/tmp/chr-installer"
MOUNT_DIR="/mnt/chr-installer"

IMAGE_FILE="${RAM_DIR}/chr.img"
ZIP_FILE="${DOWNLOAD_DIR}/chr.img.zip"


# ============================================================
# 颜色
# ============================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'


info() {
    echo -e "${BLUE}[信息]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[成功]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[注意]${RESET} $*"
}

error() {
    echo -e "${RED}[错误]${RESET} $*"
}

die() {
    error "$*"
    exit 1
}


# ============================================================
# 异常处理
# ============================================================

cleanup() {

    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount "$MOUNT_DIR" 2>/dev/null || true
    fi

}

trap cleanup EXIT


# ============================================================
# 必须使用 ROOT
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 用户运行本脚本。"
fi


clear

echo
echo "============================================================"
echo "       MikroTik CHR 最新 Stable 一键安装脚本"
echo "============================================================"
echo


# ============================================================
# 检查 CPU
# ============================================================

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        ok "CPU 架构：$ARCH"
        ;;
    *)
        die "CHR 需要 x86_64/amd64 架构，当前架构：$ARCH"
        ;;
esac


# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    local missing=0

    for cmd in \
        wget \
        unzip \
        ip \
        awk \
        grep \
        sed \
        fdisk \
        lsblk \
        findmnt \
        mount \
        umount \
        mountpoint \
        dd \
        df
    do

        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi

    done


    if [ "$missing" -eq 0 ]; then
        ok "必要工具检查通过"
        return
    fi


    warn "检测到缺少必要工具，尝试自动安装..."


    if command -v apt-get >/dev/null 2>&1; then

        apt-get update

        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y \
            wget \
            unzip \
            util-linux \
            iproute2 \
            coreutils


    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            wget \
            unzip \
            util-linux \
            iproute \
            coreutils


    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            wget \
            unzip \
            util-linux \
            iproute \
            coreutils


    else

        die "无法识别软件包管理器，请先手动安装 wget、unzip、util-linux、iproute。"

    fi
}


install_dependencies


# ============================================================
# 清理旧目录
# ============================================================

cleanup

rm -rf "$RAM_DIR"
rm -rf "$DOWNLOAD_DIR"

mkdir -p "$RAM_DIR"
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$MOUNT_DIR"


# ============================================================
# 获取 MikroTik 最新 Stable 版本
# ============================================================

info "正在通过 MikroTik Stable Changelog 获取版本..."

CHANGELOG_HTML="$(
    wget \
        -qO- \
        --timeout=20 \
        --tries=2 \
        "$MIKROTIK_STABLE_CHANGELOG" \
        2>/dev/null || true
)"

[ -n "$CHANGELOG_HTML" ] || \
    die "无法访问 MikroTik 官方 Stable Changelog 页面。"

# 仅从 Stable 页面提取完整的 7.x / 7.x.y 版本标记。
# 先按完整标记分词，避免把 7.xrc / 7.xbeta 或其他版本的子串当成 Stable。
# 保留页面顺序并去重，不使用任意三段版本号的宽松匹配。
mapfile -t VERSION_CANDIDATES < <(
    printf '%s\n' "$CHANGELOG_HTML" |
    grep -oE '[[:alnum:]_.+-]+' |
    grep -E '^7\.[0-9]+(\.[0-9]+)?$' |
    awk '!seen[$0]++'
)

[ "${#VERSION_CANDIDATES[@]}" -gt 0 ] || \
    die "未能从 MikroTik 官方 Stable 页面解析出 RouterOS 7.x 版本。"

CHR_VERSION=""
CHR_URL=""

for VERSION in "${VERSION_CANDIDATES[@]}"; do

    TEST_URL="https://download.mikrotik.com/routeros/${VERSION}/chr-${VERSION}.img.zip"

    info "正在验证 RouterOS $VERSION CHR 镜像..."

    if wget \
        --spider \
        --timeout=20 \
        --tries=2 \
        "$TEST_URL" \
        >/dev/null 2>&1
    then
        CHR_VERSION="$VERSION"
        CHR_URL="$TEST_URL"
        break
    fi

    warn "RouterOS $VERSION CHR 镜像验证失败，继续尝试下一个候选版本"

done

[ -n "$CHR_VERSION" ] || \
    die "所有 RouterOS 7.x Stable 候选镜像均验证失败，脚本已停止，不会执行 DD。"

ok "检测到最新 Stable：RouterOS $CHR_VERSION"

echo
info "CHR 下载地址："
echo "$CHR_URL"
echo

ok "CHR 官方镜像验证成功"


# ============================================================
# 检测默认 IPv4 路由
# ============================================================

info "正在检测服务器 IPv4 网络..."


DEFAULT_ROUTE="$(
    ip -4 route show default |
    head -n1
)"


[ -n "$DEFAULT_ROUTE" ] || \
    die "未检测到 IPv4 默认路由。"


echo
info "Linux 默认路由："
echo "$DEFAULT_ROUTE"
echo


# ============================================================
# 获取网卡
# ============================================================

NET_IF="$(
    printf '%s\n' "$DEFAULT_ROUTE" |
    awk '
    {
        for (i=1; i<=NF; i++) {
            if ($i == "dev") {
                print $(i+1)
                exit
            }
        }
    }'
)"


[ -n "$NET_IF" ] || \
    die "无法从默认路由中识别公网网卡。"


ok "公网网卡：$NET_IF"


# ============================================================
# IPv4
# ============================================================

IP_ADDR="$(
    ip -4 -o addr show \
        dev "$NET_IF" \
        scope global |
    awk '{print $4}' |
    head -n1
)"


[ -n "$IP_ADDR" ] || \
    die "无法获取 $NET_IF 的 IPv4 地址。"


IP_ONLY="${IP_ADDR%/*}"
PREFIX="${IP_ADDR#*/}"


if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] ||
   [ "$PREFIX" -lt 0 ] ||
   [ "$PREFIX" -gt 32 ]; then

    die "IPv4 Prefix 异常：$IP_ADDR"

fi


ok "IPv4 地址：$IP_ADDR"


# ============================================================
# 网关
# ============================================================

GATEWAY="$(
    printf '%s\n' "$DEFAULT_ROUTE" |
    awk '
    {
        for (i=1; i<=NF; i++) {
            if ($i == "via") {
                print $(i+1)
                exit
            }
        }
    }'
)"


[ -n "$GATEWAY" ] || \
    die "默认路由中未检测到 IPv4 Gateway。"


ok "默认网关：$GATEWAY"


# ============================================================
# 判断 onlink /32
# ============================================================

ONLINK="no"


if printf '%s\n' "$DEFAULT_ROUTE" |
   grep -qw "onlink"; then

    ONLINK="yes"

fi


if [ "$PREFIX" -eq 32 ]; then

    ONLINK="yes"

fi


if [ "$ONLINK" = "yes" ]; then

    warn "检测到 /32 或 onlink 网络"

    warn "RouterOS 将额外创建：
$GATEWAY/32 → ether1"

fi


# ============================================================
# 自动识别系统硬盘
# ============================================================

info "正在检测系统硬盘..."


ROOT_SOURCE="$(
    findmnt -n -o SOURCE / 2>/dev/null || true
)"


SYSTEM_DISK=""


# ------------------------------------------------------------
# 如果 ROOT 是普通块设备 / LVM / Partition
# ------------------------------------------------------------

if [ -n "$ROOT_SOURCE" ] &&
   [ -b "$ROOT_SOURCE" ]; then

    SYSTEM_DISK="$(
        lsblk \
            -s \
            -n \
            -o PATH,TYPE \
            "$ROOT_SOURCE" \
            2>/dev/null |
        awk '$2=="disk" {print $1; exit}'
    )"

fi


# ------------------------------------------------------------
# /dev/root 情况
# ------------------------------------------------------------

if [ -z "$SYSTEM_DISK" ] &&
   [ "$ROOT_SOURCE" = "/dev/root" ]; then

    ROOT_REAL="$(
        readlink -f /dev/root 2>/dev/null || true
    )"

    if [ -n "$ROOT_REAL" ] &&
       [ -b "$ROOT_REAL" ]; then

        SYSTEM_DISK="$(
            lsblk \
                -s \
                -n \
                -o PATH,TYPE \
                "$ROOT_REAL" |
            awk '$2=="disk" {print $1; exit}'
        )"

    fi

fi


# ------------------------------------------------------------
# Rescue / 特殊环境
# ROOT 不在本地磁盘时：
# 如果只存在一块真实硬盘，则使用它
# ------------------------------------------------------------

if [ -z "$SYSTEM_DISK" ]; then

    mapfile -t REAL_DISKS < <(
        lsblk \
            -dpn \
            -o NAME,TYPE \
            2>/dev/null |
        awk '$2=="disk" {print $1}'
    )


    if [ "${#REAL_DISKS[@]}" -eq 1 ]; then

        SYSTEM_DISK="${REAL_DISKS[0]}"

        warn "当前 ROOT 不位于普通块设备"
        warn "服务器仅检测到一块真实硬盘，自动选择：$SYSTEM_DISK"

    elif [ "${#REAL_DISKS[@]}" -gt 1 ]; then

        echo
        error "检测到多块硬盘，无法安全自动判断 DD 目标："

        printf '  %s\n' "${REAL_DISKS[@]}"

        echo

        die "为避免误删数据，脚本停止。"

    fi

fi


[ -n "$SYSTEM_DISK" ] || \
    die "无法自动识别系统硬盘。"


[ -b "$SYSTEM_DISK" ] || \
    die "$SYSTEM_DISK 不是有效块设备。"


DISK_SIZE="$(
    lsblk -dn -o SIZE "$SYSTEM_DISK"
)"


ok "目标硬盘：$SYSTEM_DISK"
ok "硬盘容量：$DISK_SIZE"


# ============================================================
# 防止误选 loop
# ============================================================

DISK_TYPE="$(
    lsblk -dn -o TYPE "$SYSTEM_DISK"
)"


[ "$DISK_TYPE" = "disk" ] || \
    die "目标设备不是物理/虚拟磁盘：$SYSTEM_DISK"


# ============================================================
# 显示系统信息
# ============================================================

echo
echo "============================================================"
echo -e "${WHITE}                 自动检测结果${RESET}"
echo "============================================================"
echo
printf "%-18s %s\n" "RouterOS：" "$CHR_VERSION Stable"
printf "%-18s %s\n" "下载地址：" "$CHR_URL"
printf "%-18s %s\n" "Linux 网卡：" "$NET_IF"
printf "%-18s %s\n" "IPv4：" "$IP_ADDR"
printf "%-18s %s\n" "Gateway：" "$GATEWAY"
printf "%-18s %s\n" "Onlink：" "$ONLINK"
printf "%-18s %s\n" "目标硬盘：" "$SYSTEM_DISK"
printf "%-18s %s\n" "硬盘容量：" "$DISK_SIZE"
echo
echo "============================================================"
echo


# ============================================================
# 检查 /dev/shm 空间
#
# CHR 解压后的 IMG 必须放内存盘
# 避免 DD 自己所在的硬盘时继续读取 chr.img
# ============================================================

SHM_AVAILABLE_KB="$(
    df -Pk /dev/shm |
    awk 'NR==2 {print $4}'
)"


if ! [[ "$SHM_AVAILABLE_KB" =~ ^[0-9]+$ ]]; then
    die "无法读取 /dev/shm 可用容量。"
fi


SHM_AVAILABLE_MB=$((SHM_AVAILABLE_KB / 1024))


info "/dev/shm 当前可用：${SHM_AVAILABLE_MB} MB"


# 给 CHR RAW 镜像留至少 150 MiB
# 实际下载后还会再次检查

if [ "$SHM_AVAILABLE_MB" -lt 150 ]; then

    die "/dev/shm 可用空间不足。

当前：${SHM_AVAILABLE_MB} MB

为了避免把 chr.img 放在即将被 DD 的系统盘上，
脚本不会继续执行。

建议：
1. 临时增加服务器内存
或
2. 使用 VPS Rescue System 后运行脚本。"

fi


# ============================================================
# 下载 ZIP
#
# ZIP 暂时放 /tmp
# RAW IMG 解压到 /dev/shm
#
# DD 之前 ZIP 已经不再需要
# ============================================================

info "正在下载 MikroTik CHR $CHR_VERSION ..."


wget \
    --timeout=30 \
    --tries=3 \
    --progress=bar:force \
    "$CHR_URL" \
    -O "$ZIP_FILE"


[ -s "$ZIP_FILE" ] || \
    die "CHR ZIP 下载失败或文件为空。"


ok "CHR ZIP 下载完成"


# ============================================================
# 检查 ZIP
# ============================================================

info "正在检查 ZIP 文件完整性..."


if ! unzip -t "$ZIP_FILE" >/dev/null 2>&1; then
    die "下载的 CHR ZIP 文件损坏。"
fi


ok "ZIP 完整性检查通过"


# ============================================================
# 解压 IMG 到 RAM
# ============================================================

info "正在将 CHR RAW 镜像解压到内存盘..."


unzip -p \
    "$ZIP_FILE" \
    > "$IMAGE_FILE"


[ -s "$IMAGE_FILE" ] || \
    die "CHR RAW 镜像解压失败。"


rm -f "$ZIP_FILE"


IMAGE_SIZE="$(
    stat -c%s "$IMAGE_FILE"
)"


IMAGE_SIZE_MB=$((
    (IMAGE_SIZE + 1048575) / 1048576
))


ok "CHR RAW 镜像大小：${IMAGE_SIZE_MB} MB"


# ============================================================
# 检查镜像格式
# ============================================================

info "正在读取 CHR 镜像分区表..."


FDISK_OUTPUT="$(
    fdisk -lu "$IMAGE_FILE"
)"


echo
echo "------------------------------------------------------------"
echo "$FDISK_OUTPUT"
echo "------------------------------------------------------------"
echo


# ============================================================
# 自动获取第一分区 Start
# ============================================================

START_SECTOR="$(
    printf '%s\n' "$FDISK_OUTPUT" |
    awk '
        $1 ~ /chr\.img/ &&
        $2 ~ /^[0-9]+$/ {
            print $2
            exit
        }
    '
)"


# 路径可能变成 /dev/shm/.../chr.img1
# 因此上面的严格匹配失败时再宽松识别一次

if [ -z "$START_SECTOR" ]; then

    START_SECTOR="$(
        printf '%s\n' "$FDISK_OUTPUT" |
        awk '
            $1 !~ /^Disk$/ &&
            $1 !~ /^Device$/ &&
            $2 ~ /^[0-9]+$/ &&
            $3 ~ /^[0-9]+$/ {
                print $2
                exit
            }
        '
    )"

fi


[ -n "$START_SECTOR" ] || \
    die "无法读取 CHR 第一分区 Start 值。"


if ! [[ "$START_SECTOR" =~ ^[0-9]+$ ]]; then
    die "CHR Start Sector 格式异常：$START_SECTOR"
fi


# ============================================================
# 获取扇区大小
# ============================================================

SECTOR_SIZE="$(
    printf '%s\n' "$FDISK_OUTPUT" |
    awk '
        /Units: sectors of 1 \*/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    n=$i
                }
            }
            print n
            exit
        }
    '
)"


# CHR 标准扇区一般为 512
if ! [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]]; then

    warn "无法从 fdisk 自动获取 Sector Size，使用标准 512 Bytes"

    SECTOR_SIZE=512

fi


OFFSET=$((START_SECTOR * SECTOR_SIZE))


ok "第一分区 Start：$START_SECTOR"
ok "Sector Size：$SECTOR_SIZE Bytes"
ok "Mount Offset：$OFFSET Bytes"


# ============================================================
# 挂载 CHR
# ============================================================

info "正在挂载 CHR 第一分区..."


if mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR"
fi


mount \
    -o loop,offset="$OFFSET" \
    "$IMAGE_FILE" \
    "$MOUNT_DIR"


if ! mountpoint -q "$MOUNT_DIR"; then
    die "CHR 分区挂载失败。"
fi


ok "CHR 分区挂载成功"


# ============================================================
# 生成随机密码
# ============================================================

if command -v openssl >/dev/null 2>&1; then

    ADMIN_PASSWORD="$(
        openssl rand -hex 16 |
        head -c 20
    )"

else

    ADMIN_PASSWORD="$(
        tr -dc 'A-Za-z0-9' </dev/urandom |
        head -c 20
    )"

fi


[ -n "$ADMIN_PASSWORD" ] || \
    die "无法生成 RouterOS admin 密码。"


# ============================================================
# 创建 autorun.scr
# ============================================================

mkdir -p "$MOUNT_DIR/rw"


AUTORUN="$MOUNT_DIR/rw/autorun.scr"


info "正在生成 RouterOS 首次启动配置..."


cat > "$AUTORUN" <<EOF
:delay 5s

/user set [find where name="admin"] password="$ADMIN_PASSWORD"

/ip dhcp-client remove [find where interface="ether1"]

/ip address remove [find where interface="ether1"]

/ip address add address=$IP_ADDR interface=ether1 comment="CHR-AutoInstall"
EOF


# ============================================================
# /32 / Onlink
# ============================================================

if [ "$ONLINK" = "yes" ]; then

cat >> "$AUTORUN" <<EOF

/ip route add dst-address=$GATEWAY/32 gateway=ether1 scope=10 comment="CHR-Onlink-Gateway"

/ip route add dst-address=0.0.0.0/0 gateway=$GATEWAY distance=1 comment="CHR-Default-Route"
EOF

else

cat >> "$AUTORUN" <<EOF

/ip route add dst-address=0.0.0.0/0 gateway=$GATEWAY distance=1 comment="CHR-Default-Route"
EOF

fi


cat >> "$AUTORUN" <<'EOF'

/ip dns set servers=1.1.1.1,8.8.8.8

/ip service enable ssh
/ip service enable winbox

:log warning "CHR automatic installation completed"
EOF


# ============================================================
# 检查脚本内容
# ============================================================

echo
echo "============================================================"
echo "          RouterOS 首次启动配置"
echo "============================================================"
echo

cat "$AUTORUN"

echo
echo "============================================================"
echo


sync


# ============================================================
# 卸载 CHR
# ============================================================

info "正在保存并卸载 CHR 镜像..."


umount "$MOUNT_DIR"

sync


ok "CHR 镜像修改完成"


# ============================================================
# 最终信息
# ============================================================

echo
echo "################################################################"
echo -e "${RED}                     最终危险确认${RESET}"
echo "################################################################"
echo
echo "RouterOS 版本：$CHR_VERSION Stable"
echo
echo "目标磁盘："
echo
echo "    $SYSTEM_DISK"
echo
echo "目标磁盘容量："
echo
echo "    $DISK_SIZE"
echo
echo "当前 Linux 将被完整覆盖！"
echo
echo "CHR 网络配置："
echo
echo "    IP      ：$IP_ADDR"
echo "    Gateway ：$GATEWAY"
echo
echo "CHR 登录："
echo
echo "    用户名：admin"
echo "    密码  ：$ADMIN_PASSWORD"
echo
echo "################################################################"
echo


warn "请现在把上面的 admin 密码保存下来。"

echo


read -r -p "确定覆盖 $SYSTEM_DISK 请输入大写 YES ：" CONFIRM


if [ "$CONFIRM" != "YES" ]; then

    echo
    warn "安装已取消，没有执行 DD。"
    exit 0

fi


# ============================================================
# 最后再检查 IMG
# ============================================================

[ -s "$IMAGE_FILE" ] || \
    die "DD 前检查失败：CHR 镜像不存在。"


[ -b "$SYSTEM_DISK" ] || \
    die "DD 前检查失败：目标磁盘不存在。"


echo
warn "即将开始覆盖系统盘！"
warn "从现在开始不要关闭服务器。"
echo


# ============================================================
# sync
# ============================================================

sync


# ============================================================
# SysRq
#
# s = sync
# u = remount filesystem readonly
#
# CHR IMG 位于 /dev/shm，因此不依赖被覆盖的系统盘继续读取
# ============================================================

if [ -w /proc/sysrq-trigger ]; then

    info "正在同步当前 Linux 文件系统..."

    echo s > /proc/sysrq-trigger 2>/dev/null || true

    sleep 2


    info "正在将当前文件系统切换为只读..."

    echo u > /proc/sysrq-trigger 2>/dev/null || true

    sleep 2

fi


# ============================================================
# DD
# ============================================================

echo
warn "开始写入 MikroTik CHR..."
echo


dd \
    if="$IMAGE_FILE" \
    of="$SYSTEM_DISK" \
    bs=4M \
    status=progress \
    conv=fsync


DD_EXIT=$?


if [ "$DD_EXIT" -ne 0 ]; then

    echo
    error "DD 写入失败！"

    # 此时系统盘可能已经被部分覆盖
    # 不继续普通操作

    exit 1

fi


sync || true


echo
echo "============================================================"
echo -e "${GREEN}             MikroTik CHR 写入完成${RESET}"
echo "============================================================"
echo
echo "RouterOS ：$CHR_VERSION Stable"
echo
echo "管理 IP ：$IP_ONLY"
echo
echo "用户名  ：admin"
echo "密码    ：$ADMIN_PASSWORD"
echo
echo "Gateway ：$GATEWAY"
echo
echo "============================================================"
echo


ok "服务器即将强制重启进入 MikroTik CHR..."


sleep 3


# ============================================================
# 重启
# ============================================================

reboot -f
