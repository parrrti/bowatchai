# bowatch

**Native iOS + watchOS client for watchd — chat with Miyu from your wrist.**

The Apple Watch only had a web shell before: EventSource dies silently,
typing hurts, half the taps are just re-Authenticating. bowatch puts the
whole watchd API behind native SwiftUI instead.

## Features

| Watchd feature | iOS | watchOS |
| --- | :---: | :---: |
| Login / logout (cookie relay) | ✅ | ✅ |
| Streaming replies (2s polling backbone + live tool-call line) | ✅ | ✅ |
| History (last 40 turns, meta lines) | ✅ | ✅ |
| Session list / switch / create / delete | ✅ | ✅ |
| Model picker (51-entry catalog + per-session override) | ✅ | ✅ |
| Context compaction (normal + forced) | ✅ | ✅ |
| Reasoning blocks (on-demand fetch) | ✅ | ✅ |
| Inline reply images (authenticated) | ✅ | ✅ |
| Camera snapshot | ✅ | → |
| Context window usage meter | ✅ | ✅ |

## Architecture

- [`project.yml`](project.yml) — XcodeGen spec, no hand-written pbxproj
- [`Sources/Shared/`](Sources/Shared/) — `APIClient` + `ChatEngine`, one
  logic layer both targets import; only UI shells differ
- [`Sources/iOS/`](Sources/iOS/) / [`Sources/WatchApp/`](Sources/WatchApp/) —
  SwiftUI shells

The server base URL is user-configurable (default: the SakuraFrp nyat.app
tunnel), sessions persist via shared `HTTPCookieStorage`, so one login
survives launches on both devices independently.

## Build

Cloud (unsigned artifacts, no signing needed):

```sh
git push   # .github/workflows/build.yml runs xcodegen + xcodebuild on macos-14
```
Check the *Actions* tab — failures auto-write `errors.md` to the repo root.

Local (Xcode 15+, to install on a device):
```sh
brew install xcodegen && xcodegen generate
open bowatch.xcodeproj
# iOS target → run on iPhone; the watch target appears alongside in the simulator list
# Signing: your Apple ID (Personal Team) in Signing & Capabilities
```

## Server

bowatch talks to **watchd** — a tiny Python relay in front of the Miyu
daemon (`~/.miyu/watch/server.py`). All traffic goes through the relay's
`/watch/*` prefix; the app never touches the daemon directly.

## Status

Actively maintained. Latest: **v0.0.29**.

## Changelog

### v0.0.34
- 版本占位：用于验证「检查更新」弹窗逻辑（装 v0.0.33 会检测到 v0.0.34）

### v0.0.33
- **会话重命名**：列表左滑「重命名」（铅笔），弹窗输入新名字（服务端 watchd 新增 `/api/rename`，走 miyu `PATCH /api/sessions/{sid}`）

### v0.0.32
- 会话列表**长按拖动排序**（本地 UserDefaults 持久化，重启保持）
- **检查更新**：开屏静默检查，有新版弹窗提示（不强制，可"稍后"）；设置 → 关于 → 检查更新
- 修复灵动岛不自动清除：完成改用 `.immediate` 立即收起
- 多行输入框自适应（最多 4 行，`axis: .vertical`），聊天内容靠 safeAreaInset 随输入框高度自动抬高（去掉固定 padding）

### v0.0.31
- 修复通知权限不弹：请求移到 ContentView 就绪后（init 太早被系统吞）+ 回前台补一次（幂等）

### v0.0.30
- **本地通知**：回复完成（带内容前 60 字）/ 压缩完成 / 会话已删都推送
- **灵动岛 Live Activity**：发消息后锁屏+灵动岛实时显示生成正文，完成收起（新增 Widget Extension target）

### v0.0.29
- 生成中状态文案「发送中…」→「思考中…」
- 修复进入会话无法自动滚到底部（LazyVStack 首次布局前 scrollTo 静默失败，
  改为切会话后延时两拍双次滚动 + 消息加载即滚）

### v0.0.28
- 生成态从全局锁改为**每会话独立**：A 会话生成中，B 会话照常可发送
- 单个轮询 Task 改为按 sid 管理的任务字典，各会话各生成、互不阻塞

### v0.0.27
- 生成中（busy）不再触发前台刷新，修复切后台回来消息重复落两份
- 会话列表每行左滑出「压缩 / 删除」，删除带会话名二次确认

### v0.0.26
- 进入会话（含新建、历史加载完）自动定位到最底部
- 压缩 / 删除从设置页移到会话页右上角 ⋯ 菜单

### v0.0.25
- iOS 26 Liquid Glass：玻璃输入条 + 原生玻璃发送/停止键、导航栏透底
- 登录态固化：miyu 会话 cookie 当场转 token 存盘，重启免重登
- 服务器地址输入即存盘；刷新间隔改了真正写回 UserDefaults（此前漏存）
- 补 `confirmCompact` 状态声明；CI 换 macos-26 + Xcode 26

### v0.0.24
- iOS 26 Liquid Glass 适配初版；生成态不串会话

### v0.0.23
- 生成中状态只在发送的那条会话里显示，不再串门
- 删除/压缩对话点下去先弹确认，带会话名

### v0.0.22
- 聊天内容底部恒定垫高 72pt，输入条不再压住最后一条消息

### v0.0.21
- 键盘弹起聊天记录自动跟随上滚；打字期间输入条常驻

### v0.0.20
- 三角键复活：有字=直接发送，空=唤起键盘，生成中=红色停止键
- 聊天气泡重排：用户右侧蓝底、AI 左侧灰底，[图]/[思考] 胶囊化

### v0.0.19
- 单行输入框 Done 键即发送（修多行 return 只换行不发送）
- 回前台自动刷新；底部常驻「双击此处」备用登录入口

> 早期（v0.0.18 及以前）：仓库骨架、watchd 11 端点全集、双端免签 CI、
> 会话列表/设置/账户三页 UI、离线缓存、[图]/[思考] 详情页等奠基工作。

License: none yet — ask before reusing.
