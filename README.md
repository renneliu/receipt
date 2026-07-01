# ReceiptPrinter

macOS 热敏小票打印机软件：CUPS Raw 打印、模板设计、照片识别、Gmail 订单邮件半自动打印。

## 系统要求

- macOS 14+
- Swift 6.x（Xcode 或 Command Line Tools）
- USB 热敏打印机已在系统中添加为 Generic/Raw 驱动

## 构建

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/ReceiptPrinter.app
```

或使用 Swift Package Manager：

```bash
swift build
.build/debug/ReceiptPrinter
```

## 打印机配置

1. 连接 USB 热敏打印机
2. **系统设置 → 打印机与扫描仪 → 添加打印机**，驱动选 **Generic**
3. 在应用 **设置** 中选择对应 CUPS 打印机名称

## Gmail 配置

1. [Google Cloud Console](https://console.cloud.google.com/) 创建项目并启用 Gmail API
2. 配置 OAuth 同意屏幕，添加测试用户
3. 创建「桌面应用」OAuth Client ID
4. 在应用 **设置** 填入 Client ID / Secret
5. **Gmail** 页面连接账号，在 **影院规则** 配置匹配条件与字段正则

## 功能

- 快速打印 / ESC/POS 测试页
- 可视化模板设计器（80mm）
- 小票照片 OCR 识别生成模板
- Gmail 订单邮件匹配 → 通知 → 确认打印
- 按影院规则绑定不同模板

## 拍摄小票照片建议

- 正面平拍，避免倾斜
- 光线充足，避免阴影
- 尽量填满画面，减少背景

## 版本管理（简明）

项目里只有一个版本文件需要关心：

**`VERSION`**（两行）
```
1.0.0    ← 第 1 行：给用户看的版本号
1        ← 第 2 行：构建号（每次打包递增）
```

### 日常怎么用

| 你想做什么 | 命令 |
|-----------|------|
| 查看当前版本 | `./scripts/bump-version.sh show` |
| 打包前自动 +1 构建号 | `./scripts/bump-version.sh` |
| 修了一个小 bug | `./scripts/bump-version.sh patch` |
| 加了一个新功能 | `./scripts/bump-version.sh minor` |
| 打包正式版 | `./scripts/bump-version.sh && ./scripts/build-app.sh` |
| 打包调试版 | `./scripts/build-debug-app.sh` |

打包后可在应用 **设置 → 关于** 看到版本号。

### 代码历史（Git）

```bash
git status              # 看改了哪些文件
git add .               # 暂存所有改动
git commit -m "说明"    # 保存一个版本快照
git log --oneline       # 查看历史
```

详细改动记在 [CHANGELOG.md](CHANGELOG.md)。
