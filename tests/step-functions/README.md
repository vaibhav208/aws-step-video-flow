# Step Functions tests (Phase 5)

Real, unmocked, execution-based tests that drive a **deployed** state
machine end to end. These are a different kind of test from
`tests/lambda/` and `tests/video-processor/` (mocked with `moto`, no AWS
account needed, run on every push in CI) -- there is no way to mock "does
this whole pipeline actually work," so these tests are the thing that
catches the class of bug unit tests structurally can't: a wrong IAM
permission, a `Parameters` block pointing at the wrong JSONPath, a real
network path that only breaks inside an actual VPC, a timeout that's
tight enough to matter against real Fargate cold-start latency.

## What's covered

Three deterministic scenarios, each triggerable through the pipeline's own
documented inputs (no need to temporarily break IAM, kill a running task,
or shrink a `TimeoutSeconds` value to force a race):

| Test | What it exercises | How it's triggered |
|---|---|---|
| `test_successful_execution_completes` | The full happy path: `ValidateVideo` → `Parallel` (thumbnail + metadata) → `Map` (transcode) → `RecordJobComplete` → `NotifySuccess` → `JobSucceeded` | A real tiny (1s, 64×64) video fixture, requesting only `480p` to keep runtime/cost minimal |
| `test_validation_failure_routes_correctly` | `IsVideoValid` routing to `HandleValidationFailure` → `NotifyValidationFailure` → `ValidationFailedState` | A `.txt` object uploaded under `uploads/` — rejected by `ValidateVideo`'s format check |
| `test_processing_failure_routes_correctly` | `RunTranscodeTask`'s `Catch` routing to `HandleProcessingFailure` → `NotifyProcessingFailure` → `ProcessingFailedState` | A valid video but an unsupported resolution string (`"8k"`) — `video-processor` exits 1 |

Each test also reads back the DynamoDB job record and asserts on the exact
fields `step-functions/state-machine.asl.json.tpl` writes for that path
(`status`, `failure_stage`, `resolutions_processed`, `thumbnail_key`,
`duration_seconds`, `validation_errors`) — confirming not just that the
execution reached the right terminal state, but that the right data
landed where the rest of the system (and a human debugging it) expects it.

**Not automated here**, and why: Lambda Retry-exhaustion, an ECS task
killed mid-run, and a state's `TimeoutSeconds` actually firing are all
real, valid failure modes — but reliably forcing them means deliberately
degrading the real deployed infrastructure (revoking a permission, killing
a task out from under the state machine, cutting a timeout tight enough
that it legitimately races real transcode time). That's reasonable to walk
through by hand against your own dev stack (see "Simulating failures" in
[`step-functions/README.md`](../../step-functions/README.md) — the same
recipes these three automated tests are drawn from) but not something to
script unattended against whatever AWS account happens to be wired up to
CI.

## Running these tests

They need a **real deployed stack** (`terraform apply` from the root
README's Phase 1-4 instructions) and three environment variables
identifying it — deliberately not read from Terraform state/outputs
directly, so this suite stays decoupled from *where* that state lives
(local file, S3 backend, run from your laptop or from CI):

```bash
cd terraform
export STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)
export MEDIA_BUCKET_NAME=$(terraform output -raw media_bucket_name)
export DYNAMODB_TABLE_NAME=$(terraform output -raw dynamodb_table_name)
cd ..

pip install -r tests/step-functions/requirements-test.txt
python -m pytest tests/step-functions/ -v
```

Without those three variables set, every test in this directory `skip`s
(not fails) with a message pointing back here — running `pytest` from the
repo root or in an environment with no deployed stack is safe and won't
error out.

Runtime is minutes, not seconds (waiting on real Step Functions executions
and real Fargate task startup), and each run costs a small amount of real
money — see the root README's Phase 5 cost note. That's also why this
suite is wired to the separate, manually-triggered
[`.github/workflows/integration.yml`](../../.github/workflows/integration.yml)
rather than the on-every-push
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

## Test isolation

Every test gets a fresh `job_id` (`test-<random hex>`) from the
`unique_job_id` fixture in `conftest.py`, so runs don't collide with each
other, with manual testing (section 17/21 of the root README), or with a
real EventBridge-triggered execution from an actual upload. Nothing here
deletes its own S3 objects, DynamoDB items, or Step Functions execution
history afterward — for a learning-project dev account that's a fair
tradeoff for keeping the tests simple (and the leftover `test-*` records
are themselves a useful trail if you ever need to see exactly what a
passing run actually did); a shared/production account would want a
teardown fixture pruning these by the `test-` prefix.
