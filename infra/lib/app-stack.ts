import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { CfnOutput, RemovalPolicy, Stack, type StackProps } from 'aws-cdk-lib'
import type { ICertificate } from 'aws-cdk-lib/aws-certificatemanager'
import {
  AllowedMethods,
  CachePolicy,
  Distribution,
  Function as CloudFrontFunction,
  FunctionCode,
  FunctionEventType,
  HttpVersion,
  OriginProtocolPolicy,
  OriginRequestPolicy,
  PriceClass,
  ResponseHeadersPolicy,
  ViewerProtocolPolicy,
} from 'aws-cdk-lib/aws-cloudfront'
import { HttpOrigin, S3BucketOrigin } from 'aws-cdk-lib/aws-cloudfront-origins'
import { BlockPublicAccess, Bucket, BucketEncryption } from 'aws-cdk-lib/aws-s3'
import { BucketDeployment, CacheControl, Source } from 'aws-cdk-lib/aws-s3-deployment'
import type { Construct } from 'constructs'
import { Api } from './api.ts'
import { Auth } from './auth.ts'
import { Monitoring } from './monitoring.ts'

const here = path.dirname(fileURLToPath(import.meta.url))
const WEB_DIST = path.join(here, '../../web/dist')

export interface AppStackProps extends StackProps {
  domainName: string
  certificate: ICertificate
  cognitoDomainPrefix: string
  iosUrlScheme: string
  selfSignUp: boolean
  sonioxKeyParameterName: string
  alarmEmail: string
  monthlyBudgetUsd: number
  costTag: { key: string; value: string }
}

export class AppStack extends Stack {
  constructor(scope: Construct, id: string, props: AppStackProps) {
    super(scope, id, props)

    // --- Auth: Cognito user pool, Managed Login, web + iOS clients ---
    const auth = new Auth(this, 'Auth', {
      siteDomain: props.domainName,
      cognitoDomainPrefix: props.cognitoDomainPrefix,
      iosUrlScheme: props.iosUrlScheme,
      selfSignUp: props.selfSignUp,
    })

    // --- API: POST /api/temporary-api-key (JWT-protected Lambda) ---
    const api = new Api(this, 'Api', {
      sonioxKeyParameterName: props.sonioxKeyParameterName,
      jwtIssuer: auth.issuerUrl,
      jwtAudience: [auth.webClient.userPoolClientId, auth.iosClient.userPoolClientId],
    })

    // --- Alarms (email via SNS) + monthly budget ---
    new Monitoring(this, 'Monitoring', {
      alarmEmail: props.alarmEmail,
      monthlyBudgetUsd: props.monthlyBudgetUsd,
      temporaryKeyFunction: api.fn,
      costTag: props.costTag,
    })

    // --- Static site: private bucket, readable only by CloudFront (OAC) ---
    const siteBucket = new Bucket(this, 'SiteBucket', {
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      encryption: BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      // Build output only; safe to wipe on `npm run destroy`.
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    })

    // SPA fallback done at the edge for the site behavior only, so /api/*
    // errors are never rewritten into index.html.
    const spaRewrite = new CloudFrontFunction(this, 'SpaRewrite', {
      comment: 'Serve index.html for client-side routes',
      code: FunctionCode.fromInline(`
function handler(event) {
  var request = event.request;
  var last = request.uri.split('/').pop();
  if (last.indexOf('.') === -1) request.uri = '/index.html';
  return request;
}`),
    })

    // One origin for site + API: same-origin requests, so no CORS at all.
    const distribution = new Distribution(this, 'Distribution', {
      comment: 'catchline',
      domainNames: [props.domainName],
      certificate: props.certificate,
      defaultRootObject: 'index.html',
      httpVersion: HttpVersion.HTTP2_AND_3,
      // Personal use from North America / Asia: cheapest class that covers both.
      priceClass: PriceClass.PRICE_CLASS_200,
      defaultBehavior: {
        origin: S3BucketOrigin.withOriginAccessControl(siteBucket),
        viewerProtocolPolicy: ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: CachePolicy.CACHING_OPTIMIZED,
        responseHeadersPolicy: ResponseHeadersPolicy.SECURITY_HEADERS,
        functionAssociations: [{ function: spaRewrite, eventType: FunctionEventType.VIEWER_REQUEST }],
      },
      additionalBehaviors: {
        '/api/*': {
          origin: new HttpOrigin(api.originDomain, { protocolPolicy: OriginProtocolPolicy.HTTPS_ONLY }),
          viewerProtocolPolicy: ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: AllowedMethods.ALLOW_ALL,
          cachePolicy: CachePolicy.CACHING_DISABLED,
          // Everything but Host (API Gateway routes on its own hostname).
          // CloudFront always forwards Authorization on POST.
          originRequestPolicy: OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        },
      },
    })

    // Runtime config for the web app, so the bundle needn't be rebuilt per
    // environment. Absent in local dev → the app skips login and uses the mock.
    const webConfig = Source.jsonData('config.json', {
      authority: auth.issuerUrl,
      cognitoDomain: auth.hostedUiBaseUrl,
      clientId: auth.webClient.userPoolClientId,
      redirectUri: auth.webCallbackUrl,
      logoutUri: auth.webLogoutUrl,
    })

    // --- Upload the Vite build. Hashed assets are immutable; everything
    // else (index.html, manifest, icons, config) must revalidate.
    new BucketDeployment(this, 'DeployAssets', {
      sources: [Source.asset(WEB_DIST, { exclude: ['*', '!assets', '!assets/**'] })],
      destinationBucket: siteBucket,
      cacheControl: [CacheControl.fromString('public, max-age=31536000, immutable')],
      prune: false,
    })
    new BucketDeployment(this, 'DeploySite', {
      sources: [Source.asset(WEB_DIST, { exclude: ['assets', 'assets/**'] }), webConfig],
      destinationBucket: siteBucket,
      cacheControl: [CacheControl.fromString('no-cache')],
      prune: false,
      distribution,
      distributionPaths: ['/*'],
      memoryLimit: 512,
    })

    new CfnOutput(this, 'SiteUrl', { value: `https://${props.domainName}` })
    new CfnOutput(this, 'DistributionDomain', {
      value: distribution.distributionDomainName,
      description: `DNS: CNAME ${props.domainName} -> this value`,
    })
    new CfnOutput(this, 'DistributionId', { value: distribution.distributionId })
    new CfnOutput(this, 'SiteBucketName', { value: siteBucket.bucketName })
    new CfnOutput(this, 'ApiUrl', { value: `https://${props.domainName}/api/temporary-api-key` })
    new CfnOutput(this, 'CognitoDomain', { value: auth.hostedUiBaseUrl })
    new CfnOutput(this, 'UserPoolId', { value: auth.userPool.userPoolId })
    new CfnOutput(this, 'WebClientId', { value: auth.webClient.userPoolClientId })
    new CfnOutput(this, 'IosClientId', { value: auth.iosClient.userPoolClientId })
  }
}
