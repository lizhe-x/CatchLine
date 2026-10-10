# Catchline

**Catch every word.** 实时双语字幕：麦克风收音 → Soniox 实时识别 + 翻译 → 浏览器显示。完整需求见 [SPEC.md](SPEC.md)。

## 目录

```
web/       Vite + React 前端（PWA）
backend/   签发 Soniox 临时 key 的逻辑（Lambda 与本地 mock 共用）
infra/     AWS CDK（CertStack + AppStack，全部在 us-east-1）
```

## 本地开发（不需要 AWS）

```bash
cp .env.example .env        # 填入 SONIOX_API_KEY（.env 已在 .gitignore）
npm install
npm run dev                 # http://localhost:5173
```

`npm run dev` 时，Vite 中间件在本机提供 `POST /api/temporary-api-key`，
用 `.env` 里的长期 key 换取一次性临时 key（与线上 Lambda 用同一份代码 `backend/src/soniox.ts`）。
浏览器只会拿到 `snx_temp…` 临时 key。

### 在 iPad / iPhone 上调试

麦克风需要 HTTPS。用局域网 + 自签证书：

```bash
npm run dev:lan -w web      # https://<Mac 的局域网 IP>:5173
```

Safari 会提示证书不受信任，选「访问此网站」即可。

## 设计要点

- **音频不经过后端**：浏览器直连 Soniox WebSocket，延迟最低；后端只签发短期、单次使用的临时 key。
- **字幕分段**：Soniox 先给非 final token（浅色显示），再按句块 final，并紧跟该句块的翻译 token。
  一行 = 一个原文句块 + 它的译文；收到 `<end>`（端点检测）或下一句原文时换行。见 `web/src/transcript.ts`。
- **断线不丢字幕**：字幕状态存在 Soniox 会话之外。SDK 负责网络抖动重连；`web/src/captioner.ts`
  另外处理 SDK 视为致命但其实可恢复的情况（单流时长上限、临时 key 过期、长时间断网、iOS 切后台后麦克风被挂起），
  自动取新 key 重开会话。

## 架构

```
iPhone / 浏览器
  │ 1. Cognito Managed Login（OAuth2 授权码 + PKCE）
  │ 2. POST /api/temporary-api-key（带 access token）
  ▼
CloudFront  catchline.deskfox.cn（ACM 证书，DNS 在阿里云）
  ├── 默认   → S3 私有桶（OAC，静态前端 + /config.json）
  └── /api/* → API Gateway HTTP API（JWT authorizer = Cognito，限流 2 rps）
                 └── Lambda（Node 24, arm64）
                       ├── SSM SecureString /catchline/soniox-api-key（冷启动读一次）
                       └── Soniox REST：换取单次使用、2 分钟内开流的临时 key
  │ 3. 拿临时 key 直连 Soniox WebSocket（音频不经过我们的后端）
  ▼
Soniox Real-time STT + Translation
```

监控：Lambda 错误 ≥1 / 调用 >50 次每小时 → SNS 邮件；月预算按 `project=catchline` 成本标签过滤。

## 部署

前置：AWS CLI v2 + SSO profile `catchline`（`aws sso login --profile catchline`），已 `cdk bootstrap`。

```bash
# 一次性：长期 key 写入 SSM（不进代码、不进 CDK）
aws ssm put-parameter --profile catchline --name /catchline/soniox-api-key \
  --type SecureString --tier Standard --value "<SONIOX_API_KEY>"

npm run deploy     # 构建前端 → cdk deploy --all
npm run destroy    # 删除全部资源（证书校验 CNAME 需手动在阿里云删）
```

可调参数在 `infra/cdk.json` 的 `context`：域名、Cognito 域名前缀、iOS URL scheme、是否开放注册、SSM 参数名、告警邮箱、预算。

首次部署的手动步骤：阿里云 DNS 添加 ACM 校验 CNAME 和 `catchline → <DistributionDomain>`；确认 SNS 订阅邮件；
`aws cognito-idp admin-create-user` 创建用户（阶段 A 关闭自助注册）；24 小时后激活成本标签
`aws ce update-cost-allocation-tags-status --cost-allocation-tags-status TagKey=project,Status=Active`。

## 设计取舍

- **SSM 而不是 Secrets Manager**：标准参数免费，单个 key 不需要自动轮换功能。
- **最小权限 Lambda 角色**：不用 `AWSLambdaBasicExecutionRole`（可写任意日志组），只允许写自己的日志组、读一个参数、经由 SSM 解密。
- **同源**：前端和 API 都走同一个 CloudFront 域名，不需要 CORS；iOS 也用同一个地址。
- **SPA 回退用 CloudFront Function** 而不是 403/404 错误页，避免把 API 的错误改写成 HTML。
- **证书单独一个栈**：DNS 不在 Route 53，首次需手动校验；之后应用栈的部署不再等待证书。
- **运行时配置 `/config.json`** 由 CDK 写入，前端包不随环境重建。
