#!/bin/bash

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# 获取默认路由的网卡名称（如 eth0、ens33 等）
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}')

# 检查是否成功获取网卡名称
if [ -z "$DEFAULT_IFACE" ]; then
  echo "错误：未找到默认路由的网卡！"
  exit 1
fi

# 调试输出默认网卡信息
echo "默认网卡是: $DEFAULT_IFACE"

# 解析命令行选项
if [ "$1" == "-d" ] || [ "$1" == "--delete" ]; then
    # 删除 NAT 规则
    echo "正在删除 NAT 规则..."
    
    # 先检查是否存在该 NAT 规则
    iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null
    if [ $? -eq 0 ]; then
        iptables -t nat -D POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
        iptables-save > /etc/iptables.rules
        echo "NAT规则已删除！"
    else
        echo "错误：未找到 NAT 规则，无法删除！"
    fi
    
    exit 0
fi

# 设置 NAT 规则，使 VPN 客户端可以通过服务器访问互联网
echo "正在添加 NAT 规则..."
iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
iptables-save > /etc/iptables.rules

# 确保 iptables 规则在重启后生效
if [ ! -f /etc/rc.local ]; then
    # 如果没有 /etc/rc.local 文件，则创建它
    cat > /etc/rc.local <<EOF
#!/bin/bash
iptables-restore < /etc/iptables.rules
exit 0
EOF
    chmod +x /etc/rc.local
    echo "创建了 /etc/rc.local 文件以恢复规则。"
else
    # 如果文件已经存在，检查是否包含恢复规则的内容
    if ! grep -q "iptables-restore < /etc/iptables.rules" /etc/rc.local; then
        # 在文件末尾添加恢复规则
        echo "iptables-restore < /etc/iptables.rules" >> /etc/rc.local
        echo "已将恢复规则添加到现有的 /etc/rc.local 文件中。"
    fi
fi

echo "NAT规则添加成功！"
