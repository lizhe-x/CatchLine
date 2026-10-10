import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Duration, RemovalPolicy, Stack } from 'aws-cdk-lib'
import { HttpApi, HttpMethod, HttpStage } from 'aws-cdk-lib/aws-apigatewayv2'
import { HttpJwtAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers'
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations'
import { AttributeType, BillingMode, Table } from 'aws-cdk-lib/aws-dynamodb'
import { Effect, PolicyStatement, Role, ServicePrincipal } from 'aws-cdk-lib/aws-iam'
import { Architecture, Runtime } from 'aws-cdk-lib/aws-lambda'
import { NodejsFunction, OutputFormat } from 'aws-cdk-lib/aws-lambda-nodejs'
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs'
import { Construct } from 'constructs'

const here = path.dirname(fileURLToPath(import.meta.url))
const backendSrc = (file: string) => path.join(here, '../../backend/src', file)

export interface AppStoreProps {
  teamId: string
  bundleId: string
  productIds: string[]
  /** Numeric App Store ID; required before Production transactions are accepted. */
  appAppleId?: string
  /** Accept App Attest keys from development-signed builds (TestFlight/App Store use production). */
  allowDevelopmentAttestation: boolean
  freeDailySeconds: number
  trialSeconds: number
  paidMonthlySeconds: number
}

export interface ApiProps {
  /** SSM SecureString holding the long-lived Soniox key (written by hand). */
  sonioxKeyParameterName: string
  jwtIssuer: string
  /** Cognito app client IDs allowed to call the web route. */
  jwtAudience: string[]
  appStore: AppStoreProps
}

/**
 * HTTP API behind CloudFront at /api/*:
 * - Web: POST /api/temporary-api-key, Cognito JWT required.
 * - iOS: /api/attest/* and /api/session*, App Attest verified in Lambda,
 *   usage metered in DynamoDB.
 */
export class Api extends Construct {
  readonly httpApi: HttpApi
  readonly fn: NodejsFunction
  readonly appFn: NodejsFunction
  readonly table: Table

  constructor(scope: Construct, id: string, props: ApiProps) {
    super(scope, id)
    const { region, account } = Stack.of(this)
    const parameterArn = `arn:aws:ssm:${region}:${account}:parameter/${props.sonioxKeyParameterName.replace(/^\//, '')}`

    this.table = new Table(this, 'AppTable', {
      partitionKey: { name: 'PK', type: AttributeType.STRING },
      sortKey: { name: 'SK', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl',
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      // Holds paid users' usage: keep it if the stack is ever torn down.
      removalPolicy: RemovalPolicy.RETAIN,
    })

    this.fn = this.lambda('TemporaryKey', {
      entry: backendSrc('handler.ts'),
      description: 'web: Cognito user -> Soniox temporary key',
      parameterArn,
      environment: { SONIOX_KEY_PARAMETER: props.sonioxKeyParameterName },
    })

    const s = props.appStore
    this.appFn = this.lambda('AppApi', {
      entry: backendSrc('appHandler.ts'),
      description: 'iOS: App Attest + StoreKit entitlement -> metered Soniox key',
      parameterArn,
      environment: {
        SONIOX_KEY_PARAMETER: props.sonioxKeyParameterName,
        TABLE_NAME: this.table.tableName,
        TEAM_ID: s.teamId,
        BUNDLE_ID: s.bundleId,
        PRODUCT_IDS: s.productIds.join(','),
        APP_APPLE_ID: s.appAppleId ?? '',
        ALLOW_DEV_ATTEST: String(s.allowDevelopmentAttestation),
        FREE_DAILY_SECONDS: String(s.freeDailySeconds),
        TRIAL_SECONDS: String(s.trialSeconds),
        PAID_MONTHLY_SECONDS: String(s.paidMonthlySeconds),
      },
    })
    // Item-level CRUD on this one table only (no Scan, no table admin).
    this.appFn.addToRolePolicy(
      new PolicyStatement({
        actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:UpdateItem', 'dynamodb:DeleteItem'],
        resources: [this.table.tableArn],
      }),
    )

    this.httpApi = new HttpApi(this, 'HttpApi', {
      apiName: 'catchline',
      description: 'catchline API (reached via CloudFront at /api/*)',
      createDefaultStage: false,
    })
    // Explicit stage so we can cap request rate: these routes spend money upstream.
    new HttpStage(this, 'DefaultStage', {
      httpApi: this.httpApi,
      stageName: '$default',
      autoDeploy: true,
      throttle: { rateLimit: 20, burstLimit: 40 },
    })

    this.httpApi.addRoutes({
      path: '/api/temporary-api-key',
      methods: [HttpMethod.POST],
      integration: new HttpLambdaIntegration('TemporaryKeyIntegration', this.fn),
      authorizer: new HttpJwtAuthorizer('CognitoAuthorizer', props.jwtIssuer, { jwtAudience: props.jwtAudience }),
    })

    const appIntegration = new HttpLambdaIntegration('AppApiIntegration', this.appFn)
    for (const routePath of ['/api/attest/challenge', '/api/attest/register', '/api/session', '/api/session/status', '/api/session/end']) {
      this.httpApi.addRoutes({ path: routePath, methods: [HttpMethod.POST], integration: appIntegration })
    }
  }

  /** Hostname for the CloudFront origin. */
  get originDomain(): string {
    return `${this.httpApi.apiId}.execute-api.${Stack.of(this).region}.amazonaws.com`
  }

  /**
   * Node 24 / arm64 function with a hand-written role instead of
   * AWSLambdaBasicExecutionRole (which may write to *any* log group):
   * its own log group, the one SSM parameter, and SSM-mediated decrypt.
   */
  private lambda(
    name: string,
    opts: { entry: string; description: string; parameterArn: string; environment: Record<string, string> },
  ): NodejsFunction {
    const { region, account } = Stack.of(this)
    const logGroup = new LogGroup(this, `${name}Logs`, {
      retention: RetentionDays.ONE_MONTH,
      removalPolicy: RemovalPolicy.DESTROY,
    })
    const role = new Role(this, `${name}Role`, {
      assumedBy: new ServicePrincipal('lambda.amazonaws.com'),
      description: `catchline ${name}: ${opts.description}`,
    })
    role.addToPolicy(
      new PolicyStatement({ actions: ['logs:CreateLogStream', 'logs:PutLogEvents'], resources: [logGroup.logGroupArn] }),
    )
    role.addToPolicy(new PolicyStatement({ actions: ['ssm:GetParameter'], resources: [opts.parameterArn] }))
    // SecureString uses the AWS-managed aws/ssm key. Allow decrypt only when
    // the call comes through SSM, so the role can't decrypt anything directly.
    role.addToPolicy(
      new PolicyStatement({
        effect: Effect.ALLOW,
        actions: ['kms:Decrypt'],
        resources: [`arn:aws:kms:${region}:${account}:key/*`],
        conditions: { StringEquals: { 'kms:ViaService': `ssm.${region}.amazonaws.com` } },
      }),
    )

    return new NodejsFunction(this, `${name}Function`, {
      entry: opts.entry,
      handler: 'handler',
      description: opts.description,
      runtime: Runtime.NODEJS_24_X,
      architecture: Architecture.ARM_64,
      memorySize: 256,
      timeout: Duration.seconds(10),
      role,
      logGroup,
      environment: opts.environment,
      bundling: {
        format: OutputFormat.ESM,
        minify: true,
        sourceMap: true,
        target: 'node24',
        // The Node 24 runtime ships AWS SDK v3; don't bundle it.
        externalModules: ['@aws-sdk/*'],
        // Some bundled deps (Apple's library) still call require() for Node built-ins.
        banner: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);",
      },
    })
  }
}
