# AnyTLS Installer

适用于 Ubuntu / Debian / CentOS / RHEL / Fedora 的 [AnyTLS-Go](https://github.com/anytls/anytls-go) 一键安装管理脚本。

基于 [tianrking/AnyTLS-Go-Script](https://github.com/tianrking/AnyTLS-Go-Script) 优化。

## 功能

- 自动获取最新版本（不再硬编码版本号）
- 自动检测架构（amd64 / arm64）
- 同时安装 `anytls-server` 和 `anytls-client`
- **内置订阅服务** — 一个链接兼容所有客户端
- systemd 服务管理（开机自启、启停、日志）
- 密码支持随机生成
- 安装后可直接用 `anytls` 命令管理

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Mike09811/AnyTLS-Installer/main/install.sh) install
```

## 订阅链接

安装完成后会自动生成订阅链接，格式如下：

| 客户端 | 链接 |
|--------|------|
| Shadowrocket / NekoBox / 通用 | `http://IP:SUB_PORT/sub/TOKEN` |
| Clash / Mihomo | `http://IP:SUB_PORT/sub/TOKEN?client=clash` |
| sing-box | `http://IP:SUB_PORT/sub/TOKEN?client=singbox` |

随时查看订阅链接：
```bash
anytls info
```

## 管理命令

```bash
sudo anytls install      # 安装/更新
sudo anytls uninstall    # 卸载
sudo anytls start        # 启动
sudo anytls stop         # 停止
sudo anytls restart      # 重启
     anytls status       # 查看状态
     anytls log          # 查看日志 (可加 -n 50)
     anytls info         # 显示订阅链接
     anytls help         # 帮助
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
- curl、unzip、python3（脚本会自动安装）

## License

MIT
