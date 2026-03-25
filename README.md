# AnyTLS Installer

适用于 Ubuntu / Debian / CentOS / RHEL / Fedora 的 [AnyTLS-Go](https://github.com/anytls/anytls-go) 一键安装管理脚本。

基于 [tianrking/AnyTLS-Go-Script](https://github.com/tianrking/AnyTLS-Go-Script) 优化。

## 功能

- 自动获取最新版本（不再硬编码版本号）
- 自动检测架构（amd64 / arm64）
- 同时安装 `anytls-server` 和 `anytls-client`
- systemd 服务管理（开机自启、启停、日志）
- 自动获取公网 IP，生成 NekoBox / Shadowrocket 二维码
- 支持一键卸载

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Mike09811/AnyTLS-Installer/main/install.sh) install
```

## 用法

```bash
sudo ./install.sh install      # 安装/更新
sudo ./install.sh uninstall    # 卸载
sudo ./install.sh start        # 启动
sudo ./install.sh stop         # 停止
sudo ./install.sh restart      # 重启
     ./install.sh status       # 查看状态
     ./install.sh log          # 查看日志 (可加 -n 50)
     ./install.sh qr           # 重新生成二维码
     ./install.sh help         # 帮助
```

## 支持的客户端

- **Shadowrocket** (iOS 2.2.65+)
- **NekoBox** (Android 1.3.8+)
- **sing-box** (多平台)
- **mihomo / Clash Meta** (多平台)

> 注意: anytls-go 使用自签名证书，客户端需开启「允许不安全」选项。

## 系统要求

- Linux (Ubuntu / Debian / CentOS / RHEL / Fedora)
- root 权限
- curl、unzip（脚本会自动安装）

## License

MIT
