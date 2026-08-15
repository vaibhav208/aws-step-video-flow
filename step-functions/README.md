# step-functions

**Status:** Implemented in **Phase 3**; extended with SNS notifications in
**Phase 4**; covered by real execution-based tests in **Phase 5**.

This directory holds the Amazon States Language (ASL) source for the pipeline's
Standard Workflow state machine — the actual orchestration logic that ties
together every Lambda function and the ECS Fargate task built in Phase 2, plus
(as of Phase 4) a best-effort SNS notification before every terminal state.

| File | What it is |
|---|---|
| `state-machine.asl.json.tpl` | The real ASL definition, as an HCL `templatefile()` template. This is the single source of truth — Terraform (`terraform/modules/step-functions`) renders it with real ARNs and deploys it; nothing else generates or duplicates it. |
| `sample-input.json` | A ready-to-edit execution input for manual testing (see below). |

Why a `.tpl` file living outside `terraform/` at all, instead of an inline
`jsonencode(...)` block in the Terraform module? Two reasons: (1) ASL is
already JSON — writing it as HCL `jsonencode()` would mean either a giant,
hard-to-read nested HCL structure or constant back-and-forth translation
while editing; a plain `.json.tpl` file is exactly what you'd paste into the
Step Functions console's own visual editor. (2) Keeping it here (not nested
three directories deep inside a Terraform module) matches how you'll
actually work with it: open this one file to understand or change the
workflow logic, without needing to understand Terraform at all.

## How Terraform turns this into a deployed state machine

`terraform/main.tf`'s `module "step_functions"` block calls:

```hcl
definition = templatefile("${path.module}/../step-functions/state-machine.asl.json.tpl", {
  validate_function_arn       = module.lambda.validate_function_arn
  database_function_arn       = module.lambda.database_function_arn
  metadata_function_arn       = module.lambda.metadata_function_arn
  thumbnail_function_arn      = module.lambda.thumbnail_function_arn
  ecs_cluster_arn             = module.ecs.ecs_cluster_arn
  ecs_task_definition_family  = module.ecs.task_definition_family
  ecs_task_security_group_id  = module.networking.ecs_task_security_group_id
  public_subnet_ids           = module.networking.public_subnet_ids
  ecs_runtask_stagger_seconds = var.ecs_runtask_stagger_seconds
  sns_topic_arn               = module.sns.topic_arn
})
```

Every `${...}` placeholder in the `.tpl` file is substituted with a real
resource ARN/ID from the Phase 1/2 modules before the JSON is handed to
`aws_sfn_state_machine`. There are no placeholder or wildcard values left in
what actually gets deployed.

## Execution input contract

```json
{
  "job_id": "job-demo-0001",
  "bucket": "your-media-bucket-name",
  "key": "uploads/job-demo-0001/source.mp4",
  "resolutions": ["1080p", "720p", "480p"]
}
```

`resolutions` can be any subset/order of `1440p, 1080p, 720p, 480p, 360p,
240p` — the `video-processor` app's `RESOLUTION_PRESETS` (Phase 2) already
supports all six, and the `TranscodeAllResolutions` Map state iterates
whatever list you pass with **no state machine changes required** to add or
remove a resolution.

## Two ways to start an execution

As of Phase 4, this input is normally built and supplied **automatically**:
uploading a file to `s3://<media-bucket>/uploads/<job_id>/<filename>`
triggers the `eventbridge` module's rule, which invokes the `trigger`
Lambda (`src/lambda/trigger/handler.py`), which derives `job_id` from the
key and calls `StartExecution` with `resolutions` set from the
`trigger_target_resolutions` Terraform variable (default
`1080p,720p,480p`). That's genuinely the easiest way to test the whole
pipeline end to end now — just `aws s3 cp` a real video to the right key
and watch the Step Functions console.

The manual path below still works exactly as it did in Phase 3, and is
still the only way to request a *specific* (non-default) set of resolutions
for a one-off test, since the automatic trigger always uses the Terraform
variable's default list.

## Testing the deployed state machine manually

```bash
# 1. Get the values you need from Terraform outputs
STATE_MACHINE_ARN=$(terraform -chdir=terraform output -raw state_machine_arn)
BUCKET=$(terraform -chdir=terraform output -raw media_bucket_name)

# 2. Upload a real test video to the bucket at the key your input references
aws s3 cp ./my-test-video.mp4 "s3://${BUCKET}/uploads/job-demo-0001/source.mp4"

# 3. Edit sample-input.json: set "bucket" to $BUCKET (job_id/key can stay as-is
#    if you uploaded to that exact key, or change both together)

# 4. Start an execution
aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --name "manual-test-$(date +%s)" \
  --input file://step-functions/sample-input.json

# 5. Watch it run — either in the Step Functions console (visual execution
#    graph, per-state input/output, exactly which Retry/Catch fired), or:
aws stepfunctions describe-execution --execution-arn <arn-from-step-4-output>

# 6. Check the job record Step Functions wrote/updated throughout the run
aws dynamodb get-item \
  --table-name "$(terraform -chdir=terraform output -raw dynamodb_table_name)" \
  --key '{"job_id": {"S": "job-demo-0001"}}'
```

A full execution (validate → thumbnail + metadata in parallel → transcode
3 resolutions on Fargate) realistically takes several minutes, dominated by
the ECS `RunTask.sync` calls (Fargate task provisioning + the actual ffmpeg
transcode). This is expected — Standard Workflows are built for exactly this
kind of longer-running orchestration (up to 1 year per execution), unlike
Express Workflows which are optimized for short, high-volume executions.

## Simulating failures

Three of these recipes are now automated as real assertions in
[`tests/step-functions/test_end_to_end.py`](../tests/step-functions/test_end_to_end.py)
(Phase 5) — this section stays as the manual/exploratory reference for
poking at them by hand, and as the source the automated versions were
drawn from.

- **Validation failure:** point `key` at a `.txt` file, or a video larger
  than `max_file_size_bytes` → `ValidateVideo` returns `is_valid: false` →
  `IsVideoValid` routes to `HandleValidationFailure` → `ValidationFailedState`.
- **Missing source object:** point `key` at an object that doesn't exist →
  the `validate` Lambda raises `SourceObjectNotFoundError` → caught directly
  (no retries) → same failure path as above.
- **Transcoding failure:** pass a `resolutions` entry that isn't one of the
  six supported presets (e.g. `"8k"`) → the ECS task's `video-processor` app
  exits 1 with "Unsupported resolution" → `RunTranscodeTask` catches
  `States.TaskFailed` → `RecordResolutionFailure` → `ResolutionFailed` (Fail,
  inside the Map iterator) → propagates up and fails the whole Map →
  `HandleProcessingFailure` → `ProcessingFailedState`.

Each of these is visible end-to-end in the DynamoDB job record
(`status`, `failure_stage`, and either `validation_errors` or
`failed_resolution`/`error_info`) as well as in the Step Functions console's
execution graph and CloudWatch Logs.

---

## State-by-state documentation

| State | Type | Purpose | Input | Output | Failure handling |
|---|---|---|---|---|---|
| `CreateJobRecord` | Task (Lambda `database`) | First DynamoDB write for this job; sets `status: PENDING`. | Full execution input (`job_id`, `bucket`, `key`, `resolutions`). | Unchanged (ResultPath `null` discards the Lambda response). | Retry: Lambda service errors (3x, backoff 2.0). Catch `States.ALL` → `HandleProcessingFailure`. |
| `ValidateVideo` | Task (Lambda `validate`) | Format/size/duration validation against Phase 2's `ALLOWED_FORMATS`/`MAX_FILE_SIZE_BYTES`. | `job_id`, `bucket`, `key`. | Merges `{is_valid, validation_errors, file_size, format, ...}` into `$.validation`. | Retry: `TransientS3Error` (4x) + Lambda service errors (3x). Catch: `SourceObjectNotFoundError` → `HandleValidationFailure` (no retry — permanent); `States.ALL` → `HandleProcessingFailure`. |
| `IsVideoValid` | Choice | Routes on `$.validation.is_valid`. | `$.validation.is_valid`. | Unchanged. | N/A (Choice states don't fail; `Default` covers the false/missing case). |
| `HandleValidationFailure` | Task (Lambda `database`) | Records `status: FAILED`, `failure_stage: VALIDATION`, `validation_errors`. | `job_id`, `$.validation.validation_errors`. | Discarded (`ResultPath: null`). | None — always proceeds to `NotifyValidationFailure`. |
| `NotifyValidationFailure` | Task (`sns:publish`) | Phase 4: best-effort SNS notification of the validation failure. | `job_id` (via `States.Format`). | Discarded (`ResultPath: null`). | Catch `States.ALL` → `ValidationFailedState` (an SNS-side failure can't block reaching the terminal state). No Retry. |
| `ValidationFailedState` | Fail | Terminal: rejected input. | — | Execution ends with `Error: VideoValidationFailed`. | Terminal. |
| `ParallelProcessing` | Parallel | Runs thumbnail generation and metadata extraction concurrently (independent of each other). | Full state at that point. | `$.parallel_results = [thumbnail_response, metadata_response]` (each branch trimmed via `OutputPath`). | Catch `States.ALL` (either branch failing fails the whole Parallel) → `HandleProcessingFailure`. |
| &nbsp;&nbsp;↳ `GenerateThumbnail` | Task (Lambda `thumbnail`) | Generates and uploads a JPEG thumbnail. | `job_id`, `bucket`, `key`. | `$.thumbnail_response` only (via `InputPath`/`ResultPath`/`OutputPath` — see below). | Retry: Lambda service errors (3x). |
| &nbsp;&nbsp;↳ `ExtractMetadata` | Task (Lambda `metadata`) | Runs `ffprobe`, extracts duration/resolution/codecs. | `job_id`, `bucket`, `key`. | `$.metadata_response` only. | Retry: Lambda service errors (3x). |
| `RecordMediaDetails` | Task (Lambda `database`) | Persists thumbnail key + media metadata; flips `status: PROCESSING`. | `$.parallel_results[0]` (thumbnail), `$.parallel_results[1]` (metadata). | Discarded. | Retry: Lambda service errors (3x). Catch `States.ALL` → `HandleProcessingFailure`. |
| `TranscodeAllResolutions` | Map | Fans out over `$.resolutions`, one ECS Fargate task per resolution. | `$.resolutions` (array), `MaxConcurrency: 3`. | `$.transcode_results` = array of completed resolution strings. | Catch `States.ALL` (backstop for pre-iteration errors) → `HandleProcessingFailure`. |
| &nbsp;&nbsp;↳ `StaggerLaunch` | Wait | Paces concurrent `RunTask` calls so they don't all hit the ECS API simultaneously. | — | Unchanged. | N/A. |
| &nbsp;&nbsp;↳ `RunTranscodeTask` | Task (`ecs:runTask.sync`) | Runs the `video-processor` Fargate task for one resolution; blocks until the task finishes. | `job_id`, `bucket`, `key`, `resolution`, `output_bucket` (as container env vars). | Trimmed to just the resolution string (`OutputPath: "$.resolution"`). | Retry: ECS API throttling only (3x). Catch `States.ALL` (container failures, timeouts) → `RecordResolutionFailure`. `TimeoutSeconds: 1800`. |
| &nbsp;&nbsp;↳ `RecordResolutionFailure` | Task (Lambda `database`) | Fine-grained record of *which* resolution failed and why. | `job_id`, `resolution`, `$.error_info`. | Discarded. | None — always proceeds to `ResolutionFailed`. |
| &nbsp;&nbsp;↳ `ResolutionFailed` | Fail | Ends this Map iteration; with default `ToleratedFailurePercentage: 0`, fails the whole Map. | — | `Error: TranscodingFailed`. | Terminal (for the iteration; propagates to the Map's own Catch). |
| `RecordJobComplete` | Task (Lambda `database`) | Final write: `status: SUCCESS`, `resolutions_processed`. | `job_id`, `$.transcode_results`. | Discarded. | Retry: Lambda service errors (3x). Catch `States.ALL` → `HandleProcessingFailure`. |
| `BuildExecutionSummary` | Pass | Builds a compact final result instead of returning the entire accumulated state bag. | Full state. | Replaces state entirely (`ResultPath: "$"`) with `{job_id, status, resolutions_processed, thumbnail_key, duration_seconds}`. | N/A. |
| `NotifySuccess` | Task (`sns:publish`) | Phase 4: best-effort SNS notification of success. | `job_id` (via `States.Format`). | Discarded (`ResultPath: null` — the summary `BuildExecutionSummary` built is untouched). | Catch `States.ALL` → `JobSucceeded` (an SNS-side failure can't turn a successful run into a failed execution). No Retry. |
| `JobSucceeded` | Succeed | Terminal: success. | — | Execution output = `BuildExecutionSummary`'s result (unchanged by `NotifySuccess`). | Terminal. |
| `HandleProcessingFailure` | Task (Lambda `database`) | Shared handler for every post-validation failure. Records `status: FAILED`, `failure_stage: PROCESSING`, `$.error_info`. | `job_id`, `$.error_info`. | Discarded. | None — always proceeds to `NotifyProcessingFailure`. |
| `NotifyProcessingFailure` | Task (`sns:publish`) | Phase 4: best-effort SNS notification of the processing failure. | `job_id` (via `States.Format`). | Discarded (`ResultPath: null`). | Catch `States.ALL` → `ProcessingFailedState`. No Retry. |
| `ProcessingFailedState` | Fail | Terminal: pipeline failure after validation succeeded. | — | `Error: MediaProcessingFailed`. | Terminal. |

## Retry policies, explained

| Task(s) | ErrorEquals | MaxAttempts | IntervalSeconds | BackoffRate | Why |
|---|---|---|---|---|---|
| Every Lambda Task | `Lambda.ServiceException`, `Lambda.AWSLambdaException`, `Lambda.SdkClientException`, `Lambda.TooManyRequestsException` | 3 | 2 | 2.0 | AWS's own documented baseline retry for Lambda invocation plumbing failures (cold starts, throttling, SDK hiccups) — not application-level errors, which are handled by Catch instead. |
| `ValidateVideo` only | `TransientS3Error` (raised by the `validate` Lambda itself) | 4 | 1 | 2.0 | A brief S3 network blip or eventual-consistency window is worth retrying more aggressively than generic Lambda errors, since it's cheap and usually resolves within a second or two. |
| `RunTranscodeTask` only | `ECS.AmazonECSException`, `ECS.LimitExceededException` | 3 | 5 | 2.0 | Retries only failures to *launch* the Fargate task (API throttling/capacity). Deliberately does **not** retry `States.TaskFailed` (the container itself exiting non-zero, e.g. a corrupt input file) — that's a deterministic failure retrying would just waste Fargate spend re-running. |

## Catch handlers, explained

Every Catch in this state machine ultimately routes to one of two shared
handlers, each of which writes a `FAILED` DynamoDB record before ending the
execution with `Fail`:

- **`HandleValidationFailure` → `ValidationFailedState`** (`Error:
  VideoValidationFailed`) — reached only from `ValidateVideo`'s two Catch
  entries and the `IsVideoValid` Choice's `Default` branch. Represents "the
  input itself was invalid" — nothing was wrong with the pipeline.
- **`HandleProcessingFailure` → `ProcessingFailedState`** (`Error:
  MediaProcessingFailed`) — reached from `ParallelProcessing`,
  `RecordMediaDetails`, `TranscodeAllResolutions`, and `RecordJobComplete`.
  Represents "validation passed, but something in our pipeline failed."

Splitting these into two distinct terminal `Fail` states (rather than one
generic "something went wrong") means Phase 4's CloudWatch Alarms/EventBridge
rules can alert differently on them — a spike in `VideoValidationFailed` is a
user-facing/input-quality signal; a spike in `MediaProcessingFailed` is an
operational signal that the pipeline itself is broken.

Additionally, `RunTranscodeTask` has its own inner Catch
(`RecordResolutionFailure` → `ResolutionFailed`) that records *which specific
resolution* failed before that failure propagates up to the shared
`HandleProcessingFailure` handler — so both the fine-grained detail (which
resolution, what error) and the job-level terminal state are captured, not
just one or the other.

**Phase 4** inserted exactly the SNS `Publish` Task the paragraph above used
to describe as a preview: `NotifyValidationFailure` between
`HandleValidationFailure` and `ValidationFailedState`,
`NotifyProcessingFailure` between `HandleProcessingFailure` and
`ProcessingFailedState`, and (new, on the success path too)
`NotifySuccess` between `BuildExecutionSummary` and `JobSucceeded`. No
restructuring of the Catch graph above was needed — each is one more Task
in an existing chain, exactly as anticipated. Each `Notify*` state has its
own `Catch: States.ALL` routed straight to the terminal state it precedes,
deliberately with **no Retry** — a publish failure here means "we couldn't
tell anyone", not "the job failed", so there's nothing worth retrying
before falling through to the (already-correct) terminal state; retrying
would only delay reaching it.

## Timeout layering — three different things, easy to confuse

This state machine relies on timeouts enforced at three separate layers,
each catching a different kind of "stuck":

1. **Lambda function timeout** (configured in Phase 2's
   `terraform/modules/lambda`, e.g. `validate_timeout_seconds = 10`,
   `metadata_timeout_seconds = 30`) — a hard kill enforced by the Lambda
   service itself, independent of Step Functions. If the function runs
   longer than this, Lambda terminates it and returns a
   `Task Timed Out` / `Lambda.Unknown` style error.
2. **Step Functions `TimeoutSeconds`** on each Task (e.g. `ValidateVideo`:
   20s, the thumbnail/metadata branches: 45s, `RunTranscodeTask`: 1800s) —
   an *external* ceiling Step Functions enforces on top of whatever the
   underlying service is doing. This is set comfortably above the
   corresponding Lambda timeout (so Step Functions doesn't cut a function
   off before its own timeout would have) — and for the ECS task, this is
   the **only** timeout that exists at all, because:
3. **ECS/Fargate has no built-in task timeout.** A Fargate task runs until
   it exits on its own — there's nothing in ECS itself to stop a
   runaway/hung `ffmpeg` process. `RunTranscodeTask`'s
   `TimeoutSeconds: 1800` is what gives the transcoding step an upper
   bound at all: if exceeded, Step Functions calls `ecs:StopTask` on the
   state machine's behalf (which is exactly why the execution role's
   `ecs_run_task` IAM policy includes `ecs:StopTask`).

## InputPath / ResultPath / OutputPath — where and why

Rather than a single trivial example, this state machine uses the three
keywords in three genuinely different, motivated ways:

- **`ResultPath: null`** (`CreateJobRecord`, `HandleValidationFailure`,
  `RecordMediaDetails`, `RecordJobComplete`, `HandleProcessingFailure`,
  `RecordResolutionFailure`) — these are all "write-only" calls to the
  `database` Lambda whose *response* nothing downstream needs. Setting
  `ResultPath: null` discards the Lambda's return value entirely and
  passes the state's original input straight through unchanged, keeping
  the accumulated state bag from growing with data nobody uses.
- **`InputPath` + `ResultPath` + `OutputPath` together** (`GenerateThumbnail`
  and `ExtractMetadata`, inside `ParallelProcessing`) — `InputPath: "$"`
  takes the full branch input; `Parameters` narrows what's sent to the
  Lambda; `ResultPath` merges the Lambda's response into a named field;
  `OutputPath` then keeps **only** that named field as the branch's output.
  Without the final `OutputPath` trim, each Parallel branch's result would
  carry a full duplicate copy of the entire job state into
  `$.parallel_results`, doubling data for no reason. The same three-keyword
  pattern is reused in `RunTranscodeTask` — `OutputPath: "$.resolution"`
  trims each Map iteration's large ECS `RunTask` response down to just the
  resolution string that succeeded.
- **`ResultPath: "$"`** (`BuildExecutionSummary`) — the special case of
  `ResultPath` where, instead of merging a result into a named field,
  `"$"` tells Step Functions to **replace the entire state** with the
  `Parameters`-built summary object. By the time this Pass state runs, `$`
  has accumulated `$.validation`, `$.parallel_results`,
  `$.transcode_results`, and more — useful mid-execution for debugging, but
  noisy as the final execution output. `ResultPath: "$"` here is what
  produces a clean, minimal `JobSucceeded` result instead.
