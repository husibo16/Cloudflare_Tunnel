# Cloudflare_Tunnel
一键安装脚本（Cloudflare Tunnel）

📘 脚本功能说明
🧱 自动安装 cloudflared	下载并放入 /usr/local/bin/
🔐 登录 Cloudflare	浏览器登录授权域名管理权限
🧩 创建 tunnel	建立专属隧道 UUID
🌐 绑定域名	把你的域名（如 www.jbr16.top）绑定到隧道
⚙️ 写入配置文件	自动创建 /root/.cloudflared/config.yml
🧰 systemd 自启	开机自动运行隧道服务
