#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

apt update && apt upgrade -y
apt install -y curl wget sudo git unzip software-properties-common \
  apt-transport-https ca-certificates gnupg lsb-release

timedatectl set-timezone Asia/Shanghai

curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
  | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
  http://nginx.org/packages/mainline/debian bookworm nginx" \
  | tee /etc/apt/sources.list.d/nginx.list

echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
  | tee /etc/apt/preferences.d/99nginx

apt update && apt install -y nginx

sed -i 's/^user.*/user www-data;/' /etc/nginx/nginx.conf

systemctl start nginx && systemctl enable nginx

curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
  https://packages.redis.io/deb bookworm main" | tee /etc/apt/sources.list.d/redis.list

apt update && apt install -y redis

sed -i 's/^# bind 127.0.0.1 ::1/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

systemctl restart redis-server && systemctl enable redis-server

mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp \
  'https://mariadb.org/mariadb_release_signing_key.pgp'

cat > /etc/apt/sources.list.d/mariadb.sources <<EOF
X-RepoLib-Name: MariaDB
Types: deb
URIs: https://deb.mariadb.org/11.8/debian
Suites: bookworm
Components: main
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF

# 安装 MariaDB
apt update && apt install -y mariadb-server mariadb-client

# 启动服务
systemctl start mariadb && systemctl enable mariadb

# 安全初始化
mariadb-secure-installation <<EOF
\n
n
n
y
y
y
y
EOF

# 生成安全密码
DB_PASSWORD=$(openssl rand -base64 16)
echo "请牢记数据库密码！！！ 数据库密码：$DB_PASSWORD"

# 创建数据库和用户（使用 mariadb 命令，避免弃用警告）
mariadb -u root <<EOF
CREATE DATABASE ppanel_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
FLUSH PRIVILEGES;
EOF

# 创建配置目录
mkdir -p /etc/nginx/conf.d

read -p "请输入后台API地址: " domain

# 创建站点配置
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_http_version 1.1;

        add_header X-Cache \$upstream_cache_status;

        proxy_pass http://127.0.0.1:8080;
    }

    location ~* \.(gif|png|jpg|css|js|woff|woff2)$ {
        expires 30d;
        add_header Cache-Control public;
    }
}
EOF


# 测试配置
nginx -t

# 重载 Nginx
systemctl reload nginx

# 安装 Certbot
apt install -y certbot python3-certbot-nginx

# 获取证书
certbot --nginx -d $domain --non-interactive --agree-tos -m admin@$domain

wget -O ppanel-server-linux-amd64.tar.gz \
  https://github.com/perfect-panel/server/releases/latest/download/ppanel-server-linux-amd64.tar.gz

tar -zxvf ppanel-server-linux-amd64.tar.gz

sudo mv ppanel-server /usr/local/bin/ppanel-server
sudo mkdir -p /usr/local/etc/ppanel
sudo mv ./etc/ppanel.yaml /usr/local/etc/ppanel/
sudo chmod +x /usr/local/bin/ppanel-server
AccessSecret=$(openssl rand -base64 16)
cat > /usr/local/etc/ppanel/ppanel.yaml <<EOF
Host: 127.0.0.1
Port: 8080
Debug: false

JwtAuth:
  AccessSecret: $AccessSecret
  AccessExpire: 604800

Logger:
  FilePath: /var/log/ppanel/ppanel.log
  MaxSize: 50
  MaxBackup: 3
  MaxAge: 30
  Compress: true
  Level: info

MySQL:
  Addr: 127.0.0.1:3306
  Username: root
  Password: $DB_PASSWORD
  Dbname: ppanel_db
  Config: charset=utf8mb4&parseTime=true&loc=Asia%2FShanghai
  MaxIdleConns: 10
  MaxOpenConns: 100
  LogMode: info
  LogZap: true
  SlowThreshold: 1000

Redis:
  Host: 127.0.0.1:6379
  Pass: ''
  DB: 0

Administrator:
  Email: admin@ppanel.dev
  Password: password
EOF

cat > /etc/systemd/system/ppanel.service <<EOF
[Unit]
Description=PPANEL Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ppanel-server run --config /usr/local/etc/ppanel/ppanel.yaml
Restart=always
User=root
WorkingDirectory=/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start ppanel
systemctl enable ppanel

echo "您的管理员账户为：admin@ppanel.dev 密码为：password ，请登陆后台后及时修改管理员账户和密码"
