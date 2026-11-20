# WB Hub · WorkBuddy 本地反代 + 任务中心（iOS 自签 / 巨魔 IPA）

一个 iOS 原生 App：**把 WorkBuddy 订阅变成本机 OpenAI 兼容反代**，同时内置**一键跑完签到 / 成长任务 / 活动 / 抽奖 / 猫猫旅行 / 补签**，并支持**出站替换客户端系统提示词**。

作者：**小帅**  ·  QQ：**57844458**

---

## 一、它能干什么

| 能力 | 说明 |
| --- | --- |
| OpenAI 兼容反代 | `POST /v1/chat/completions`、`GET /v1/models`，SSE 流式 |
| Anthropic 兼容 | `POST /v1/messages`，含 thinking / tool_use 双向翻译 |
| Responses 兼容 | `POST /v1/responses` |
| 多账号池 | 国内版 / 国际版混池，按剩余积分排序轮转，401 自动刷新重试 |
| 一键任务 | 签到 → 活跃上报 → 桌面事件链 → 补签 → 礼包补偿 → 成长任务接受/领奖 → 连登兑换 → 抽奖 → 猫猫旅行 → 活动页任务 |
| 提示词改写 | 4 种模式（不处理 / 追加 / 前置 / 整体替换），出站生效 |
| 上游标记规避 | 只改写被拦的自报家门前缀（Claude Code / Codex CLI / Harness），其余原样透传 |
| 扫码登录 | 设备授权流，浏览器完成登录后自动轮询拿 token，不需要桌面端 |
| 凭证永续 | 过期前自动 refresh，RT 轮换后原子写回 |
| iOS 适配 | 端口可改、API Key 可改、后台保活、局域网可访问 |

---

## 二、跑起来（3 步）

### 1. 出 IPA

本仓库已经是不签名 `.app` 的完整工程，任选一种：

**A. GitHub Actions（最快，无需 Mac）**

```bash
git init && git add . && git commit -m "init"
git remote add origin https://github.com/<你的账号>/WBHub.git
git push -u origin main
```

推上去后 Actions 会自动跑 `Build unsigned IPA`，在 Artifacts 里下载 `WBHub-unsigned-ipa`。

**B. 本机 Mac**

```bash
chmod +x build.sh
./build.sh            # 产物：./WBHub.ipa
```

**C. 已有 Xcode**

```bash
open WBHub.xcodeproj
# 真机运行：Signing & Capabilities 里选自己的 Team 即可
# 出包：Product > Archive > Export
```

### 2. 装到 iPhone

| 方式 | 做法 |
| --- | --- |
| **巨魔 TrollStore** | 直接把 `WBHub.ipa` 拖进 TrollStore 安装，无需签名，权限最全 |
| **自签 Sideloadly** | 拖入 ipa，填 Apple ID，Start；7 天需重签 |
| **自签 AltStore / Esign** | 同上，装好 ipa 后在描述文件里信任 |
| **企业签 / 个人证书** | 解包后 `codesign -f -s "证书名" --entitlements WBHub/WBHub.entitlements Payload/WBHub.app` 再 zip |

Bundle ID：`com.xiaoshuai.wbhub`（与官方 App 不冲突）

### 3. 加账号

1. 打开 App → 「账号」→「登录新账号（扫码）」
2. 选国内版 / 国际版 → 自动跳浏览器登录
3. 登录完成后回到 App，自动收 token，昵称和积分会同步

也可以「粘贴 AT / RT 导入」，格式：`手机号:AT:RT`（每行一个）。

---

## 三、接客户端

首页会显示：

```
Base URL: http://127.0.0.1:8788/v1
API Key : sk-xxxxxxxx
```

任何 OpenAI 兼容客户端（Cherry Studio / NextChat / LobeChat / OpenCode / DSH / OpenAI SDK）填这两个值即可。

iOS 上其他 App 访问 `127.0.0.1` 是不通的（沙盒隔离）。要跨 App 用，把地址换成手机局域网 IP：

```
http://192.168.x.x:8788/v1
```

首次启动会请求本地网络权限，允许即可。

Anthropic 客户端：

```
Base URL: http://127.0.0.1:8788
API Key : 同上
```

---

## 四、提示词 / 破甲

「提示词」页：

- **追加到末尾**（默认）：保留客户端原本的 system prompt，把你的规则接在后面 —— 最稳，不破坏工具调用
- **插入到开头**：你的规则获得最高优先级
- **整体替换**：完全接管 system prompt
- **规避上游客户端标记**：默认开启。上游网关会拦 `You are Claude Code, Anthropic's official CLI tool for Claude.`、Codex CLI 开头段、`You are an AI agent powered by DeepSeek Harness.` 这类自报家门的文本。开启后只改这几个标记，其余内容一字不改

预设里带一份「执行引擎」提示词，点一下即可套用。

---

## 五、任务

「任务」页点「立即执行全部任务」，会按顺序跑：

1. 查签到活动状态 → 未签则签
2. 上报今日活跃（点亮热力墙）
3. 六连桌面事件链（点亮桌面端对话）
4. 检查昨日缺卡 → 用补签卡
5. 新手礼包 + 活动补偿
6. 拉任务列表 → 批量接受 → 上报任务埋点（对话 / 专家 / 灵感）→ 回读 → 领奖
7. 连登档位兑换 → 抽奖
8. 猫猫旅行（领养 / 派出 / 到站领奖）
9. 活动页任务（星巴克 / 记者节）：埋点 → viewed → claim

每一步都幂等，重复跑只补缺口。所有请求带账号级稳定设备指纹（`X-Machine-ID` 由 uid 派生），不会多账号串号。

「设置」里可以开自动执行：每天指定时间自动跑，23:05 单独跑夜猫子窗口。

---

## 六、目录结构

```
WBHub/
├── WBHub.xcodeproj/          # Xcode 工程（已含 shared scheme）
├── WBHub/                    # 源码
│   ├── WBHubApp.swift        # 入口 + 定时器
│   ├── RootView.swift        # 五个 Tab
│   ├── HomeView.swift        # 首页：反代状态 / 统计 / 快捷操作 / 日志
│   ├── TasksView.swift       # 一键任务
│   ├── PromptView.swift      # 提示词编辑
│   ├── AccountsView.swift    # 账号池
│   ├── LoginView.swift       # 扫码登录
│   ├── SettingsView.swift    # 设置（底部含作者信息）
│   ├── Models.swift          # 数据模型 + 容错解码
│   ├── Store.swift           # 持久化
│   ├── Wire.swift            # 上游线协议（头/信封/请求体整形）
│   ├── Networking.swift      # HTTP + SSE
│   ├── Upstream.swift        # 登录/刷新/模型/积分
│   ├── Tasks.swift           # 任务引擎
│   ├── PromptEngine.swift    # 提示词改写 + 三方言互转
│   ├── HttpServer.swift      # NWListener HTTP/1.1 服务
│   ├── ServerManager.swift   # 反代路由
│   ├── Theme.swift           # 设计系统
│   └── Presets.swift         # 提示词预设
├── build.sh                  # 一键出 ipa
└── .github/workflows/build.yml
```

---

## 七、参考的开源项目

- `HanawaBanana/workbuddy2api` — 上游头族、信封、SSE 聚合、prompt_cache_key、effort 降级
- `xc3qaq/WorkBuddy-Hub-Android` — 成长中心端点、旅行/连登/抽奖状态机、三方言翻译、拦截标记规避
- `L0NE-6/WorkBuddy-Daily` — 任务清单、小程序埋点指纹、活动页 portal 契约、领奖回读
- `88lin/workbuddy-auto-signin` — 补签与连登判据
- `Tom6814/WorkBuddy2API` — 思考内容透传、reasoning_effort 档位
- `uernamezzj/WorkBuddy-Prompt-Patcher` — 提示词模块划分与注入位置
- `caigee-cmd/cli2api` — 本机网关形态与多账号路由

---

## 八、说明

- 所有凭证只存本机 App 沙盒内，不上传任何服务器。
- 反代只监听本机，局域网访问是可选能力（系统会弹权限确认）。
- 上游接口随时可能变；日志页能看到每一次请求的状态码与业务码，出问题先看日志。
