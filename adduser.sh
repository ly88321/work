#!/bin/bash

# 检查用户名和密码参数
if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
  echo "用法: $0 <用户名> <密码> [<分配IP>]"
  exit 1
fi

USERNAME=$1
PASSWORD=$2
IP=${3:-"*"}  # 如果没有提供 IP，默认使用 "*"

# 添加用户到 chap-secrets
echo "$USERNAME * $PASSWORD $IP" | sudo tee -a /etc/ppp/chap-secrets > /dev/null

# 重新加载 pppd 配置
sudo kill -HUP $(pgrep pppd)

echo "用户 $USERNAME 添加成功！"

