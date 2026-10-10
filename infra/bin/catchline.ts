#!/usr/bin/env node
import { App, Tags } from 'aws-cdk-lib'
import { CertStack } from '../lib/cert-stack.ts'
import { AppStack } from '../lib/app-stack.ts'

const app = new App()
const ctx = <T>(key: string): T => app.node.getContext(`catchline:${key}`) as T

const domainName = ctx<string>('domainName')
const costTag = { key: 'project', value: 'catchline' }

// Everything lives in us-east-1: CloudFront requires its ACM certificate
// there, and keeping one region avoids cross-region references.
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-1' }

const cert = new CertStack(app, 'CatchlineCert', { env, domainName })

new AppStack(app, 'CatchlineApp', {
  env,
  domainName,
  certificate: cert.certificate,
  cognitoDomainPrefix: ctx('cognitoDomainPrefix'),
  iosUrlScheme: ctx('iosUrlScheme'),
  selfSignUp: ctx('selfSignUp'),
  sonioxKeyParameterName: ctx('sonioxKeyParameter'),
  alarmEmail: ctx('alarmEmail'),
  monthlyBudgetUsd: ctx('monthlyBudgetUsd'),
  costTag,
})

// Every taggable resource gets project=catchline (drives the cost budget).
Tags.of(app).add(costTag.key, costTag.value)
