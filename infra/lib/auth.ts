import { Duration, RemovalPolicy } from 'aws-cdk-lib'
import {
  AccountRecovery,
  CfnManagedLoginBranding,
  FeaturePlan,
  ManagedLoginVersion,
  OAuthScope,
  UserPool,
  type UserPoolClient,
  UserPoolDomain,
} from 'aws-cdk-lib/aws-cognito'
import { Construct } from 'constructs'

export interface AuthProps {
  /** e.g. catchline.deskfox.cn — the web client's redirect target. */
  siteDomain: string
  /** Globally unique prefix for <prefix>.auth.us-east-1.amazoncognito.com */
  cognitoDomainPrefix: string
  /** Custom URL scheme of the iOS app, e.g. com.deskfox.catchline */
  iosUrlScheme: string
  /** Phase A: false (admin creates the only user). Phase B: true. */
  selfSignUp: boolean
}

/**
 * Cognito user pool + Managed Login (hosted UI), OAuth 2.0 Authorization
 * Code flow with PKCE. Two public clients (no secret — browsers and phones
 * can't keep one): web and iOS. Both get the same access tokens, so the API
 * authorizer and per-user usage tracking (`sub`) are shared.
 */
export class Auth extends Construct {
  readonly userPool: UserPool
  readonly webClient: UserPoolClient
  readonly iosClient: UserPoolClient
  readonly domain: UserPoolDomain
  readonly webCallbackUrl: string
  readonly webLogoutUrl: string

  constructor(scope: Construct, id: string, props: AuthProps) {
    super(scope, id)

    this.userPool = new UserPool(this, 'UserPool', {
      userPoolName: 'catchline',
      // Essentials is required for the new Managed Login pages; free up to 10k MAU.
      featurePlan: FeaturePlan.ESSENTIALS,
      selfSignUpEnabled: props.selfSignUp,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: { email: { required: true, mutable: true } },
      passwordPolicy: { minLength: 10, requireSymbols: false },
      accountRecovery: AccountRecovery.EMAIL_ONLY,
      // Phase A has a single throwaway user; switch to RETAIN before real users exist.
      removalPolicy: RemovalPolicy.DESTROY,
    })

    this.domain = this.userPool.addDomain('Domain', {
      cognitoDomain: { domainPrefix: props.cognitoDomainPrefix },
      managedLoginVersion: ManagedLoginVersion.NEWER_MANAGED_LOGIN,
    })

    this.webCallbackUrl = `https://${props.siteDomain}/auth/callback`
    this.webLogoutUrl = `https://${props.siteDomain}/`

    const common = {
      generateSecret: false,
      preventUserExistenceErrors: true,
      // Sign-in happens on the hosted UI. Pin the direct flows explicitly
      // (SRP + refresh only) instead of Cognito's implicit defaults, which
      // also enable custom auth.
      authFlows: { userSrp: true },
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(30),
      enableTokenRevocation: true,
    }
    const scopes = [OAuthScope.OPENID, OAuthScope.EMAIL, OAuthScope.PROFILE]

    this.webClient = this.userPool.addClient('WebClient', {
      ...common,
      userPoolClientName: 'web',
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes,
        callbackUrls: [this.webCallbackUrl],
        logoutUrls: [this.webLogoutUrl],
      },
    })

    this.iosClient = this.userPool.addClient('IosClient', {
      ...common,
      userPoolClientName: 'ios',
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes,
        callbackUrls: [`${props.iosUrlScheme}://auth/callback`],
        logoutUrls: [`${props.iosUrlScheme}://auth/logout`],
      },
    })

    // Managed Login needs a branding record per client, or its pages error out.
    for (const [name, client] of [
      ['WebBranding', this.webClient],
      ['IosBranding', this.iosClient],
    ] as const) {
      new CfnManagedLoginBranding(this, name, {
        userPoolId: this.userPool.userPoolId,
        clientId: client.userPoolClientId,
        useCognitoProvidedValues: true,
      })
    }
  }

  get issuerUrl(): string {
    return `https://cognito-idp.${this.userPool.env.region}.amazonaws.com/${this.userPool.userPoolId}`
  }

  get hostedUiBaseUrl(): string {
    return this.domain.baseUrl()
  }
}
