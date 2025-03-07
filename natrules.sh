#!/bin/bash

# 日志文件路径
LOG_FILE="/var/log/iptables-setup.log"

# 记录日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    log "请使用 root 用户运行此脚本！"
    exit 1
fi

# 获取默认路由的网卡名称（如 eth0、ens33 等）
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}')

# 检查是否成功获取网卡名称
if [ -z "$DEFAULT_IFACE" ]; then
    log "错误：未找到默认路由的网卡！"
    exit 1
fi

# 打印调试信息：确认网卡名称
log "默认网卡是: $DEFAULT_IFACE"

# 打印所有传入参数
log "传入的参数是: $1"

# 检查 iptables 命令是否存在
if ! command -v iptables &> /dev/null; then
    log "错误：iptables 命令未找到，请确保已安装 iptables！"
    exit 1
fi

# 检查 iptables-save 和 iptables-restore 路径
IPTABLES_SAVE=$(which iptables-save)
IPTABLES_RESTORE=$(which iptables-restore)

if [ -z "$IPTABLES_SAVE" ] || [ -z "$IPTABLES_RESTORE" ]; then
    log "错误：iptables-save 或 iptables-restore 未找到！"
    exit 1
fi

# 规则保存路径
RULES_FILE="/etc/iptables/rules.v4"

# 创建规则保存目录（如果不存在）
mkdir -p /etc/iptables

# 删除 NAT 规则函数
delete_nat_rule() {
    log "检测到删除参数 -d 或 --delete，正在删除 NAT 规则..."
    
    # 先检查是否存在该 NAT 规则
    if iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null; then
        log "找到了 NAT 规则，正在删除..."
        iptables -t nat -D POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
        $IPTABLES_SAVE > "$RULES_FILE"
        log "NAT 规则已删除！"
    else
        log "错误：未找到 NAT 规则，无法删除！"
    fi
}

# 添加 NAT 规则函数
add_nat_rule() {
    log "检查是否已存在 MASQUERADE 规则..."
    if iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null; then
        log "MASQUERADE 规则已存在，跳过添加。"
    else
        # 如果没有找到规则，添加 NAT 规则
        log "MASQUERADE 规则不存在，正在添加..."
        iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
        $IPTABLES_SAVE > "$RULES_FILE"
        log "NAT 规则添加成功！"
    fi
}

# 创建 systemd 服务函数
create_systemd_service() {
    local SERVICE_PATH="/etc/systemd/system/iptables-restore.service"

    if [ ! -f "$SERVICE_PATH" ]; then
        log "创建 systemd 服务单元文件..."
        cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=$IPTABLES_RESTORE -c $RULES_FILE
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
        # 重新加载 systemd 配置
        systemctl daemon-reload

        # 启用和启动 iptables 恢复服务
        systemctl enable iptables-restore.service
        systemctl start iptables-restore.service
        log "systemd 服务已创建并启用，规则将被恢复。"
    else
        log "systemd 服务单元文件已存在，跳过创建。"
    fi
}

# 解析命令行选项
if [ "$1" == "-d" ] || [ "$1" == "--delete" ]; then
    delete_nat_rule
    exit 0
fi

# 添加 NAT 规则
add_nat_rule

# 创建 systemd 服务
create_systemd_service

# 提示用户完成
log "脚本执行完毕！"
