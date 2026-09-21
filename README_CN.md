# OpenCode Mobile

<p align="center">
  <b>🖥️ Windows 桌面端</b><br />
  <img src="./docs/windows.png" width="96%" alt="Windows 桌面端" />
</p>

<div align="center">

| 📱 手机端 | 💻 平板端 |
| :---: | :---: |
| <img src="./docs/phone.jpg" width="280" alt="手机端" /> | <img src="./docs/tablet.jpg" width="600" alt="平板端" /> |

</div>

<p align="center">
  <a href="./README.md">English</a> | <b>简体中文</b>
</p>

> [!WARNING]
> **非官方项目** — 本项目为 OpenCode 的**非官方**移动端与桌面端客户端。

---

> [!IMPORTANT]
> 如遇历史消息无法继续聊天，请立即更新 OpenCode 版本。如果是按照 [docs/server.md](./docs/server.md) 中安装的，升级完执行 `sudo systemctl restart opencode`。

---

现在的 token 实在是太贵了，deepseek flash 都用不起了，就开源了。

我的 Windows 离线语音转文本项目，已上架微软商店：
- 微软商店：https://apps.microsoft.com/detail/9pdf92ts07pf
- 使用文档：https://owlmeeting.com/docs/en/
- 小小支持：下载试用版，给个好评
- 大力支持：你懂的

---

## 📱 项目简介

**OpenCode Mobile** 是基于 **Flutter** 和 **Rust** 开发的 OpenCode **非官方**客户端（支持 Android 与 Windows），通过 Basic Auth 连接远程 `opencode serve` 后端。

目前已针对手机、平板及 Windows 桌面端进行深度适配：
- **Windows 桌面端**：无边框窗口与自定义标题栏、Chrome/VS Code 风格多会话页签（支持拖拽排序/滚轮滚动/中键关闭）、输入法防误触的快捷键体系（Enter 发送、Shift+Enter 换行、Esc 取消）、剪贴板图像一键粘贴等。
- **手机端**：简洁高效的单栏对话界面，内置常用语、终端、文件树及浏览器预览。
- **平板端**：基于分屏优化的双栏/多栏布局，大屏空间利用更充分。

---

## 🛠️ 本地开发与构建

### 环境要求
- **Flutter SDK**：3.38.5（Dart 3.10）
- **Rust**：支持 1.88

### 常用命令
```bash
# 获取依赖
flutter pub get

cd rust
cargo build --release
```

### 须知
大部分 api 是基于 opencode v1，当时在写这个项目的时候，v2 版本 session 部分的 api 状态控制有问题，调不好。现在不知道还有没有问题。

