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

# 设置 NAT 规则，使 VPN 客户端可以通过服务器访问互联网
iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
# iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save > /etc/iptables.rules

# 确保 iptables 规则在重启后生效
cat > /etc/rc.local <<EOF
#!/bin/bash
iptables-restore < /etc/iptables.rules
exit 0
EOF
chmod +x /etc/rc.local

echo "NAT规则添加成功！"