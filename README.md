# AWS-Step-video-Flow

A production-style, asynchronous video processing platform built to
practically demonstrate every major AWS Step Functions capability: Task,
Choice, Parallel, Map, Wait, Pass, Succeed, Fail, Retry, Catch, Timeout,
`InputPath`/`ResultPath`/`OutputPath`, and native integrations with Lambda,
ECS/Fargate, S3, SNS, EventBridge, and DynamoDB. Built for hands-on learning
and to double as a portfolio/interview project.

**This is being built in phases.** See [Project status](#project-status)
below for what's implemented right now. This README is written for the full
end-state project and updated as each phase lands, so sections describing
unbuilt pieces are marked accordingly.

## 1. Project overview

A user uploads a video to S3. That upload triggers an EventBridge rule,
which starts a Step Functions **Standard Workflow**. The workflow validates
the video, extracts metadata, branches on validity, runs thumbnail
generation and metadata storage in parallel, transcodes the video into
multiple resolutions via a Step Functions **Map** state (each iteration
running FFmpeg inside an **ECS Fargate** task), collects the results, stores
everything in DynamoDB, and sends a success or failure notification via SNS
— all orchestrated declaratively by Step Functions, with retries and error
handling at every step that can plausibly fail.

Full narrative walkthrough and diagrams: [`docs/architecture.md`](docs/architecture.md).

## 2. Architecture

See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid
diagram, the S3 key layout, the DynamoDB item shape, the IAM relationship
diagram, and the design rationale for using Step Functions as the
orchestrator instead of a single Lambda.

## 3. AWS services used

S3 · Step Functions · Lambda · ECS · Fargate · ECR · DynamoDB · SNS ·
EventBridge · CloudWatch · IAM · (optionally) API Gateway

## 4. Repository structure

```
.
├── terraform/                    # All infrastructure (Terraform)
│   ├── main.tf / variables.tf / outputs.tf / providers.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── s3/                   # ✅ Phase 1
│       ├── iam/                  # ✅ Phase 1
│       ├── dynamodb/             # ✅ Phase 1
│       ├── networking/           # ✅ Phase 2 — VPC, public subnets, S3 endpoint, SG
│       ├── ecs/                  # ✅ Phase 2 — ECR, cluster, Fargate task def
│       ├── lambda/               # ✅ Phase 2 — 4 functions (2 zip, 2 image)
│       ├── step-functions/       # ✅ Phase 3 — state machine + execution IAM role
│       ├── sns/                  # ✅ Phase 4 — notifications topic
│       ├── eventbridge/          # ✅ Phase 4 — S3 upload trigger Lambda + rule
│       └── cloudwatch/           # ✅ Phase 4 — alarms + dashboard
├── src/
│   ├── lambda/
│   │   ├── validate/             # ✅ Phase 2 — zip-packaged
│   │   ├── database/             # ✅ Phase 2 — zip-packaged
│   │   ├── ffmpeg/                # ✅ Phase 2 — container image (metadata + thumbnail)
│   │   └── trigger/               # ✅ Phase 4 — zip-packaged, S3 upload → StartExecution
│   ├── video-processor/          # ✅ Phase 2 — Dockerized FFmpeg transcoder (ECS)
│   └── api/                      # ❌ Skipped (Phase 5, optional) — see src/api/README.md
├── step-functions/               # ✅ Phase 3 — ASL state machine definition + docs
├── scripts/
│   ├── deploy.sh                 # ✅ Phase 1 — terraform init/plan/apply wrapper
│   ├── build.sh                  # ✅ Phase 2 — Docker build/push (2 images)
│   └── upload-test-video.sh      # ✅ Phase 4 — trigger a real execution
├── tests/
│   ├── lambda/                   # ✅ Phase 2/4 — pytest + moto, validate/database/trigger
│   ├── video-processor/          # ✅ Phase 2 — pytest + moto, ffmpeg mocked
│   └── step-functions/           # ✅ Phase 5 — real, execution-based, deployed-stack tests
├── .github/workflows/            # ✅ Phase 5 — ci.yml (every push) + integration.yml (manual)
└── docs/
    ├── architecture.md           # ✅ full target architecture (written up front)
    └── troubleshooting.md        # ✅ Phase 5 — symptom-first cross-phase reference
```

Every not-yet-built directory contains a `README.md` stating which phase
implements it — that's intentional scaffolding, not dead weight; nothing in
those directories is referenced by the Terraform built so far. `src/api/`
is the one exception that stays permanently unbuilt by choice — its
`README.md` explains why.

## 5. Project status

| Phase | Contents | Status |
|---|---|---|
| 1 | Repo structure, architecture docs, Terraform base, S3, IAM, DynamoDB | ✅ Done |
| 2 | Lambda functions, Dockerized FFmpeg processor, ECR, ECS/Fargate, networking | ✅ Done |
| 3 | Step Functions state machine: Task/Choice/Parallel/Map/Wait/Retry/Catch/InputPath/ResultPath/OutputPath | ✅ Done |
| 4 | EventBridge auto-trigger, SNS notifications, CloudWatch alarms/dashboard | ✅ Done |
| **5** | GitHub Actions CI/CD, real execution-based tests, troubleshooting guide, interview questions (API skipped — see `src/api/README.md`) | ✅ **Done — this README covers it** |

## 6. Prerequisites

- An AWS account you're comfortable deploying learning infrastructure into
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with credentials (`aws configure` or an SSO profile)
- Docker (needed from Phase 2 onward, to build/push the two container images)
- Python 3.12 + `pip` (only if you want to run the Phase 2 unit tests locally)
- `jq` (used by a couple of the Phase 2 verification/test commands below)

## 7. AWS setup

Use an IAM identity with permissions to create S3 buckets, DynamoDB tables,
and IAM roles/policies (for Phase 1). Broad `AdministratorAccess` on a
sandbox/learning account is fine; in a shared account, a scoped
"infrastructure deployer" policy covering `s3:*`, `dynamodb:*`, and `iam:*`
on resources named `<project>-<env>-*` is enough for everything this project
creates — Terraform itself needs more than the least-privilege runtime roles
it provisions.

Confirm your CLI identity before deploying:

```bash
aws sts get-caller-identity
```

## 8. Terraform deployment — Phase 1

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set owner, and aws_region if you don't want us-east-1

terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Or via the wrapper script (from the repo root):

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
scripts/deploy.sh init
scripts/deploy.sh plan
scripts/deploy.sh apply
```

Phase 1 creates:

- One S3 bucket (`<project>-<env>-media-<account-id>`): versioned,
  encrypted (SSE-S3), all public access blocked, lifecycle rules for
  incomplete multipart uploads and noncurrent versions, CORS enabled, and
  EventBridge notifications flipped on (ready for Phase 4's rule).
- One DynamoDB table (`<project>-<env>-jobs`): `PAY_PER_REQUEST` billing,
  partition key `job_id`, GSI `status-created_at-index`, SSE enabled.
- Three IAM roles with individually-scoped policies: `lambda_execution`,
  `ecs_task`, `ecs_task_execution` — see
  [`docs/architecture.md`](docs/architecture.md#iam-relationships) for what
  each can and can't do and why.

Nothing here costs money at idle beyond a few cents of S3/DynamoDB storage —
see [Cost notes](#10-cost-notes-phase-1).

## 9. Verifying Phase 1

```bash
# Terraform's own view
terraform output

# S3 — bucket exists, versioning + encryption + public-access-block are on
aws s3api get-bucket-versioning --bucket "$(terraform output -raw media_bucket_name)"
aws s3api get-bucket-encryption --bucket "$(terraform output -raw media_bucket_name)"
aws s3api get-public-access-block --bucket "$(terraform output -raw media_bucket_name)"
aws s3api get-bucket-notification-configuration --bucket "$(terraform output -raw media_bucket_name)"

# DynamoDB — table + GSI exist and are ACTIVE
aws dynamodb describe-table --table-name "$(terraform output -raw dynamodb_table_name)" \
  --query 'Table.{Status:TableStatus,Billing:BillingModeSummary.BillingMode,GSIs:GlobalSecondaryIndexes[].IndexName}'

# IAM — roles exist with the expected trust policy and attached policies
aws iam get-role --role-name "$(terraform output -raw lambda_execution_role_arn | cut -d/ -f2)"
aws iam list-attached-role-policies --role-name "$(terraform output -raw lambda_execution_role_arn | cut -d/ -f2)"
aws iam list-attached-role-policies --role-name "$(terraform output -raw ecs_task_role_arn | cut -d/ -f2)"
aws iam list-attached-role-policies --role-name "$(terraform output -raw ecs_task_execution_role_arn | cut -d/ -f2)"

# Sanity-check least privilege: this should show ALLOWED only for the
# actions actually granted, on the actual bucket ARN
aws iam simulate-principal-policy \
  --policy-source-arn "$(terraform output -raw lambda_execution_role_arn)" \
  --action-names s3:GetObject s3:DeleteBucket \
  --resource-arns "$(terraform output -raw media_bucket_arn)/uploads/test.mp4"
```

Expected: `s3:GetObject` → `allowed`, `s3:DeleteBucket` → `implicitDeny` (the
role was never granted bucket-admin actions).

## 10. Cost notes (Phase 1)

Everything deployed so far is effectively free at rest for a learning
project:

- **S3**: pennies for a few GB of test video storage; no request charges
  until you're actually uploading/processing.
- **DynamoDB**: `PAY_PER_REQUEST` means $0 when idle, and this table's
  volume as a learning project is far below any meaningful cost.
- **IAM**: roles and policies are free.

Nothing here provisions compute (Lambda invocations, ECS tasks, NAT
Gateways) — that starts in Phase 2, where cost tradeoffs (e.g. avoiding NAT
Gateway's ~$32/month by using public subnets + a locked-down security group
for Fargate, per `docs/architecture.md`) are called out explicitly.

## 11. Cleanup

```bash
scripts/deploy.sh destroy
# or: cd terraform && terraform destroy
```

`s3_force_destroy = true` (the default) lets Terraform delete the bucket
even if it still has test objects in it — set it to `false` in
`terraform.tfvars` if you want a safety net against accidental destroys once
you're storing anything you care about.

## 12. Terraform deployment — Phase 2

Phase 2 adds networking, ECS/ECR, and Lambda on top of Phase 1. Two of the
four Lambda functions (`metadata`, `thumbnail`) and the ECS task definition
reference container images that don't exist until you've built and pushed
them — so the **first-ever** apply after adding Phase 2 needs three steps
instead of one:

```bash
cd terraform

# 1. Create just the (currently empty) ECR repos first
terraform apply \
  -target=module.ecs.aws_ecr_repository.video_processor \
  -target=module.lambda.aws_ecr_repository.lambda_ffmpeg

# 2. Build and push both images (needs Docker running; first build of the
#    ffmpeg image is slow — it downloads a ~130MB static ffmpeg build)
cd ..
scripts/build.sh all

# 3. Now apply everything else — the task definition and the two
#    image-based Lambda functions can now find real images
cd terraform
terraform apply
```

After that first bootstrap, a normal `terraform apply` / `scripts/deploy.sh
apply` is enough — the two-step dance is only needed because ECR repos
start empty and `:latest` doesn't exist until you've pushed something to it.
Pushing a new image later (`scripts/build.sh image` or `lambda-image`) is
picked up by ECS/Lambda on their next invocation without any Terraform run
at all, since both reference the mutable `:latest` tag by default.

## 13. Testing Phase 2 independently

Every function/task is invokable on its own, without Step Functions —
that's the point of building them first and wiring them into a state
machine in Phase 3.

**Unit tests** (no AWS account needed — S3/DynamoDB are mocked with `moto`,
ffmpeg is mocked with a monkeypatched `subprocess.run`):

```bash
pip install -r tests/lambda/requirements-test.txt
pytest tests/lambda/ -v

pip install -r tests/video-processor/requirements-test.txt
pytest tests/video-processor/ -v
```

**Against real deployed resources**, once Phase 2's `terraform apply` has
completed:

```bash
# Seed a test object (any small mp4 works, or a .txt renamed to .mp4 to
# exercise the invalid-format path)
aws s3 cp your-test-video.mp4 \
  "s3://$(cd terraform && terraform output -raw media_bucket_name)/uploads/test-job/source.mp4"

# validate
aws lambda invoke --function-name "$(cd terraform && terraform output -raw validate_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"job_id\":\"test-job\",\"bucket\":\"$(cd terraform && terraform output -raw media_bucket_name)\",\"key\":\"uploads/test-job/source.mp4\"}" \
  out.json && cat out.json

# metadata (needs the ffmpeg image built+pushed first)
aws lambda invoke --function-name "$(cd terraform && terraform output -raw metadata_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"job_id\":\"test-job\",\"bucket\":\"$(cd terraform && terraform output -raw media_bucket_name)\",\"key\":\"uploads/test-job/source.mp4\"}" \
  out.json && cat out.json

# thumbnail — same pattern, function name thumbnail_function_name

# database — create then update
aws lambda invoke --function-name "$(cd terraform && terraform output -raw database_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"job_id":"test-job","create":true,"updates":{"status":"PENDING"}}' \
  out.json && cat out.json

# video-processor (ECS RunTask directly — no Step Functions yet)
aws ecs run-task \
  --cluster "$(cd terraform && terraform output -raw ecs_cluster_name)" \
  --task-definition "$(cd terraform && terraform output -raw ecs_task_definition_family)" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$(cd terraform && terraform output -json public_subnet_ids | jq -r 'join(",")')],securityGroups=[$(cd terraform && terraform output -raw ecs_task_security_group_id)],assignPublicIp=ENABLED}" \
  --overrides "{\"containerOverrides\":[{\"name\":\"video-processor\",\"environment\":[{\"name\":\"JOB_ID\",\"value\":\"test-job\"},{\"name\":\"SOURCE_BUCKET\",\"value\":\"$(cd terraform && terraform output -raw media_bucket_name)\"},{\"name\":\"SOURCE_KEY\",\"value\":\"uploads/test-job/source.mp4\"},{\"name\":\"RESOLUTION\",\"value\":\"480p\"}]}]}"

# then watch it in CloudWatch Logs:
aws logs tail "$(cd terraform && terraform output -raw ecs_log_group_name)" --follow
```

## 14. Verifying Phase 2

```bash
# Networking
aws ec2 describe-vpcs --vpc-ids "$(cd terraform && terraform output -raw vpc_id)"
aws ec2 describe-subnets --subnet-ids $(cd terraform && terraform output -json public_subnet_ids | jq -r '.[]')

# ECR — both repos exist
aws ecr describe-repositories --repository-names \
  "$(cd terraform && terraform output -raw ecr_video_processor_repository_url | cut -d/ -f2)" \
  "$(cd terraform && terraform output -raw ecr_lambda_ffmpeg_repository_url | cut -d/ -f2)"

# ECS cluster + task definition
aws ecs describe-clusters --clusters "$(cd terraform && terraform output -raw ecs_cluster_name)"
aws ecs describe-task-definition --task-definition "$(cd terraform && terraform output -raw ecs_task_definition_family)"

# Lambda — all four functions exist and are Active
for fn in validate_function_name database_function_name metadata_function_name thumbnail_function_name; do
  aws lambda get-function --function-name "$(cd terraform && terraform output -raw $fn)" \
    --query 'Configuration.{Name:FunctionName,State:State,PackageType:PackageType,Timeout:Timeout,Memory:MemorySize}'
done
```

## 15. Cost notes (Phase 2 additions)

- **VPC / subnets / IGW / S3 Gateway Endpoint**: free. No NAT Gateway is
  provisioned (see `docs/architecture.md` for why public subnets + a
  locked-down security group are an equivalent, $0 alternative for this
  specific workload).
- **ECR**: storage cost only (a few cents/GB/month); the lifecycle policies
  in both `ecs` and `lambda` modules cap how many images accumulate.
- **Lambda**: free tier covers 1M requests + 400,000 GB-seconds/month —
  nowhere close to what manual testing here uses. Container-image cold
  starts are slightly slower/costlier than zip-based ones, which is part of
  why `validate`/`database` stay zip-based rather than defaulting everything
  to images.
- **ECS Fargate**: billed per-second while a task runs. A single manual
  `run-task` test transcoding a short clip costs a fraction of a cent; this
  only adds up if you leave something invoking it in a loop.

## 16. Terraform deployment — Phase 3

Phase 3 adds one module, `step-functions`, on top of everything Phase 1/2
built — no bootstrap dance this time (unlike Phase 2's ECR chicken-and-egg
problem, the state machine's definition only references ARNs that already
exist by the time you get here):

```bash
cd terraform
terraform apply
```

This creates:

- The **state machine** itself (`aws_sfn_state_machine.video_pipeline`,
  Standard Workflow type), rendered from
  `step-functions/state-machine.asl.json.tpl` with real ARNs substituted in.
- Its dedicated **`step_functions_execution` IAM role**, scoped to exactly
  the four Lambda ARNs, the ECS cluster + task definition family, and the
  `iam:PassRole`/EventBridge permissions the `ecs:runTask.sync` integration
  requires — see [`docs/architecture.md`](docs/architecture.md#iam-relationships)
  and `terraform/modules/step-functions/main.tf` for the full breakdown of
  why each statement exists.
- A CloudWatch Logs group (`/aws/vendedlogs/states/<project>-<env>-video-pipeline`)
  the state machine's execution history logging writes to.

## 17. Starting an execution (testing Phase 3)

```bash
BUCKET=$(cd terraform && terraform output -raw media_bucket_name)
SFN_ARN=$(cd terraform && terraform output -raw state_machine_arn)

# Upload a real test video to the key your input will reference
aws s3 cp your-test-video.mp4 "s3://${BUCKET}/uploads/job-demo-0001/source.mp4"

# Edit step-functions/sample-input.json: set "bucket" to $BUCKET

aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "manual-test-$(date +%s)" \
  --input file://step-functions/sample-input.json
```

Then watch it run in the Step Functions console (the visual execution graph
shows exactly which state ran, its input/output, and which Retry/Catch
fired if any did), or poll from the CLI with `aws stepfunctions
describe-execution`. Full walkthrough, the state-by-state documentation
table, Retry/Catch rationale, the three-layer timeout explanation, and
failure-simulation recipes: **[`step-functions/README.md`](step-functions/README.md)**.

## 18. Verifying Phase 3

```bash
# State machine exists and is ACTIVE
aws stepfunctions describe-state-machine \
  --state-machine-arn "$(cd terraform && terraform output -raw state_machine_arn)" \
  --query '{Name:name,Status:status,Type:type}'

# Execution role exists with the expected policies attached
ROLE_NAME=$(cd terraform && terraform output -raw step_functions_execution_role_arn | cut -d/ -f2)
aws iam list-attached-role-policies --role-name "$ROLE_NAME"

# Sanity-check least privilege: this role can invoke the pipeline's Lambdas
# but nothing else in the account
aws iam simulate-principal-policy \
  --policy-source-arn "$(cd terraform && terraform output -raw step_functions_execution_role_arn)" \
  --action-names lambda:InvokeFunction \
  --resource-arns "$(cd terraform && terraform output -raw validate_function_arn)" "arn:aws:lambda:*:*:function:some-other-function-not-in-this-project"
```

Expected: `allowed` for the real `validate_function_arn`, `implicitDeny` for
the made-up unrelated function ARN.

## 19. Cost notes (Phase 3 additions)

- **Step Functions Standard Workflow**: billed per state transition
  (roughly $0.025 per 1,000 transitions as of this writing — check current
  pricing, it changes). A full pipeline execution is on the order of 15-25
  transitions depending on how many resolutions you request; testing this
  manually a few dozen times costs a fraction of a cent.
- **CloudWatch Logs** for the state machine's execution history: same
  `log_retention_days`-controlled retention as every other log group in
  this project (Phase 1/2) — no "never expire" default left on.
- **X-Ray tracing is off** (`tracing_configuration.enabled = false`) —
  it's a small additional per-request cost this learning project doesn't
  need, since the Step Functions console's own execution graph plus
  CloudWatch Logs already show everything relevant.
- No new compute was added — Phase 3 orchestrates the Lambda/ECS Phase 2
  already built and costs; it doesn't add its own compute billing beyond
  the per-transition charge above.

## 20. Terraform deployment — Phase 4

Phase 4 adds three modules — `sns`, `eventbridge`, `cloudwatch` — on top of
everything Phase 1-3 built. No bootstrap dance this time either: unlike
Phase 2's ECR chicken-and-egg problem, all three modules only reference
resources (the media bucket, the state machine, the four Lambda ARNs) that
already exist by the time you get here.

```bash
cd terraform
terraform apply
```

If you want email notifications, set `notification_email` in
`terraform.tfvars` before applying — SNS will send a subscription
confirmation email that has to be clicked before notifications actually
deliver. Leaving it unset (the default) still creates the topic; you just
won't get emails, which is fine if you only plan to watch CloudWatch or poll
executions directly.

This creates:

- The **`sns-notifications`** topic, with an optional email subscription
  (`aws_sns_topic_subscription`, only created when `notification_email` is
  non-empty).
- The **`trigger` Lambda** and its own dedicated IAM role
  (`trigger_execution`, scoped to exactly one action —
  `states:StartExecution` — on exactly one resource, the state machine
  ARN), plus the **EventBridge rule** that invokes it whenever an object is
  created under `uploads/` in the media bucket. This replaces the manual
  `aws stepfunctions start-execution` call from section 17 as the normal way
  to run the pipeline — see [`step-functions/README.md`](step-functions/README.md#two-ways-to-start-an-execution)
  for both paths.
- Three new states in the state machine's ASL definition —
  `NotifyValidationFailure`, `NotifyProcessingFailure`, `NotifySuccess` —
  each a best-effort `sns:publish` Task with `ResultPath: null` and a
  `Catch: States.ALL` that routes straight to the real terminal state, so an
  SNS outage can never block or mask the actual pipeline outcome.
- Two **CloudWatch Alarms** (`ExecutionsFailed`, `ExecutionsTimedOut` on the
  state machine, both `alarm_actions` and `ok_actions` pointed at the SNS
  topic so recovery is announced too) and one **CloudWatch Dashboard**
  charting Step Functions executions/duration, all 5 Lambda functions'
  invocations/errors (the 4 from Phase 2 plus the new `trigger` function),
  and DynamoDB consumed capacity.

Full design rationale — why a trigger Lambda instead of a direct
EventBridge→Step Functions target, why `job_id` alone is the execution name
(idempotency), why there's no per-Lambda alarm or ECS dashboard widget — is
in [`docs/architecture.md`](docs/architecture.md#eventbridge-sns-and-cloudwatch-built-in-phase-4).

## 21. Testing the automatic trigger

With Phase 4 applied, uploading a video is now enough on its own — no
manual `start-execution` call needed:

```bash
BUCKET=$(cd terraform && terraform output -raw media_bucket_name)

aws s3 cp your-test-video.mp4 "s3://${BUCKET}/uploads/job-auto-0001/source.mp4"

# give EventBridge + the trigger Lambda a few seconds, then check
aws stepfunctions list-executions \
  --state-machine-arn "$(cd terraform && terraform output -raw state_machine_arn)" \
  --query 'executions[?name==`job-auto-0001`]'
```

Or use the wrapper script:

```bash
scripts/upload-test-video.sh your-test-video.mp4 job-auto-0002
```

Re-uploading to the same `job_id` within 90 days hits
`ExecutionAlreadyExists` and intentionally does **not** start a second
execution — see the idempotency note in `src/lambda/trigger/handler.py`. Use
a new `job_id` (a new key prefix) to start a fresh run. The manual
`start-execution` path from section 17 still works and is still the only
way to request non-default resolutions.

## 22. Verifying Phase 4

```bash
# EventBridge rule exists and targets the trigger Lambda
aws events describe-rule --name "$(cd terraform && terraform output -raw eventbridge_rule_name)"

# trigger Lambda exists and is Active
aws lambda get-function --function-name "$(cd terraform && terraform output -raw trigger_function_name)" \
  --query 'Configuration.{Name:FunctionName,State:State,Timeout:Timeout,Memory:MemorySize}'

# trigger's IAM role is scoped to exactly StartExecution on the state machine
TRIGGER_ROLE=$(aws lambda get-function --function-name "$(cd terraform && terraform output -raw trigger_function_name)" \
  --query 'Configuration.Role' --output text | cut -d/ -f2)
aws iam list-attached-role-policies --role-name "$TRIGGER_ROLE"

# SNS topic exists, and (if notification_email was set) the subscription is
# either "PendingConfirmation" or confirmed
aws sns list-subscriptions-by-topic --topic-arn "$(cd terraform && terraform output -raw sns_topic_arn)"

# Both alarms exist and their actions point at the SNS topic
aws cloudwatch describe-alarms \
  --alarm-names "$(cd terraform && terraform output -raw state_machine_arn | cut -d: -f6)-execution-failures" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Actions:AlarmActions}'

# Dashboard exists
aws cloudwatch get-dashboard --dashboard-name "$(cd terraform && terraform output -raw cloudwatch_dashboard_name)" \
  --query 'DashboardName'
```

Or just open the dashboard directly — `terraform output cloudwatch_dashboard_url`.

## 23. Cost notes (Phase 4 additions)

Unlike Phases 1-3 (all effectively free at rest), Phase 4 adds one genuine
small recurring cost:

- **CloudWatch Dashboard**: a flat **~$3/month** per dashboard regardless of
  how much you look at it — the one new fixed cost in this project so far.
- **CloudWatch Alarms**: ~$0.10/alarm/month for the two standard-resolution
  alarms this module creates (~$0.20/month total).
- **EventBridge**: the S3 "Object Created" rule itself is free to have
  registered; matched events are billed per-event and are negligible at
  learning-project upload volumes (well within the free tier).
- **Extra Lambda invocation**: the `trigger` function is tiny (128MB,
  ~sub-second) and invoked once per upload — effectively free at this
  volume, same free-tier headroom discussed in section 15.
- **SNS**: $0.50 per million publishes past the free tier (1,000/month
  free) — a learning project's manual test runs won't come close. Email
  delivery is free regardless of volume.

Nothing here is expensive, but the dashboard's flat fee means Phase 4 is the
first phase where "leave it deployed indefinitely" has a non-zero monthly
cost worth knowing about — see [Cleanup](#11-cleanup) if you want to tear
it down between sessions.

## 24. CI/CD — Phase 5

Two GitHub Actions workflows, deliberately split by cost/risk rather than
lumped into one:

- **[`.github/workflows/ci.yml`](.github/workflows/ci.yml)** — runs on
  every push/PR to `main`. Three jobs: the `tests/lambda/` unit tests
  (moto-mocked, no AWS account needed), the `tests/video-processor/` unit
  tests (same), and `terraform fmt -check` + `terraform init -backend=false`
  + `terraform validate` (needs network access to the provider registry,
  but no AWS credentials — it's checking the config is internally
  consistent, not touching real infrastructure). This is the workflow that
  should gate merges.
- **[`.github/workflows/integration.yml`](.github/workflows/integration.yml)**
  — `workflow_dispatch` only (manual trigger, never on push/PR). Runs the
  real, unmocked tests in `tests/step-functions/` against an already
  -deployed stack. See section 26 and
  [`tests/step-functions/README.md`](tests/step-functions/README.md) for
  what it needs configured before it'll do anything.

Since this repo hasn't been pushed to GitHub yet, there's nothing to
"deploy" here beyond pushing the code — `ci.yml` starts working the moment
this repo has a GitHub remote and a push happens; no secrets or setup
required for it specifically. `integration.yml` needs the one-time OIDC
role + repo variables setup documented in its own header comment before
its manual trigger will do anything useful.

## 25. Running the test suites locally

All three suites, in the order you'd typically want them (fast/free first):

```bash
# Unit tests — mocked, free, seconds to run. Two SEPARATE invocations
# (not one `pytest tests/`) — see docs/troubleshooting.md's Phase 5 table
# for why running them together hits a pytest conftest collision.
pip install -r tests/lambda/requirements-test.txt
pytest tests/lambda/ -v

pip install -r tests/video-processor/requirements-test.txt
pytest tests/video-processor/ -v

# Integration tests — real AWS, real (small) cost, minutes to run. Needs a
# deployed stack (Phases 1-4 applied) and three env vars pointing at it.
cd terraform
export STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)
export MEDIA_BUCKET_NAME=$(terraform output -raw media_bucket_name)
export DYNAMODB_TABLE_NAME=$(terraform output -raw dynamodb_table_name)
cd ..
pip install -r tests/step-functions/requirements-test.txt
pytest tests/step-functions/ -v
```

Running `pytest tests/step-functions/` with none of those three variables
set is safe — every test `SKIP`s with a message explaining what's missing,
rather than failing.

## 26. Verifying Phase 5

```bash
# Both workflow files are valid YAML with the expected jobs
python3 -c "
import yaml
for f in ['.github/workflows/ci.yml', '.github/workflows/integration.yml']:
    d = yaml.safe_load(open(f))
    print(f, '->', list(d['jobs'].keys()))
"

# All three local unit/integration suites in one pass (integration tests
# will SKIP unless you've exported the three env vars from section 25)
pytest tests/lambda/ -v
pytest tests/video-processor/ -v
pytest tests/step-functions/ -v
```

Once this repo is pushed to GitHub: confirm `ci.yml` shows as a check on
your first PR/push to `main`, and confirm `integration.yml` appears under
the repo's **Actions** tab with a **Run workflow** button (manual trigger
only — it will not fire on its own).

## 27. Cost notes (Phase 5 additions)

- **`ci.yml`**: free on GitHub's free tier for public repos; for a private
  repo, counts against your account's included Actions minutes (each run
  is well under 5 minutes total across all three jobs — negligible).
- **`integration.yml`**: each manual run costs roughly what one manual
  `start-execution` test already costs in Phase 3 (a few cents at most —
  a handful of Step Functions transitions, a few seconds of Fargate, a few
  KB of S3/DynamoDB) **times three**, since the suite runs the success,
  validation-failure, and processing-failure scenarios once each. Trivial
  for occasional runs before a release; not something to wire into
  every-push CI, which is exactly why it isn't.
- No new always-on infrastructure was added in Phase 5 — everything here
  is either free (static checks) or billed only for the seconds an
  on-demand workflow run actually executes.

## 28. Project status: all five phases complete

Every phase from the original plan is now built, tested (to the extent
testable without live infrastructure in some development environments —
see `docs/troubleshooting.md`), documented, and verified on the actual
target device. The one deliberate scope decision worth restating: the
optional FastAPI layer (`src/api/`) was not built — see
[`src/api/README.md`](src/api/README.md) for why, and what it would take
to add if you want it later.

From here, natural next steps if you want to keep extending this project
are documented, not required: a remote Terraform backend (S3 + DynamoDB
locking, sketched in `terraform/providers.tf`) for team use instead of
local state; splitting the single SNS topic into success/failure/ops
topics with routing rules; per-Lambda X-Ray tracing; or actually building
`src/api/` per the notes above.

---

## 29. Interview questions this project is built to answer

A learning/portfolio project is more useful if it can survive being
questioned, not just demoed. These are the questions this specific
codebase (not video-processing pipelines in the abstract) has real,
specific, file-pointing answers to — a way to check the project actually
taught what it set out to, not just a script to memorize.

**"Why Step Functions instead of one big Lambda function, or a chain of
Lambda-invokes-Lambda calls?"** Visibility (the console's execution graph
shows exactly which state ran, with what input/output, for every past
execution — see section 17), and separation of concerns: orchestration
logic (branching, retries, parallelism) lives declaratively in ASL, not
buried in `if`/`try` code paths across five different functions. See
`docs/architecture.md`'s "System overview" for the full state diagram.

**"Why does the ECS task role and the ECS task execution role need to be
two separate IAM roles?"** The execution role is assumed by the ECS agent
*before* your container starts (pulling the image, setting up logging);
the task role is assumed by *your application code* once it's running.
Keeping them separate means a compromised container can't use its own
credentials to, say, pull arbitrary images from ECR. Full answer:
`docs/architecture.md`'s "IAM relationships" section.

**"How do you guarantee this pipeline doesn't double-process the same
upload?"** `src/lambda/trigger/handler.py` sets the Step Functions
execution `name` to the `job_id` itself, not a timestamp-suffixed value —
Standard Workflow `StartExecution` is idempotent on `(name, input)` for 90
days, so a duplicate EventBridge delivery (which AWS's own docs say WILL
happen — "at least once" delivery) just returns the existing execution's
ARN instead of starting a second one.

**"What happens if your notification system (SNS) goes down — does the
pipeline break?"** No — every `Notify*` state has `ResultPath: null` and a
`Catch: States.ALL` routing straight to the real terminal state, with
*no* Retry. See `step-functions/README.md`'s Catch handlers section for
why skipping the retry there is deliberate, not an oversight.

**"Why are `validate` and `database` zip-packaged Lambdas but `metadata`
and `thumbnail` are container images?"** Native `ffmpeg`/`ffprobe`
binaries run ~140MB each, and Lambda's zip-plus-layers deployment caps
*unzipped* size at 250MB combined — two ffmpeg-family binaries alone blow
past that before a line of Python is counted. Container images cap at
10GB uncompressed instead. `validate`/`database` have zero native
dependencies, so there's no reason to pay a container image's larger,
slower-to-build, slower-cold-start deployment unit for them. Full
reasoning: `docs/architecture.md`'s "Why metadata/thumbnail are Lambda
container images" section.

**"Walk me through least privilege in this project — give a concrete
example, not just the term."** The Step Functions execution role has zero
DynamoDB permissions attached, even though the pipeline writes to
DynamoDB constantly — every job-record write flows through the
`database` Lambda's *own* `lambda_execution` role instead (the
single-writer pattern). The state machine's role only needs
`lambda:InvokeFunction` on four specific ARNs, `ecs:RunTask` scoped to one
cluster/task-definition family, and (Phase 4) `sns:Publish` on one topic
ARN — nothing wildcarded. See `docs/architecture.md`'s IAM diagram and the
"Why the Step Functions execution role was built in Phase 3, not earlier"
paragraph for why that role wasn't just given broad access up front.

**"How would you test this without a live AWS account?"** Two layers:
`moto`-mocked unit tests (`tests/lambda/`, `tests/video-processor/`) that
run anywhere, cost nothing, and run in CI on every push; and for the ASL
definition itself (which moto can't meaningfully simulate — Step
Functions' real Map/Parallel/Catch semantics aren't reproduced), a
`templatefile()` + `jsondecode()` round-trip that renders the real
template with dummy ARNs and asserts on the resulting JSON structure
without needing an AWS provider at all. Real end-to-end correctness still
needs `tests/step-functions/` against a real deployed stack — that's the
one thing neither mocking layer can substitute for.

**"What would you change to run this at real production scale, not just
as a learning project?"** A remote Terraform backend with state locking
(single biggest gap for team use — see `terraform/providers.tf`); NAT
Gateway (or VPC endpoints for every AWS service touched) instead of public
subnets for the Fargate tasks, if "no task ever holds a routable public
IP" becomes a real compliance requirement rather than a cost tradeoff; a
higher `sfn_alarm_threshold` than "alert on the first failure" once
failure volume is expected background noise rather than a signal; and
splitting the single SNS topic into routed success/failure/ops topics so
failures can page on-call while successes just log.
