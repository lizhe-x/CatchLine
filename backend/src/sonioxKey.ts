// Long-lived Soniox key from SSM, read once per Lambda container.
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm'

const ssm = new SSMClient({})
let cached: Promise<string> | undefined

export function getLongLivedKey(): Promise<string> {
  // On failure, drop the cached promise so the next invocation retries.
  cached ??= ssm
    .send(new GetParameterCommand({ Name: process.env.SONIOX_KEY_PARAMETER!, WithDecryption: true }))
    .then((res) => {
      const value = res.Parameter?.Value
      if (!value) throw new Error(`SSM parameter ${process.env.SONIOX_KEY_PARAMETER} is empty`)
      return value
    })
    .catch((err: unknown) => {
      cached = undefined
      throw err
    })
  return cached
}
