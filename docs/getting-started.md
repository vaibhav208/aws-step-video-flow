# Getting Started — Redeploying AWS-Step-video-Flow From Scratch

This is a step-by-step checklist to bring the **entire** project (Phases 1-6:
S3, DynamoDB, IAM, networking, ECR/ECS, 6 Lambda functions, Step Functions,
EventBridge, SNS, CloudWatch, and the web frontend) back up after running
`terraform destroy`. It's a condensed, linear version of the deploy
instructions spread across `README.md` sections 6-31 — read this when you
just want the commands in order, and go back to `README.md` for the "why"
behind any step.

Everything below assumes you're running from the repo root on your WSL/Linux
machine, with Docker running and AWS credentials configured.

## 0. Before you start

- [ ] Confirm you actually want to redeploy — this creates real AWS
      resources (S3, DynamoDB, ECR, ECS/Fargate, Lambda, Step Functions,
      EventBridge, SNS, CloudWatch, API Gateway). Nothing here is free
      forever at rest, though most of it is pennies/month — see
      `README.md` sections 10, 15, 19, 23, 27, 31 for a full cost
      breakdown per phase.
- [ ] Confirm your AWS CLI is pointed at the right account/region:

  ```bash
  aws sts get-caller-identity
  ```

  This project was last deployed to account `258325252965`, region
  `us-east-1`.

## 1. Prerequisites (one-time, skip if already installed)

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured (`aws configure` or SSO profile)
- Docker (running — needed to build/push two container images)
- Python 3.12 + `pip` (only if you want to run unit tests locally)
- `jq` (used by a few verification commands below)

## 2. Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `owner` — set to your name/tag
- `aws_region` — leave as `us-east-1` unless you want to change it
- `notification_email` — optional; set this if you want SNS to email you
  on job success/failure (leave blank if you don't need it)

## 3. Init Terraform

```bash
terraform init
terraform fmt -recursive
terraform validate
```

## 4. Bootstrap step 1 — create the (empty) ECR repos first

The two container-image Lambda functions (`metadata`, `thumbnail`) and the
ECS task definition reference images that don't exist yet, so the **very
first** apply after a full destroy needs the ECR repos created before
anything tries to reference an image inside them:

```bash
terraform apply \
  -target=module.ecs.aws_ecr_repository.video_processor \
  -target=module.lambda.aws_ecr_repository.lambda_ffmpeg
```

## 5. Build and push the two Docker images

```bash
cd ..
scripts/build.sh all
```

This builds and pushes both images:

- the shared `ffmpeg` image (used by the `metadata` and `thumbnail` Lambda
  functions) — first build is slow, it downloads a ~130MB static ffmpeg
  binary
- the `video-processor` image (used by the ECS Fargate task)

## 6. Apply everything else

```bash
cd terraform
terraform apply
```

This single apply now creates **all six phases** in one pass: S3, DynamoDB,
IAM roles, VPC/networking, the 6 Lambda functions, Step Functions state
machine, EventBridge rule + trigger Lambda, SNS topic, CloudWatch
alarms/dashboard, and the Phase 6 web frontend (API Gateway + `web_api`
Lambda + S3 static website). Review the plan, then type `yes`.

No further bootstrap dance is needed after this — every phase after Phase 2
only references resources that already exist by the time Terraform gets to
it (no chicken-and-egg problems like the ECR one above).

## 7. Grab the important outputs

```bash
terraform output
```

Save these — you'll use them constantly:

```bash
MEDIA_BUCKET=$(terraform output -raw media_bucket_name)
SFN_ARN=$(terraform output -raw state_machine_arn)
FRONTEND_URL=$(terraform output -raw web_frontend_url)
API_URL=$(terraform output -raw web_api_invoke_url)
DASHBOARD_URL=$(terraform output -raw cloudwatch_dashboard_url)
```

## 8. Quick smoke-test that everything came up healthy

```bash
# Lambda functions are all Active
for fn in validate_function_name database_function_name metadata_function_name \
          thumbnail_function_name trigger_function_name web_api_function_name; do
  aws lambda get-function --function-name "$(terraform output -raw $fn)" \
    --query 'Configuration.{Name:FunctionName,State:State}'
done

# State machine is ACTIVE
aws stepfunctions describe-state-machine --state-machine-arn "$SFN_ARN" \
  --query '{Name:name,Status:status}'

# Frontend bucket serves the page
curl -s -o /dev/null -w '%{http_code}\n' "$FRONTEND_URL"

# API Gateway -> Lambda chain is wired (expect a 404 JSON body from the
# Lambda's own router, which confirms the whole chain works)
curl -s "$API_URL/nope"
```

## 9. Run the pipeline — three ways, pick any

**A. Through the web frontend (easiest, visual):**

```bash
echo "$FRONTEND_URL"
```

Open that URL in a browser, choose a video file, click **Start
Processing**, and watch the state diagram light up live.

**B. Automatic — just upload to S3:**

```bash
aws s3 cp your-test-video.mp4 "s3://${MEDIA_BUCKET}/uploads/job-manual-0001/source.mp4"

aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
  --query 'executions[?name==`job-manual-0001`]'
```

Or use the wrapper script, which uploads and polls for you:

```bash
scripts/upload-test-video.sh your-test-video.mp4 job-manual-0002
```

**C. Manual `start-execution` (lets you pick non-default resolutions):**

```bash
aws s3 cp your-test-video.mp4 "s3://${MEDIA_BUCKET}/uploads/job-demo-0001/source.mp4"
# edit step-functions/sample-input.json: set "bucket" to $MEDIA_BUCKET
aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "manual-test-$(date +%s)" \
  --input file://step-functions/sample-input.json
```

Watch any of these run in the Step Functions console, or via
`aws stepfunctions describe-execution`, or on the CloudWatch dashboard:

```bash
echo "$DASHBOARD_URL"
```

## 10. Run the local test suite (optional, no AWS cost)

```bash
pip install -r tests/lambda/requirements-test.txt
pytest tests/lambda/ -v

pip install -r tests/video-processor/requirements-test.txt
pytest tests/video-processor/ -v
```

## 11. Tearing it back down later

```bash
scripts/deploy.sh destroy
# or: cd terraform && terraform destroy
```

`s3_force_destroy = true` (the default in `terraform.tfvars.example`) lets
this delete the media bucket even if it still has test objects in it.

---

### If something doesn't come up clean

Check `docs/troubleshooting.md` first — it's a symptom-first reference
covering issues seen across every phase of this project (including the
`src_dir` path-resolution bug and the DynamoDB float/Decimal bug that were
only ever caught on a real `terraform apply`, not in validation).
