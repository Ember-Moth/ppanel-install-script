#!/bin/bash

apt update
apt install -y curl wget gnupg2 ca-certificates lsb-release sudo apt-transport-https

curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx

curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
echo "X-Repolib-Name: MariaDB" | sudo tee /etc/apt/sources.list.d/mariadb.sources
echo "Types: deb" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "URIs: https://deb.mariadb.org/11.4/debian" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Suites: bookworm" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Components: main" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources

apt update

apt install -y nginx redis-server mariadb-server jq

systemctl start nginx
systemctl enable nginx
systemctl start redis-server
systemctl enable redis-server
systemctl start mariadb
systemctl enable mariadb

mariadb-secure-installation <<EOF
\n
n
n
y
y
y
y
EOF

read -p "请输入要创建的数据库名称: " dbname
read -p "请创建数据库用户名: " dbuser
read -p "请创建数据库用户密码: " dbpass
echo

mariadb -u root <<EOF
CREATE DATABASE $dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';
GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost';
FLUSH PRIVILEGES;
EOF

sed -i 's/user nginx;/user www-data;/g' /etc/nginx/nginx.conf

read -p "请输入要监听的域名（若无可用域名请回车跳过）: " server_name
server_name=${server_name:-_}

cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $server_name;

    # 默认代理设置
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_http_version 1.1;

        add_header X-Cache \$upstream_cache_status;

        # 配置代理到后端服务
        proxy_pass http://127.0.0.1:8080;
    }

    # 设置静态资源缓存
    location ~* \.(gif|png|jpg|css|js|woff|woff2)$ {
        expires 30d;
        add_header Cache-Control public;
    }
}
EOF

systemctl restart nginx

LATEST_VERSION=$(curl -s https://api.github.com/repos/perfect-panel/ppanel/releases/latest | jq -r .tag_name)
DOWNLOAD_URL="https://github.com/perfect-panel/ppanel/releases/download/$LATEST_VERSION/ppanel-server-$LATEST_VERSION-linux-amd64.tar.gz"
wget $DOWNLOAD_URL -O ppanel-server-latest.tar.gz
tar -zxvf ppanel-server-latest.tar.gz
rm ppanel-server-latest.tar.gz
sudo mv ppanel-server /usr/local/bin/ppanel
sudo mkdir -p /usr/local/etc/ppanel
sudo mv ./etc/ppanel.yaml /usr/local/etc/ppanel/
sudo chmod +x /usr/local/bin/ppanel
rm LICENSE
rm -rf etc

cat > /usr/local/etc/ppanel/ppanel.yaml <<EOF
Host: 127.0.0.1
Port: 8080
Debug: false
JwtAuth:
  AccessSecret: d2a1b58958f13ab01shekdd123fcd12345xyz67890==
  AccessExpire: 604800
Logger:
  FilePath: ./ppanel.log
  MaxSize: 50
  MaxBackup: 3
  MaxAge: 30
  Compress: true
  Level: info
MySQL:
  Addr: 127.0.0.1:3306
  Username: $dbuser
  Password: $dbpass
  Dbname: $dbname
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
Administer:
  Email: admin@ppanel.dev
  Password: password
EOF

cat > /etc/systemd/system/ppanel.service <<EOF
[Unit]
Description=PPANEL Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ppanel run --config /usr/local/etc/ppanel/ppanel.yaml
Restart=always
User=root
WorkingDirectory=/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ppanel
systemctl start ppanel

if systemctl is-active --quiet ppanel; then
    if [ "$server_name" = "_" ]; then
        public_ip=$(curl -4 -s ifconfig.me)
        echo "ppanel安装成功! 您的API地址为：http://$public_ip"
    else
        echo "ppanel安装成功！您的API地址为：http://$server_name"
    fi
else
    echo "ppanel安装失败！"
fi
