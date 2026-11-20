# 更新日志

## v1.0.0

首个版本。

### 反代
- OpenAI `/v1/chat/completions`（SSE 流式 + 非流式聚合）
- OpenAI `/v1/models`
- Anthropic `/v1/messages`（含 thinking / tool_use / tool_result 双向翻译）
- Responses `/v1/responses`
- 多账号轮转（按剩余积分排序）、401 自动刷新重试、429/5xx 退避
- 账号级稳定设备指纹（X-Machine-ID / X-Session-ID 由 uid 派生）

### 任务
- 签到（活动状态预检 + 幂等）
- 今日活跃上报、六连桌面事件链
- 补签卡自动补昨日
- 新手礼包 / 活动补偿
- 成长任务：批量接受 → 小程序埋点推进度 → 回读 → 领奖
- 连登档位兑换 → 抽奖
- 猫猫旅行：领养 / 派出 / 到站领奖
- 活动页任务：埋点 → viewed → claim（星巴克 / 记者节）

### 提示词
- 4 种模式：不处理 / 追加 / 前置 / 整替
- 上游拦截标记规避（Claude Code / Codex CLI / DeepSeek Harness），只改被拦那一句
- 3 组预设

### 界面
- 首页：反代开关、Base URL、API Key、账号积分、模型选择、快捷操作、日志
- 任务：一键全流程、夜猫子、仅签到、结果清单
- 提示词：编辑器 + 模式 + 预设
- 账号：扫码登录、AT/RT 导入、编辑、删除、单账号刷新/签到
- 设置：端口、Key、默认模型、重试、协议开关、定时任务、后台保活、上游地址、关于

作者：小帅　QQ：57844458
