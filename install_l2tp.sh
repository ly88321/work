#!/bin/bash

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# 更新系统并安装必要的软件
apt update -y && apt install -y xl2tpd ppp

# 配置 xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = no
listen-addr = 0.0.0.0

[lns default]
ip range = 10.8.8.100-10.8.8.200
local ip = 10.8.8.254
require chap = yes
refuse pap = yes
require authentication = yes
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# 配置 PPP 选项
cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
mtu 1400
mru 1400
crtscts
lock
hide-password
local
debug
proxyarp
name l2tpd
lcp-echo-interval 30
lcp-echo-failure 4
EOF

# 配置 VPN 账户
cat > /etc/ppp/chap-secrets <<EOF
# 用户名 服务端  密码  分配IP
admin  *  passwd  10.8.8.8
EOF

# 启用 IP 转发
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p


# 启动并启用 xl2tpd 服务
systemctl restart xl2tpd
systemctl enable xl2tpd

# 提示安装完成
echo "Its Ok!"
