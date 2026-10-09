# 第三方组件

MacMonitor 的温度采样使用 [vladkens/macmon](https://github.com/vladkens/macmon)，固定版本为 [v0.7.2](https://github.com/vladkens/macmon/releases/tag/v0.7.2)。macmon 使用 MIT License，完整许可见 `ThirdParty/macmon-LICENSE.txt`，安装包内副本位于 App 的 `Contents/Resources/macmon-LICENSE.txt`。

构建时从该版本的官方 Release 下载 `macmon-v0.7.2.tar.gz`，SHA-256 为：

```text
c79fdc7ab02b456b897dcc3ea041678420d7a1d5bd669aaac36fda3885572ad6
```

发布包内置其 Apple Silicon 可执行文件，不要求用户安装 Homebrew，不启动 macmon 的网络服务。macmon 通过 macOS 私有接口读取平均温度，系统更新可能影响兼容性；读数缺失时仅对应温度条降级，磁盘和电量继续显示。
