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

1. [Google Cloud Console](https://console.cloud.google.com/) 创建项目
2. **API 和服务 → 库 → 搜索「Gmail API」→ 启用**（必须，否则同步报 403）
3. 配置 OAuth 同意屏幕（用户类型选「外部」或「内部」均可）
4. **OAuth 同意屏幕 → 测试用户 → 添加你的 Gmail 邮箱**
5. 创建 OAuth 客户端 ID → 类型选 **「桌面应用」**
6. 在应用 **设置** 填入 Client ID / Secret（Redirect URI 默认 `http://127.0.0.1:8765/`）
7. **Gmail** 页面连接账号，在 **影院规则** 配置发件人/主题与模板

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

### 推荐：每次发版一条龙

改完代码后，在终端执行（把说明换成你这次改了什么）：

```bash
cd ~/Projects/ReceiptPrinter

# 修 bug 发版（1.0.0 → 1.0.1）
./scripts/release.sh patch "修复某某问题"

# 加了新功能（1.0.0 → 1.1.0）
./scripts/release.sh minor "新增某某功能"

# 然后按脚本提示推送
git push origin main
git push origin v1.0.1   # 版本号换成脚本输出的那个
```

脚本会自动：更新 `VERSION` → 打包 `dist/ReceiptPrinter.app` → `git commit` → 打标签。

### 平时只改代码、不上传

```bash
git add .
git commit -m "改了电影票模板"
git push origin main
```

不必每次都发版；只有要给用户新安装包时，才跑 `release.sh`。

### 两个概念（不用背）

| 概念 | 是什么 | 在哪 |
|------|--------|------|
| **应用版本** | 用户看到的 1.0.0 | `VERSION` 文件 + 设置页 |
| **代码快照** | 某次改动的记录 | Git commit / GitHub |

### 代码历史（Git）

```bash
git status              # 看改了哪些文件
git add .               # 暂存所有改动
git commit -m "说明"    # 保存一个版本快照
git log --oneline       # 查看历史
```

详细改动记在 [CHANGELOG.md](CHANGELOG.md)。
