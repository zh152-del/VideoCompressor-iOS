# Windows 构建说明

你当前的主要电脑是 **Windows**，而 iOS 应用只能在 **macOS + Xcode** 下编译与签名。本文件明确划分「Windows 能做什么」与「必须 macOS / GitHub Actions 的部分」。

## ✅ 在 Windows 上可以完成

- 编写 / 阅读全部 Swift 源码、资源与文档（纯文本）
- 维护 `project.yml`（xcodegen 工程定义）、`Info.plist`、单元测试
- 初始化 Git 仓库、提交代码、推送到 GitHub
- 创建 GitHub Actions 工作流（`.github/workflows/ci.yml`）
- 通过 GitHub Actions（macOS runner）**远程触发真实编译与测试**
- 下载 CI 产出的**未签名 IPA** 与构建日志
- 用爱思助手在 Windows 上对未签名 IPA **手动签名并安装**

## ❌ 无法在 Windows 上完成（平台限制，并非需求变更）

- 本地使用 Xcode 打开 / 编译 / 归档 iOS 工程（无 `xcodebuild` / `iphoneos` SDK）
- 本地运行模拟器 / 真机调试
- 任何需要 Apple 证书 / 私钥 / Provisioning Profile 的签名操作

## 推荐的 Windows 工作流

1. 在 Windows 上用任意编辑器修改源码与 `project.yml`。
2. `git commit` 并 `git push` 到 GitHub（触发 Actions）。
3. 在 GitHub 仓库 **Actions** 页面查看编译 / 测试结果：
   - 绿色 ✓ → 进入 **Artifacts** 下载 `VideoCompressor-unsigned-ipa`。
   - 红色 ✗ → 展开日志，按错误信息修复（常见为 Swift 语法 / API 不可用 / 缺少导入）。
4. 用爱思助手对下载的未签名 IPA 签名并安装（见 `SigningGuide.md`）。

## 本地（macOS）可选工作流

如果你或团队成员有 Mac：

```bash
brew install xcodegen
xcodegen generate
open VideoCompressor.xcodeproj
# 用免费 / 付费 Apple ID 选择设备，Product › Archive，按提示签名分发
```

## 说明

- 本项目**不依赖任何第三方库**，运行时**完全离线**。
- CI 使用 `CODE_SIGNING_ALLOWED=NO` 产出未签名 IPA，**不包含任何证书或密钥**。
- 仓库中已 gitignore 生成产物（`.xcodeproj`、`build/`、`.ipa`），保持源码纯净。
