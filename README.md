# CatchLine

**Catch every word.** Live captions and translation for phone calls, meetings and conversations.

[English](#english) · [中文](#中文)

---

## English

CatchLine listens through the microphone and shows what's being said in real time, with a translation into the user's language underneath. Speech recognition and translation run on [Soniox](https://soniox.com) real-time STT; the backend is AWS serverless.

- **iOS app** (primary): SwiftUI, no account. Free 3 min/day; CatchLine Pro subscriptions via StoreKit 2.
- **Web app / PWA** (secondary): Vite + React, Cognito sign-in.

### Repository layout

```
ios/        SwiftUI app (XcodeGen project), unit tests, UI translations (ios/Localization)
web/        Vite + React PWA, plus static pages: privacy, fair use, support
backend/    Lambda handlers (shared with the local Vite mock) + tests
infra/      AWS CDK: CertStack + AppStack, all in us-east-1
design/     Logo sources
docs/       Test checklist
SPEC.md     Original product spec (Chinese)
```

### Architecture

```
iPhone (no account)                         Browser (PWA)
  │ App Attest key + anonymous user id         │ Cognito Managed Login (OAuth2 code + PKCE)
  │ StoreKit 2 signed transaction (JWS)        │
  ▼                                            ▼
CloudFront  catchline.deskfox.cn  (ACM cert; DNS at Aliyun)
  ├── default → private S3 bucket (OAC): web app, /config.json, legal pages
  └── /api/*  → API Gateway HTTP API (rate-limited)
                 ├── /api/session*, /api/attest/*  → AppApi Lambda
                 │     verify App Attest assertion → verify StoreKit JWS → pick plan
                 │     → meter usage in DynamoDB → mint a lease-capped Soniox key
                 └── /api/temporary-api-key (Cognito JWT) → TemporaryKey Lambda
                 Both Lambdas read the long-lived Soniox key from SSM (SecureString).
  │
  │ short-lived, single-use key; audio streams straight to Soniox (never through our servers)
  ▼
Soniox real-time STT + translation (WebSocket)
```

Monitoring: Lambda error and invocation-spike alarms → SNS email; monthly budget filtered by the `project=catchline` cost tag.

### Plans and metering

| Plan | Allowance |
|---|---|
| Free | 3 minutes per day (resets at the user's local midnight) |
| Trial | 7 days on monthly or yearly, up to 3 hours (one trial per Apple Account) |
| Pro (monthly $9.99 / yearly $59.99) | 40 hours per calendar month, no daily limit |

- Each Soniox key opens one stream capped at a **lease** (≤ 10 minutes and ≤ remaining allowance). The app rotates streams just before the cap, so no words are lost.
- Leases are charged by the **server's clock**, per second, rounded down.
- `com.deskfox.catchline.yearly.now` (no trial, highest level) is offered only when trial hours run out, so the user can start paying immediately.
- All allowances are in `infra/cdk.json` (`catchline:appStore`) and can change without an app release.

### Local development (no AWS needed)

```bash
cp .env.example .env        # set SONIOX_API_KEY (.env is gitignored)
npm install
npm run dev                 # http://localhost:5173
```

The Vite dev server mocks `POST /api/temporary-api-key` and the iOS session API (`/api/session*`, metered in memory) using the same key-minting code as the Lambdas. `npm run dev:lan` serves HTTPS on the LAN so phones can use the microphone.

iOS simulator against the mock (Debug builds only):

```bash
cd ios && xcodegen generate
# launch arguments: -CatchlineLocalMock YES  [-CatchlineAudioFile /path/to.wav] [-CatchlineAutoStart YES]
```

### Tests

```bash
npm test -w backend                                   # App Attest assertion, plans, metering
npm test -w web                                       # caption rows, incl. a recorded mixed-language session
npm run typecheck                                     # backend + infra + web build
cd ios && xcodebuild test -scheme Catchline -destination 'platform=iOS Simulator,name=iPhone 17'
```

Manual device and subscription checks: [docs/TESTING.md](docs/TESTING.md).

### Deploy

Prerequisites: AWS CLI v2 with SSO profile `catchline` (`aws sso login --profile catchline`), CDK bootstrapped in us-east-1.

```bash
# one-time: the long-lived Soniox key goes into SSM, never into code or CDK
aws ssm put-parameter --profile catchline --name /catchline/soniox-api-key \
  --type SecureString --tier Standard --value "<SONIOX_API_KEY>"

npm run deploy     # build the web app → cdk deploy --all
npm run destroy    # remove everything (the DynamoDB usage table is retained)
```

First-deploy manual steps: add the ACM validation CNAME and `catchline → <DistributionDomain>` at the DNS host; confirm the SNS email subscription; activate the `project` cost allocation tag after ~24 h.

### UI translations

UI strings are English in code; 15 languages are generated into `Localizable.xcstrings` from `ios/Localization` (`python3 ios/Localization/gen.py`). The script refuses to write if a language is missing strings or placeholders don't match.

### Design decisions

- **Audio never touches our backend.** The client streams directly to Soniox with a short-lived, single-use key; the long-lived key stays in SSM.
- **No account on iOS.** App Attest proves requests come from the genuine app on a real device; an anonymous id in iCloud Keychain follows the user across reinstalls and devices; StoreKit's signed transactions prove entitlement.
- **Server-side metering with leases.** The stream cap is enforced by Soniox itself (`max_session_duration_seconds`), so a tampered client can't exceed its allowance.
- **Least-privilege Lambda roles**: each can write only its own log group, read one SSM parameter, decrypt via SSM only, and (AppApi) do item-level CRUD on one table. No `AWSLambdaBasicExecutionRole`.
- **SSM instead of Secrets Manager**: standard parameters are free and one key doesn't need managed rotation.
- **Same origin for site and API** behind one CloudFront distribution, so there's no CORS.
- **SPA fallback via a CloudFront Function**, not 403/404 error pages, so API errors are never rewritten into HTML.
- **Certificate in its own stack**: DNS isn't in Route 53, so the first validation is manual; app deploys never wait on it.

---

## 中文

CatchLine 通过麦克风收听语音，实时显示字幕，并在下方显示用户母语的翻译。语音识别和翻译使用 [Soniox](https://soniox.com) 实时接口；后端是 AWS Serverless。

- **iOS App**（主力）：SwiftUI，不需要账号。免费每天 3 分钟；CatchLine Pro 通过 StoreKit 2 订阅。
- **网页版 / PWA**（辅助）：Vite + React，Cognito 登录。

### 目录结构

```
ios/        SwiftUI App（XcodeGen 工程）、单元测试、界面翻译（ios/Localization）
web/        Vite + React PWA，以及静态页面：隐私政策、合理使用政策、支持页
backend/    Lambda 代码（与本地 Vite mock 共用）及测试
infra/      AWS CDK：CertStack + AppStack，全部在 us-east-1
design/     Logo 源文件
docs/       测试清单
SPEC.md     最初的需求规格
```

### 架构

架构图见上方英文部分。要点：
- iPhone 用 **App Attest 设备密钥 + 匿名用户 ID** 证明身份，用 **StoreKit 2 签名交易（JWS）** 证明订阅；网页版用 **Cognito 登录**。
- CloudFront（`catchline.deskfox.cn`）默认指向私有 S3 桶，`/api/*` 指向 API Gateway。
- iOS 接口：校验 App Attest 签名 → 校验订阅凭证 → 判断方案 → 在 DynamoDB 计量 → 签发有时长上限的 Soniox 临时 key。
- 两个 Lambda 都从 SSM（SecureString）读取长期 Soniox key。
- **音频直连 Soniox**，不经过我们的服务器。
- 监控：Lambda 错误和调用量异常告警发邮件（SNS）；月度预算按 `project=catchline` 成本标签过滤。

### 方案与计量

| 方案 | 额度 |
|---|---|
| 免费 | 每天 3 分钟（按用户当地午夜重置） |
| 试用 | 月付或年付均有 7 天试用，最多 3 小时（每个 Apple 账户限一次） |
| Pro（月付 $9.99 / 年付 $59.99） | 每个自然月 40 小时，不限每日 |

- 每个 Soniox key 只能开一条流，时长上限为一个**租约**（不超过 10 分钟，也不超过剩余额度）。App 在到期前主动换流，不丢字。
- 租约按**服务器时钟**计费，按秒、向下取整。
- `com.deskfox.catchline.yearly.now`（无试用、等级最高）只在试用额度用完时出现，让用户立即转正。
- 所有额度在 `infra/cdk.json`（`catchline:appStore`）里配置，修改不需要发新版 App。

### 本地开发（不需要 AWS）

```bash
cp .env.example .env        # 填入 SONIOX_API_KEY（.env 已在 .gitignore）
npm install
npm run dev                 # http://localhost:5173
```

Vite 开发服务器模拟 `POST /api/temporary-api-key` 和 iOS 会话接口（`/api/session*`，在内存中计量），使用和 Lambda 相同的签发代码。`npm run dev:lan` 在局域网提供 HTTPS，手机可以用麦克风调试。

iOS 模拟器连本地 mock（仅 Debug 构建）：`cd ios && xcodegen generate`，启动参数 `-CatchlineLocalMock YES`，可选 `-CatchlineAudioFile /path/to.wav`、`-CatchlineAutoStart YES`。

### 测试

- `npm test -w backend`：App Attest 签名、方案判断、计量
- `npm test -w web`：字幕分行与翻译拼接（含一段真实录制的中英混说会话）
- `npm run typecheck`：后端、infra、网页构建
- iOS：`cd ios && xcodebuild test -scheme Catchline -destination 'platform=iOS Simulator,name=iPhone 17'`
- 真机和订阅的手动测试见 [docs/TESTING.md](docs/TESTING.md)。

### 部署

前置：AWS CLI v2 + SSO profile `catchline`（`aws sso login --profile catchline`），已在 us-east-1 执行 `cdk bootstrap`。

- 一次性：用 `aws ssm put-parameter` 把长期 Soniox key 写入 SSM `/catchline/soniox-api-key`（SecureString），不进代码、不进 CDK。
- `npm run deploy`：构建网页 → `cdk deploy --all`。
- `npm run destroy`：删除全部资源（DynamoDB 用量表会保留）。

首次部署的手动步骤：在 DNS 服务商处添加 ACM 校验 CNAME 和 `catchline → <DistributionDomain>`；确认 SNS 订阅邮件；约 24 小时后激活 `project` 成本分配标签。

### 界面翻译

代码里的界面文字是英文；15 种语言由 `ios/Localization` 生成到 `Localizable.xcstrings`（运行 `python3 ios/Localization/gen.py`）。缺字符串或占位符数量不一致时，脚本会拒绝写入。

### 设计取舍

- **音频不经过后端**：客户端用短期、单次使用的 key 直连 Soniox；长期 key 只在 SSM。
- **iOS 不需要账号**：App Attest 证明请求来自真机上的正版 App；iCloud 钥匙串里的匿名 ID 让重装、换机后用量不丢；StoreKit 签名交易证明订阅。
- **服务器端按租约计量**：流时长上限由 Soniox 自己执行（`max_session_duration_seconds`），篡改客户端也无法超额使用。
- **Lambda 最小权限**：只能写自己的日志组、读一个 SSM 参数、经由 SSM 解密，AppApi 另外只能对一张表做单条读写；不使用 `AWSLambdaBasicExecutionRole`。
- **用 SSM 而不是 Secrets Manager**：标准参数免费，单个 key 不需要自动轮换。
- **网站和 API 同源**：同一个 CloudFront 分发，不需要 CORS。
- **SPA 回退用 CloudFront Function**，而不是 403/404 错误页，避免把 API 错误改写成 HTML。
- **证书单独一个栈**：DNS 不在 Route 53，首次需手动验证；之后应用部署不用等证书。
