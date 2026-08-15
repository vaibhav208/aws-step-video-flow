# api

**Status:** Deliberately not built.

This was scoped as an *optional* Phase 5 addition — a thin FastAPI service
exposing `POST /videos`, `GET /jobs/{id}`, `GET /jobs/{id}/status`,
`POST /jobs/{id}/cancel`, `GET /jobs/{id}/outputs`, as a REST alternative
to using the AWS CLI directly.

Phase 5 chose to spend its scope on CI/CD, real execution-based tests
(`tests/step-functions/`), and documentation instead, and to leave this
directory unbuilt rather than add a REST layer whose only job would be
thinly wrapping calls this project already documents directly against AWS
(`aws s3 cp`, `aws stepfunctions start-execution`,
`aws dynamodb get-item` — see the root README's "Starting an execution"
and "Testing the automatic trigger" sections). For a demonstration project
about Step Functions orchestration specifically, that wrapper wouldn't
teach or exercise anything the state machine, Lambda functions, and tests
don't already cover — the AWS CLI commands throughout this README *are*
the API surface this project is demonstrating.

If you want to build it anyway: every ARN/name it would need is already a
Terraform output (`terraform output`), and every operation it would expose
already has a documented, tested AWS CLI equivalent to wrap — `start`
calls `aws stepfunctions start-execution` after an S3 upload, `status`
calls `describe-execution` and/or reads the DynamoDB job record directly
(same shape documented in `docs/architecture.md`'s "DynamoDB item shape"),
`cancel` calls `stop-execution`, `outputs` returns presigned S3 URLs for
the `processed/`/`thumbnails/` keys already recorded in that same
DynamoDB item.
