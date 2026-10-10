import { CfnOutput, Stack, type StackProps } from 'aws-cdk-lib'
import { Certificate, CertificateValidation, type ICertificate } from 'aws-cdk-lib/aws-certificatemanager'
import type { Construct } from 'constructs'

interface CertStackProps extends StackProps {
  domainName: string
}

/**
 * ACM certificate for the site. Kept in its own stack because the DNS zone
 * (getbot.me) is hosted at Aliyun, not Route 53: the first deploy blocks
 * until the validation CNAME is added by hand. Once issued, this stack
 * never changes, so app deploys don't wait on it.
 */
export class CertStack extends Stack {
  readonly certificate: ICertificate

  constructor(scope: Construct, id: string, props: CertStackProps) {
    super(scope, id, props)

    const certificate = new Certificate(this, 'SiteCertificate', {
      domainName: props.domainName,
      validation: CertificateValidation.fromDns(),
    })
    this.certificate = certificate

    new CfnOutput(this, 'CertificateArn', { value: certificate.certificateArn })
  }
}
