# OpenWrt 自动安装与扩容脚本

脚本文件：

`openwrt-auto-install.sh`

适用于 `x86/64 + EFI + ext4 combined image` 的 OpenWrt 安装场景。

## 快速运行

请先将下面命令里的 `YOUR_URL` 替换成脚本实际的 CDN 地址。

### 使用 `wget`

```sh
wget -O - "YOUR_URL" | sh
```

### 使用 `curl`

```sh
curl -fsSL "YOUR_URL" | sh
```

## 常用示例

### 交互式安装

脚本会自动尝试识别目标盘；如果无法确定，会弹出菜单让你选择。

```sh
wget -O - "YOUR_URL" | sh -s -- install
```

### 安装并跳过确认

适合无人值守场景。该命令只负责写盘，不会自动扩容。

```sh
wget -O - "YOUR_URL" | sh -s -- install -y
```

### 指定目标盘安装

```sh
wget -O - "YOUR_URL" | sh -s -- install -d /dev/sdb
```

### 单独执行扩容

请先重启进入目标盘上的 OpenWrt，再执行扩容：

```sh
wget -O - "YOUR_URL" | sh -s -- expand
```

### 指定磁盘扩容

```sh
wget -O - "YOUR_URL" | sh -s -- expand -d /dev/sda
```

## 脚本行为说明

- `install` 会下载或使用本地镜像，把 OpenWrt 写入目标磁盘
- `install` 只负责写盘，不会在 Live 环境里直接扩容
- 重启进入目标盘上的 OpenWrt 后，再执行 `expand`
- `expand` 会把第 `2` 分区扩到目标磁盘剩余空间上限
- 扩容后会自动更新 `/boot/grub/grub.cfg` 里的 `root=PARTUUID=...`
- 如果未传 `-d`，脚本会优先自动识别；识别失败时进入菜单选盘

## 建议

- 首次使用建议不要加 `-y`，先走交互模式确认磁盘选择
- 在生产环境执行前，先确认目标设备名是否正确
- 如果是通过 Live OpenWrt 或 U 盘环境安装，完成后记得拔掉启动介质再重启
- 推荐流程是：`install` -> 重启进目标盘系统 -> `expand`
