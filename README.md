# AnyTLS Installer|AnyTLS 一键安装脚本

[AnyTLS-Go](https://github.com/anytls/anytls-go) 一键安装管理脚本，支持 Ubuntu / Debian / CentOS / RHEL / Fedora。

## Features

- 自动获取最新版本，自动检测架构 (amd64 / arm64)
- 同时安装 `anytls-server` 和 `anytls-client`
- 内置订阅服务，一个链接兼容 Shadowrocket / NekoBox / Clash / sing-box
- BBR 拥塞控制 + 内核网络优化
- 随机密码 / 随机 SNI 伪装域名
- systemd 服务管理，安装后直接用 `anytls` 命令

## Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Mike09811/AnyTLS-Installer/main/install.sh) install
```

## Subscription

安装完成后自动生成订阅链接：

| Client | URL |
|--------|-----|
| Shadowrocket / NekoBox / 通用 | `http://IP:SUB_PORT/sub/TOKEN` |
| Clash / Mihomo | `http://IP:SUB_PORT/sub/TOKEN?client=clash` |
| sing-box | `http://IP:SUB_PORT/sub/TOKEN?client=singbox` |

查看订阅链接：`anytls info`

## Commands

```bash
sudo anytls install      # 安装/更新
sudo anytls uninstall    # 卸载
sudo anytls start        # 启动
sudo anytls stop         # 停止
sudo anytls restart      # 重启
sudo anytls bbr          # 启用 BBR 加速
     anytls status       # 查看状态
     anytls log          # 查看日志
     anytls info         # 显示订阅链接
     anytls help         # 帮助
```

## Supported Clients

- Shadowrocket (iOS 2.2.65+)
- NekoBox (Android 1.3.8+)
- sing-box (多平台)
- mihomo / Clash Meta (多平台)

> 已自动配置 `insecure=1` 和 SNI，客户端无需手动设置。

## Requirements

- Linux (Ubuntu / Debian / CentOS / RHEL / Fedora)
- root 权限
- curl / unzip / python3 (脚本自动安装)

## License

MIT
