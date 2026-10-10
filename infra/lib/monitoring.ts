import { Duration } from 'aws-cdk-lib'
import { CfnBudget } from 'aws-cdk-lib/aws-budgets'
import { Alarm, ComparisonOperator, TreatMissingData } from 'aws-cdk-lib/aws-cloudwatch'
import { SnsAction } from 'aws-cdk-lib/aws-cloudwatch-actions'
import type { IFunction } from 'aws-cdk-lib/aws-lambda'
import { Topic } from 'aws-cdk-lib/aws-sns'
import { EmailSubscription } from 'aws-cdk-lib/aws-sns-subscriptions'
import { Construct } from 'constructs'

export interface MonitoringProps {
  alarmEmail: string
  monthlyBudgetUsd: number
  temporaryKeyFunction: IFunction
  /** Cost allocation tag (key=value) that marks this project's resources. */
  costTag: { key: string; value: string }
}

export class Monitoring extends Construct {
  constructor(scope: Construct, id: string, props: MonitoringProps) {
    super(scope, id)

    const topic = new Topic(this, 'AlarmTopic', { displayName: 'Catchline alarms' })
    // AWS emails a confirmation link; alarms are silent until it's clicked.
    topic.addSubscription(new EmailSubscription(props.alarmEmail))
    const notify = new SnsAction(topic)

    const fn = props.temporaryKeyFunction

    new Alarm(this, 'TemporaryKeyErrors', {
      alarmDescription: 'Temporary-key Lambda failed (SSM, Soniox, or code error)',
      metric: fn.metricErrors({ period: Duration.minutes(5) }),
      threshold: 1,
      evaluationPeriods: 1,
      comparisonOperator: ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: TreatMissingData.NOT_BREACHING,
    }).addAlarmAction(notify)

    // One key per session start/reconnect; dozens per hour means a bug
    // (reconnect loop) or abuse — either way it's burning Soniox money.
    new Alarm(this, 'TemporaryKeyInvocationSpike', {
      alarmDescription: 'More than 50 temporary keys issued in an hour',
      metric: fn.metricInvocations({ period: Duration.hours(1) }),
      threshold: 50,
      evaluationPeriods: 1,
      comparisonOperator: ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: TreatMissingData.NOT_BREACHING,
    }).addAlarmAction(notify)

    // Scoped to resources tagged project=catchline, so other spend in the
    // account (e.g. Lightsail) doesn't trip it. The tag must be activated as
    // a cost allocation tag in Billing before it filters anything.
    new CfnBudget(this, 'MonthlyBudget', {
      budget: {
        budgetName: 'catchline-monthly',
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: { amount: props.monthlyBudgetUsd, unit: 'USD' },
        costFilters: { TagKeyValue: [`user:${props.costTag.key}$${props.costTag.value}`] },
      },
      notificationsWithSubscribers: [
        {
          notification: {
            notificationType: 'ACTUAL',
            comparisonOperator: 'GREATER_THAN',
            threshold: 80,
            thresholdType: 'PERCENTAGE',
          },
          subscribers: [{ subscriptionType: 'EMAIL', address: props.alarmEmail }],
        },
      ],
    })
  }
}
