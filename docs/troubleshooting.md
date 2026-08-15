# Troubleshooting

A symptom-first reference across all five phases. For narrative
walkthroughs of *why* things are built the way they are, see
[`architecture.md`](architecture.md); this doc is for "it's not working,
what do I check."

## Terraform / deployment

| Symptom | Likely cause | Fix |
|---|---|---|
| `terraform apply` fails on the very first run with an ECR/image-related error (task definition, `metadata`/`thumbnail` Lambda) | Phase 2's chicken-and-egg: those resources reference container images that don't exist yet | Follow the three-step bootstrap in root README section 12: `-target` the two ECR repos first, run `scripts/build.sh all`, then `terraform apply` again |
| `Error: BucketAlreadyExists` or similar on the S3 bucket | Bucket names are globally unique across ALL AWS accounts; extremely unlikely given the bucket name includes your account ID, but can happen with a typo'd `project_name`/`environment` colliding with something else you own | Change `project_name` or `environment` in `terraform.tfvars` |
| `terraform init`/`validate` can't reach the provider registry (works locally, fails here) | You're running inside a network-restricted sandbox (this is a known, disclosed limitation of the environment this project was originally developed in — see the note in `terraform/providers.tf`'s history) | Not fixable in that sandbox; run `terraform init`/`apply` from a normal machine or CI runner with outbound internet access. `.github/workflows/ci.yml`'s `terraform-check` job runs in a normal GitHub-hosted runner and does NOT have this limitation |
| `Error: creating IAM Role ... AccessDenied` during `terraform apply` | Your AWS identity lacks `iam:CreateRole`/`iam:PutRolePolicy` etc. | See root README section 7 ("AWS setup") — you need at least a scoped "infrastructure deployer" policy, not just the least-privilege runtime roles Terraform provisions |

## Phase 3: Step Functions executions

| Symptom | Likely cause | Fix |
|---|---|---|
| `start-execution` itself fails with `AccessDeniedException` | The **caller's** IAM identity (you, or whoever's running the CLI) lacks `states:StartExecution` — separate from the state machine's own execution role | Confirm your identity has `states:StartExecution` on the state machine ARN; this is about who can *start* a run, not what the run itself can *do* |
| Execution starts but a specific state immediately fails with `States.Runtime` or a JSONPath error | A `Parameters`/`InputPath`/`ResultPath` typo in `state-machine.asl.json.tpl`, or the execution input doesn't match the contract in `step-functions/README.md`'s "Execution input contract" | Open the failed execution in the Step Functions console — the visual graph shows exactly which state failed and its actual input; compare against the state-by-state table in `step-functions/README.md` |
| Execution hangs in `RUNNING` far longer than expected | Usually an ECS Fargate task that can't reach the network it needs (pull the image from ECR, or reach S3/DynamoDB) | Check the ECS task's own status (`aws ecs describe-tasks`) and its CloudWatch log group — a task stuck in `PENDING` almost always means a networking/security-group issue (see `docs/architecture.md`'s Networking section); a task that's `RUNNING` but never finishes is a real transcode taking a long time on a large source file |
| A Lambda-backed Task fails immediately with `AccessDeniedException` calling S3/DynamoDB | The **execution role**'s policy doesn't cover the specific action/resource (least privilege working as intended, but for the wrong scope) | Use `aws iam simulate-principal-policy` against `step_functions_execution_role_arn` (see root README section 18) to confirm exactly what's allowed vs. denied |

## Phase 4: EventBridge / SNS / CloudWatch

| Symptom | Likely cause | Fix |
|---|---|---|
| Uploading a file to `uploads/` never starts an execution | Several possible links in the chain: (1) the bucket's EventBridge notifications toggle, (2) the EventBridge rule's event pattern, (3) the rule's target/Lambda permission, (4) the trigger Lambda's own logic | Check in order: `aws s3api get-bucket-notification-configuration` (EventBridge block should be present — enabled since Phase 1), `aws events describe-rule` + `list-targets-by-rule` (confirms the rule exists and targets the trigger Lambda), then the trigger Lambda's own CloudWatch Logs (confirms it was invoked at all, and why it may have skipped — see its `UnrecognizedKeyShapeError` logging) |
| Upload triggers an execution, but re-uploading the *same* `job_id` doesn't | This is intentional, not a bug — see the idempotency note in `src/lambda/trigger/handler.py`. `StartExecution` is idempotent on `(name, input)` for 90 days on Standard Workflows | Use a new `job_id` (new key prefix) to force a fresh execution, or use the manual `start-execution` path with an explicit `--name` |
| No SNS email ever arrives | Either `notification_email` was never set, or it was set but the confirmation link was never clicked | `aws sns list-subscriptions-by-topic` — status `PendingConfirmation` means check your inbox (and spam folder) for the AWS confirmation email; it's a one-time click |
| CloudWatch alarm stays in `INSUFFICIENT_DATA` forever | `treat_missing_data = "notBreaching"` means genuinely zero executions in the evaluation window is NOT the same as "no failures" from the alarm's perspective, but the metric itself may simply have no data points yet if the pipeline has never run | Trigger at least one execution (success or failure) — `AWS/States` metrics only appear after the first execution against that state machine |
| Dashboard shows a Lambda with zero invocations that you know ran | Dashboard widgets default to a 300s period — a single recent invocation may not have aggregated into a visible datapoint yet, or the dashboard's default time range window doesn't include it | Widen the dashboard's time range in the console; this is a display/aggregation-window issue, not a missing-metric issue |

## Phase 5: tests and CI

| Symptom | Likely cause | Fix |
|---|---|---|
| `pytest tests/lambda/ tests/video-processor/` (both directories together) fails to collect with an `ImportError` on `conftest` | Both directories have a same-named `conftest.py` module with no package `__init__.py`, and pytest's default import mode can't disambiguate two same-named top-level modules when collected together | Run them as two separate `pytest` invocations (exactly as every phase's docs and `.github/workflows/ci.yml` already do) — this is a pytest collection quirk, not a real bug in either suite |
| Everything in `tests/step-functions/` shows as `SKIPPED` | Expected default behavior — see `tests/step-functions/conftest.py`'s `_require_env` helper | Export `STATE_MACHINE_ARN`, `MEDIA_BUCKET_NAME`, `DYNAMODB_TABLE_NAME` (from `terraform output`) before running; see `tests/step-functions/README.md` |
| Integration tests time out (`TimeoutError` from `wait_for_execution`) | Same root causes as "execution hangs in RUNNING" above, most commonly a Fargate task that can't pull its image or reach the network it needs | Same fix — inspect the ECS task and its logs directly; the fixture video is deliberately tiny (1s, 64×64) specifically so a slow transcode is never the explanation |
| `.github/workflows/integration.yml` fails at the "Configure AWS credentials" step | The `AWS_INTEGRATION_TEST_ROLE_ARN` secret isn't set, or the role's trust policy doesn't trust this specific repo's GitHub OIDC provider | See the setup comment at the top of `integration.yml`; this is a one-time per-repo setup step, not something that "just works" out of the box |
| moto-based unit tests fail after upgrading `boto3`/`moto` | moto's simulated AWS behavior occasionally lags or diverges from real AWS (see the `ExecutionAlreadyExists` workaround in `tests/lambda/test_trigger.py` — moto doesn't enforce Step Functions' real name-uniqueness constraint) | Check moto's changelog for the service in question; if a real-AWS behavior isn't simulated, monkeypatch the specific boto3 client method being tested rather than relying on moto to enforce it (see that same test file for the pattern) |

## General diagnostic habits worth having regardless of phase

Three commands cover the large majority of "why isn't this working" questions in this project, because almost everything here is either an IAM problem, a networking problem, or visible in CloudWatch Logs:

```bash
# "Is this identity/role actually allowed to do the thing it's trying to do?"
aws iam simulate-principal-policy --policy-source-arn <role-arn> --action-names <action> --resource-arns <arn>

# "What actually happened inside this Step Functions execution?"
aws stepfunctions get-execution-history --execution-arn <arn> --reverse-order --max-items 20

# "What did this Lambda/ECS task actually log?"
aws logs tail <log-group-name> --since 15m
```
