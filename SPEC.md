# Catchline — 实时双语字幕 App 需求与实现规格（给 Claude Code）

> 把本文件放在项目根目录（可改名为 `CLAUDE.md` 或在 `CLAUDE.md` 里引用它）。开发环境：Mac Mini。

## 0. 产品命名

| 项目 | 内容 |
|---|---|
| 产品名 | **Catchline** |
| Slogan | **Catch every word.** |
| App Store 名称 | **Catchline: Live Call Captions**（≤ 30 字符） |
| 中文名（备选，中文区使用） | 跟得上 |
| 代码中的项目名 / 包名 | `catchline`（CDK stack、S3 桶前缀、Cognito 池名、PWA 名称统一用它） |

命名约束：
- 名称中不出现 "Soniox"（第三方商标，且未来可能更换或接入多家语音 API）。
- 域名：`catchline.com` 不可用；使用自有域名的子域名（如 `catchline.<我的域名>`），或日后注册 `getcatchline.com` / `catchlineapp.com` 等。
- 上线前待办：USPTO 商标检索（Class 9、Class 42）；在 App Store Connect 预留名称。

### 产品路线
- **阶段 A（当前）**：Web / PWA，只给我自己用，同时作为 AWS 练手项目。
- **阶段 B**：iOS 原生 App 上架 App Store，面向所有在英语环境中生活工作、听力跟不上的非母语者。
- 因此从第一天起，**后端按多用户设计**：临时 key 服务、Cognito 用户体系、按用户 `sub` 记录用量，都要能直接复用给 iOS App；不要写只适用于单用户的捷径。语言对不要写死为英→中，做成可配置（源语言 / 目标语言）。

## 1. 目标

做一个只给我自己用的网页应用（PWA），在手机 / iPad / Mac 上打开后：

- 通过麦克风采集英文语音，实时显示 **英文转写**，同时显示 **中文翻译**；
- 主要场景：打电话时主手机开外放，用另一台设备（iPad 或旧 iPhone）打开本页面"旁听"；在 Mac 上开会时也可直接使用；
- 语音识别和翻译全部使用 **Soniox 实时 API**（我已有 Soniox 账号和长期 API key）；
- 后端用 **AWS Serverless**，要求做得规范：IaC、最小权限、可观测。

## 2. 总体架构

```
浏览器 (PWA)
  │  1. 登录 (Cognito Managed Login, OAuth2 Authorization Code + PKCE)
  │  2. POST /api/temporary-api-key  (带 Cognito JWT)
  ▼
CloudFront (自定义子域名, HTTPS)
  ├── 默认行为 → S3 私有桶 (静态前端, OAC)
  └── /api/*  → API Gateway HTTP API (JWT authorizer = Cognito)
                    └── Lambda: 用长期 key 向 Soniox 换取临时 key
                          └── 读取 SSM Parameter Store (SecureString)
  │
  │  3. 浏览器拿临时 key，直接连 Soniox WebSocket 推音频、收结果
  ▼
Soniox Real-time STT + Translation (WebSocket)
```

关键原则：

- **音频流不经过我们的后端**，浏览器直连 Soniox，延迟最低。
- **长期 Soniox key 永远不出现在前端**，只存在 SSM，Lambda 读取。
- 前端与 API 同源（都走同一个 CloudFront 域名），**不需要 CORS**。

## 3. AWS 资源清单

| 资源 | 用途 | 要点 |
|---|---|---|
| S3 Bucket | 存放前端静态文件 | 私有、Block Public Access 全开，只允许 CloudFront 通过 OAC 访问 |
| CloudFront Distribution | 统一入口 | 两个 origin：S3（默认）与 API Gateway（`/api/*`）；`/api/*` 禁用缓存，转发 `Authorization` 头；SPA 回退到 `index.html` |
| ACM Certificate | HTTPS 证书 | **必须在 us-east-1** 申请（CloudFront 要求）；DNS 验证 |
| API Gateway HTTP API | 签发临时 key 的接口 | JWT authorizer 指向 Cognito User Pool；路由 `POST /api/temporary-api-key` |
| Lambda | 换取临时 key | Node.js 最新 LTS runtime；冷启动时读取 SSM 并缓存在内存；超时 10s |
| SSM Parameter Store | 存长期 Soniox key | SecureString（标准参数免费，不用 Secrets Manager 以省钱）；**key 由我手动用 AWS CLI 写入，不进代码、不进 CDK** |
| Cognito User Pool + App Client | 登录 | 阶段 A 关闭自助注册（只有我一个用户，管理员创建）；阶段 B 再开放注册，配置做成开关；使用 Managed Login / Hosted UI；Authorization Code + PKCE；可选阶段二接入 Google 登录 |
| IAM Role (Lambda) | 执行角色 | 最小权限：只允许 `ssm:GetParameter` 读取那一个参数 + 对应 KMS decrypt；以及写 CloudWatch Logs |
| CloudWatch | 日志与告警 | Lambda 日志保留 30 天；告警：Lambda 错误数、调用次数异常（比如 1 小时 > 50 次）发邮件（SNS） |
| AWS Budgets | 成本告警 | 月预算 $5，超过 80% 发邮件 |
| DNS | 子域名 | 例如 `caption.<我的域名>`。域名不迁到 Route 53 也可以：在原注册商加 CNAME 指向 CloudFront（省 $0.50/月）。做成 CDK 参数可选 |

## 4. 基础设施代码（IaC）

- 使用 **AWS CDK，TypeScript**。
- 建议拆分：
  - `CertStack`（us-east-1）：ACM 证书；
  - `AppStack`（我的主区域，如 us-east-1 也可以合并）：其余全部资源。
- 用 `BucketDeployment` 在 `cdk deploy` 时上传前端构建产物，并自动 invalidate CloudFront 缓存。
- 所有可变项做成 context / 参数：域名、子域名、Soniox SSM 参数名、告警邮箱、预算金额。
- 提供 `npm run deploy` 一条命令完成：构建前端 → `cdk deploy`。
- 提供 `npm run destroy` 可以完整删除（S3 桶设置 autoDeleteObjects，仅限本项目）。
- 部署后输出：站点 URL、Cognito 登录地址、API 地址。

## 5. Lambda：签发临时 key

- 输入：无请求体（身份来自 JWT）。
- 逻辑：
  1. 从 SSM 读取长期 key（冷启动读一次，缓存）；
  2. 调用 Soniox 创建临时 key 的 REST 接口（`POST https://api.soniox.com/v1/auth/temporary-api-key`）；
  3. 参数要求：`usage_type` 设为实时语音转写 WebSocket 对应的值；短有效期（几分钟内必须用来开流）；`single_use: true`；`max_session_duration_seconds` 设为 2 小时左右；`client_reference_id` 填 Cognito 用户的 `sub`；
  4. 返回 `{ apiKey, expiresAt }`。
- 错误时返回明确的 4xx/5xx JSON，并记录结构化日志（不要把任何 key 打到日志里）。
- **字段名、取值以 Soniox 官方文档为准，实现前先查文档**：
  - Temporary API keys 指南：https://soniox.com/docs/guides/temporary-api-keys
  - 浏览器直连实时流：https://soniox.com/docs/stt/guides/direct-stream
  - API 参考：https://soniox.com/docs/stt/api-reference

## 6. 前端

### 技术选型
- Vite + TypeScript，框架用轻量的即可（React 或原生都行，倾向简单）。
- 优先使用 **Soniox 官方 Web SDK**（`@soniox/client`），它支持传入一个异步函数从后端取临时 key；若 SDK 不适合，再直接用 WebSocket 实现。
- 登录用 Cognito 的 OAuth 流程（可用 `oidc-client-ts` 或 AWS Amplify Auth，选轻量的），token 存内存 + 刷新逻辑。

### 功能（第一阶段）
1. **开始 / 停止** 按钮。开始时：取临时 key → 申请麦克风 → 连 Soniox → 显示结果。
2. **Soniox 会话配置**：源语言英文，开启单向翻译 英文 → 简体中文；使用当前推荐的实时模型（以文档为准，不要写死旧模型名）；开启 endpoint detection。
3. **字幕显示**：
   - 每一段：上面英文（大字），下面中文（稍小）；
   - 区分 final（已确定）与 non-final（临时）token，临时部分用浅色显示，确定后变正常色；
   - 自动滚动到最新，用户手动上滑时暂停自动滚动，出现"回到最新"按钮。
4. **Context 提示输入框**：开始前可填写人名、公司名、术语，作为 Soniox 的 context 传入，提高识别准确率。
5. **屏幕常亮**：使用 Screen Wake Lock API，避免旁听时设备锁屏。
6. **会话时长与断线处理**：显示已用时长；WebSocket 断开或达到 session 上限时，自动重新取临时 key 并重连，字幕不丢。
7. **导出转写**：停止后可一键下载本次通话的双语文本（`.txt` 或 `.md`，带时间戳），方便事后复习生词。
8. **PWA**：manifest + 图标，可"添加到主屏幕"，全屏运行。
9. **移动端优先的排版**：iPad 横竖屏、iPhone 都清晰可读；深色模式。
10. 字号可调（A- / A+），偏好存 localStorage。

### iOS Safari 注意事项
- 麦克风权限必须由用户点击触发；
- 页面进入后台时音频采集可能被暂停，回到前台要能检测并恢复；
- 测试设备：iPad Safari、iPhone Safari、Mac Chrome / Safari。

### 第二阶段（可选，先不做）
- Cognito 接入 Google 登录；
- 转写自动保存到 S3（按用户 sub 分目录），并做一个历史记录页面；
- 说话人区分（speaker diarization）显示；
- 一键把选中的英文单词加入生词本。

## 7. 本地开发

- Mac Mini 环境：Node.js LTS、AWS CLI v2（已配置 profile）、AWS CDK CLI。
- 首次：`cdk bootstrap`（主区域和 us-east-1 都要）。
- 本地开发模式：`npm run dev` 启动 Vite；提供一个本地 mock 接口 `/api/temporary-api-key`（读取本地 `.env` 里的 Soniox key，**`.env` 必须在 `.gitignore` 中**），这样不部署也能调试前端。
- 写入 Soniox key 到 SSM 的命令写进 README（SecureString 类型），由我手动执行一次。

## 8. 验收标准

- [ ] 未登录访问站点 → 跳转 Cognito 登录；未带 token 调 `/api/temporary-api-key` → 401。
- [ ] 登录后点"开始"，对着 iPad 说英文，2 秒内出现英文字幕和中文翻译。
- [ ] 浏览器开发者工具里看不到长期 Soniox key（只出现 `temp:` 开头的临时 key 或等价物）。
- [ ] S3 桶无法被公网直接访问。
- [ ] Lambda 角色权限只包含必要的 SSM / KMS / Logs 权限。
- [ ] 连续使用 30 分钟以上不断流；断网恢复后自动重连。
- [ ] 能导出本次会话的双语文本。
- [ ] `npm run deploy` 一条命令完成部署；`npm run destroy` 能干净删除。
- [ ] 预算告警与 Lambda 错误告警已配置。

## 9. 给 Claude Code 的工作方式要求

- 先读 Soniox 官方文档再写集成代码，**不要凭记忆编造字段名或模型名**。
- 按阶段推进：① CDK 骨架 + 静态站点上线 → ② Cognito 登录 → ③ Lambda 临时 key → ④ 前端实时字幕 → ⑤ PWA 与体验优化 → ⑥ 告警与预算。每个阶段完成后停下来让我验证。
- README 里写清楚：架构图、部署步骤、成本说明、各个设计取舍的理由。
- 不要把任何密钥写进代码仓库。

## 10. 成本预期

- Soniox：按实际使用时长计费（主要成本）。
- AWS：Lambda / API Gateway / CloudFront / Cognito / SSM 标准参数在个人用量下接近 $0；Route 53 托管区如果使用约 $0.50/月；不使用 Secrets Manager（约 $0.40/secret/月）。
