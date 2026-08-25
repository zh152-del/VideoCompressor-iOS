# VideoCompressor-iOS

一款**完全在 iPhone 本机运行**的本地视频压缩工具。所有视频处理均由 iOS 原生 AVFoundation 完成，**不上传、不联网、不需要账号**，无任何云端依赖。

- 从照片图库选择单个或多个视频
- 快速 / 平衡 / 高压缩 / 自定义 四种压缩模式
- 自定义：分辨率、帧率、画质、编码（H.264 / HEVC）、目标文件大小
- 批量压缩、压缩进度与取消、压缩前后大小对比
- 压缩完成后保存到照片图库，可选「保存成功后删除原片」
- 压缩历史、临时文件生命周期管理
- 浅色 / 深色模式、适配刘海与灵动岛、支持 Dynamic Type

---

## ⚠️ 关于 IPA 与签名（请先读）

- 本项目在 GitHub Actions（macOS runner）上**真实编译**并产出 **未签名 IPA**。
- **未签名 IPA 不能直接安装到普通 iPhone**，需要重新签名。
- 你已选择用 **爱思助手** 在 Windows 上手动签名安装，具体步骤见 [SigningGuide.md](SigningGuide.md)。
- 本项目**不包含任何证书、私钥、Provisioning Profile、Token**。需要已签名 IPA，请按签名教程提供签名（免费 Apple ID 或付费开发者账号）。

> 源码完成 ≠ 编译完成；编译完成 ≠ 签名完成；签名完成 ≠ 已验证安装。请以真实构建与真实设备验证结果为准。

---

## 技术架构

| 模块 | 职责 |
|---|---|
| `App` | 应用入口、环境对象装配 |
| `UI` | SwiftUI 界面（首页 / 进度 / 结果 / 历史 / 设置） |
| `Compression` | 压缩编排、AVAssetExportSession 预设引擎、AVAssetReader/Writer 自定义转码引擎、码率计算、编码能力探测 |
| `Photos` | 照片权限、保存、删除原片（严格「先保存成功再删除」） |
| `Storage` | 临时文件生命周期管理 |
| `History` | 本地历史记录（JSON） |
| `Settings` | 用户设置（UserDefaults） |
| `Models` / `Utilities` | 数据模型与通用工具 |

**压缩实现优先使用 iOS 原生能力**：
- 快速 / 平衡 / 高压缩 → `AVAssetExportSession`（硬件加速，自动选择不超过源分辨率的安全预设）
- 自定义 → `AVAssetReader` + `AVAssetWriter`（VideoToolbox 硬件编码，支持分辨率/帧率/质量/编码/目标大小，绝不放大低分辨率视频）

---

## 项目结构

```
VideoCompressor-iOS/
├── VideoCompressor/
│   ├── App/                  # @main 入口
│   ├── Models/              # 数据模型（错误/配置/结果/历史）
│   ├── Compression/         # 压缩核心（服务/引擎/码率/探测/信息读取）
│   ├── Photos/              # 照片库权限与读写
│   ├── Storage/             # 临时文件管理
│   ├── History/             # 历史记录
│   ├── Settings/            # 设置
│   ├── UI/                  # SwiftUI 界面与组件
│   └── Resources/           # Info.plist / entitlements / Assets
├── VideoCompressorTests/    # XCTest 单元测试
├── project.yml              # xcodegen 工程定义
├── .github/workflows/ci.yml # GitHub Actions 自动构建
├── README.md
├── WindowsBuild.md          # Windows 能/不能做什么
├── SigningGuide.md          # 爱思助手签名安装教程
└── LICENSE
```

---

## 环境要求

- **开发系统**：macOS + Xcode 15+（编译/签名所需）
- **最低系统**：iOS 16.0
- **依赖**：仅需 `xcodegen`（用于从 `project.yml` 生成 Xcode 工程）；运行时零第三方库、零网络

---

## 在 macOS 本地构建

```bash
# 1. 安装工程生成工具
brew install xcodegen

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 打开并运行 / 归档
open VideoCompressor.xcodeproj
# 或在命令行：
xcodebuild build -scheme VideoCompressor -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
```

---

## GitHub Actions 自动构建

每次 `push` 到 `main` 会触发 `.github/workflows/ci.yml`：

1. 拉取代码
2. 安装 `xcodegen`
3. 生成工程
4. 在 iOS 模拟器上**编译并运行单元测试**
5. 以 `CODE_SIGNING_ALLOWED=NO` **编译 Release（设备）**
6. 打包为 **未签名 IPA** 并作为 Artifact 上传

> CI 无法合法完成「已签名 IPA」（无你的证书/私钥），因此产物为未签名 IPA。已签名 IPA 需由你本地或提供签名 Secrets 完成。

---

## 隐私

- 全程本地处理，视频**不会**离开设备。
- 不申请定位 / 麦克风 / 相机 / 蓝牙 / 网络权限。
- 仅申请「照片」相关权限：选择视频（隐私友好，PHPicker 无需前置授权）、保存结果、删除原片。

---

## 已知限制

- 未签名 IPA 需重新签名才能安装（见签名教程）。
- 降低帧率通过抽帧实现，可能损失部分流畅度。
- 部分老设备不支持 HEVC 编码，自定义选择 HEVC 时会自动回退 H.264。
- 目标文件大小为依据码率估算，实际体积会有偏差。
- 在纯 Windows 环境无法编译 iOS 应用，编译/签名必须依赖 macOS 或 GitHub Actions。
