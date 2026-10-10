import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Duration, RemovalPolicy, Stack } from 'aws-cdk-lib'
import { HttpApi, HttpMethod, HttpStage } from 'aws-cdk-lib/aws-apigatewayv2'
import { HttpJwtAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers'
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations'
import { Effect, PolicyStatement, Role, ServicePrincipal } from 'aws-cdk-lib/aws-iam'
import { Architecture, Runtime } from 'aws-cdk-lib/aws-lambda'
import { NodejsFunction, OutputFormat } from 'aws-cdk-lib/aws-lambda-nodejs'
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs'
import { Construct } from 'constructs'

const here = path.dirname(fileURLToPath(import.meta.url))

export interface ApiProps {
  /** SSM SecureString holding the long-lived Soniox key (written by hand). */
  sonioxKeyParameterName: string
  jwtIssuer: string
  /** Cognito app client IDs allowed to call the API. */
  jwtAudience: string[]
}

/**
 * HTTP API with one JWT-protected route that trades the caller's Cognito
 * identity for a short-lived, single-use Soniox key.
 */
export class Api extends Construct {
  readonly httpApi: HttpApi
  readonly fn: NodejsFunction

  constructor(scope: Construct, id: string, props: ApiProps) {
    super(scope, id)
    const { region, account } = Stack.of(this)

    const logGroup = new LogGroup(this, 'TemporaryKeyLogs', {
      retention: RetentionDays.ONE_MONTH,
      removalPolicy: RemovalPolicy.DESTROY,
    })

    // Hand-written role instead of the default AWSLambdaBasicExecutionRole,
    // which may write to *any* log group. This one can do exactly three things.
    const role = new Role(this, 'TemporaryKeyRole', {
      assumedBy: new ServicePrincipal('lambda.amazonaws.com'),
      description: 'catchline temporary-key Lambda: read one SSM parameter, write its own logs',
    })
    role.addToPolicy(
      new PolicyStatement({
        actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
        resources: [logGroup.logGroupArn],
      }),
    )
    const parameterArn = `arn:aws:ssm:${region}:${account}:parameter/${props.sonioxKeyParameterName.replace(/^\//, '')}`
    role.addToPolicy(new PolicyStatement({ actions: ['ssm:GetParameter'], resources: [parameterArn] }))
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

    this.fn = new NodejsFunction(this, 'TemporaryKeyFunction', {
      entry: path.join(here, '../../backend/src/handler.ts'),
      handler: 'handler',
      runtime: Runtime.NODEJS_24_X,
      architecture: Architecture.ARM_64,
      memorySize: 256,
      timeout: Duration.seconds(10),
      role,
      logGroup,
      environment: { SONIOX_KEY_PARAMETER: props.sonioxKeyParameterName },
      bundling: {
        format: OutputFormat.ESM,
        minify: true,
        sourceMap: true,
        target: 'node24',
        // The Node 24 runtime ships AWS SDK v3; don't bundle it.
        externalModules: ['@aws-sdk/*'],
      },
    })

    this.httpApi = new HttpApi(this, 'HttpApi', {
      apiName: 'catchline',
      description: 'catchline API (reached via CloudFront at /api/*)',
      createDefaultStage: false,
    })
    // Explicit stage so we can cap request rate: this route spends money upstream.
    new HttpStage(this, 'DefaultStage', {
      httpApi: this.httpApi,
      stageName: '$default',
      autoDeploy: true,
      throttle: { rateLimit: 2, burstLimit: 10 },
    })

    const authorizer = new HttpJwtAuthorizer('CognitoAuthorizer', props.jwtIssuer, {
      jwtAudience: props.jwtAudience,
    })

    this.httpApi.addRoutes({
      path: '/api/temporary-api-key',
      methods: [HttpMethod.POST],
      integration: new HttpLambdaIntegration('TemporaryKeyIntegration', this.fn),
      authorizer,
    })
  }

  /** Hostname for the CloudFront origin. */
  get originDomain(): string {
    return `${this.httpApi.apiId}.execute-api.${Stack.of(this).region}.amazonaws.com`
  }
}
