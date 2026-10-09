# MacMonitor 安装说明

适用于 Apple Silicon、macOS 14 或更新版本。安装包内置温度采样器，无需 Homebrew、开发工具或管理员密码。

## 直接打开

打开 DMG 或解压 ZIP，把 `MacMonitor.app` 拖入 Applications，再双击 App。它只在菜单栏显示三根竖条，点击可看温度、磁盘已用和电量。

## 登录自动启动

双击同目录的 `安装并启用自启动.command`。该安装器复制 App 到个人 Applications，启用专用登录启动项，并在更新时备份上一版。安装完成后可关闭终端窗口并推出 DMG。

直接拖动安装和使用安装器二选一即可。安装器沿用本项目早期版本的内部 App 文件名；菜单栏显示名称为“Mac 三条”。

## 首次打开提示

此公开测试版使用 ad hoc 签名，尚无 Developer ID 签名和 Apple 公证。macOS 可能阻止首次打开。

请从 [官方 Releases](https://github.com/EOShoow/MacMonitor/releases) 下载。发布页包含 `SHA256SUMS.txt`，可核对安装包的 SHA-256。确认来源后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 在“系统设置 → 隐私与安全性”中对这个 App 选择“仍要打开”。无需关闭系统全局安全保护。

如果提示仍无法解除，可从公开仓库在本机构建或反馈具体报错；不要执行关闭 Gatekeeper 的命令。

## 使用与卸载

- 左条温度，中条磁盘已用，右条电池剩余；详细数字在面板内。
- 接电时续航估算暂停学习；台式 Mac 没有内置电池时，电量显示不可用。
- 点击面板“退出”停止程序。正常退出后不立即自动重启，下次登录仍会启动。
- 若用安装器启用了登录启动，先退出 App，再将专用 `~/Library/LaunchAgents/com.eoshow.mac-monitor-preview.plist` 和安装的 App 移到废纸篓；下次登录不再启动。续航历史单独保存在 `~/.local/state/mac-monitor-preview/`。
- 反馈问题：[GitHub Issues](https://github.com/EOShoow/MacMonitor/issues)。
