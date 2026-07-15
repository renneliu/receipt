# ReceiptPrinter

macOS 热敏小票打印机软件：CUPS Raw 光栅打印、富文本快速打印、模板设计与打印、Gmail 订单同步、邮件字段抓取、TMDB 片长查询。

详细改动记在 [CHANGELOG.md](CHANGELOG.md)。

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

调试构建：

```bash
./scripts/build-debug-app.sh
open dist/ReceiptPrinter.app
```

运行单元测试：

```bash
swift test
```

## 打印机配置

1. 连接 USB 热敏打印机
2. **系统设置 → 打印机与扫描仪 → 添加打印机**，驱动选 **Generic**
3. 在应用 **设置** 中选择对应 CUPS 打印机名称

## Gmail 配置

1. [Google Cloud Console](https://console.cloud.google.com/) 创建项目
2. **API 和服务 → 库 → 搜索「Gmail API」→ 启用**
3. 配置 OAuth 同意屏幕，**测试用户** 添加你的 Gmail
4. 创建 OAuth 客户端 ID → 类型选 **「桌面应用」**
5. 在应用 **设置** 填入 Client ID / Secret（Redirect URI 默认 `http://127.0.0.1:8765/`）
6. **Gmail** 页面连接账号；可配置时间筛选（近 7 天 / 3 个月等）并 **应用筛选并同步**
7. 在 **影院规则** 配置发件人/主题与模板（自动订单同步）

## TMDB 片长（电影票）

1. 在 [themoviedb.org](https://www.themoviedb.org/settings/api) 申请 API Key
2. **设置 → TMDB** 填入 Key
3. **模板打印** 或电影票编辑器中使用 **匹配片长 (TMDB)**

## 功能

| 模块 | 说明 |
|------|------|
| 快速打印 | 富文本编辑器（右侧格式工具 + 走纸/切纸）；预览用位图，打印走 GBK 文本；草稿本地保存 |
| Excel表格序列打印 | 导入 CSV/XLSX；可拖动列占位框 / Logo；背景图（文字下）；每行位图打印并切纸；可存模板 |
| 打印诊断 | 每次打印后台记录作业与载荷，可标记结果并对比两次作业 |
| 模板打印 | 选模板 → 填字段 → 实时预览 → 打印；电影票支持广告时长与结束时间推算 |
| 模板管理 / 设计 | 块式模板；设计器支持分类、JSON 导入导出、自由定位叠加层 |
| 邮件抓取规则 | 从 Gmail 正文按锚点/正则提取字段，占位符 `{{gmail.fieldId}}` |
| 订单收件箱 | 影院规则自动同步；状态栏固定顶部 |
| Gmail | 时间筛选、发件人/主题过滤，合并进实际搜索 `q` |
| 设置 | 纸宽/编码、默认广告时长、OAuth、TMDB Key |

照片识别（OCR）代码仍保留在仓库中，侧边栏入口已移除。

## 打印路径

- **快速打印**：布局与预览共用 `layoutLines`；物理打印发送 **GBK + FS &** 原生 ESC/POS 文本（本机 POS-80 实测可用）。
- **模板 / 电影票等**：仍可能走位图或文本路径，视渲染器而定；统一经 CUPS `lp -o raw` 提交。
- 每次打印由 `PrintController` 串行传输，诊断记录保存在 Application Support。

## 拍摄小票照片建议（OCR 备用）

- 正面平拍，避免倾斜
- 光线充足，避免阴影
- 尽量填满画面，减少背景

## 版本管理（简明）

项目里只有一个版本文件需要关心：

**`VERSION`**（两行）

1. 第 1 行：对外版本号（如 `1.1.0`）
2. 第 2 行：构建号（如 `4`）

发版：

```bash
./scripts/release.sh minor "这次改了什么"
# 或 patch / major / build
```

脚本会更新 `VERSION`、打包 `dist/ReceiptPrinter.app`、提交并打标签 `v*`。推送到 GitHub：

```bash
git push origin main
git push origin v1.1.0
```
