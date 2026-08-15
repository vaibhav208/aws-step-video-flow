# Lambda functions

Four functions, two deployment styles, chosen per function based on whether
it needs a native binary dependency:

| Function | Dir | Deploy style | Why |
|---|---|---|---|
| `validate` | `validate/handler.py` | Zip (`archive_file`) | Pure boto3 + stdlib, no native deps |
| `database` | `database/handler.py` | Zip (`archive_file`) | Pure boto3 + stdlib, no native deps |
| `metadata` | `ffmpeg/metadata_handler.py` | Container image | Needs ffprobe (~140MB binary) |
| `thumbnail` | `ffmpeg/thumbnail_handler.py` | Container image | Needs ffmpeg (~140MB binary) |

`metadata` and `thumbnail` share **one** container image (`ffmpeg/Dockerfile`)
— two Lambda functions point at the same `image_uri` and each overrides
which module.function it runs via Terraform's `image_config.command`. See
`ffmpeg/Dockerfile`'s header comment for why this needed to become a
container image at all (a 250MB zip+layer limit vs a 140MB-per-binary
dependency).

Every function's full input/output JSON contract, the specific errors it
raises (and which of those are meant to be retried vs. caught, once Phase 3
wires up the state machine), and the reasoning behind each design choice is
documented in that function's own module docstring — read the top of each
`.py` file rather than duplicating it here.

## Environment variables

| Variable | Used by | Default |
|---|---|---|
| `ALLOWED_FORMATS` | validate | `mp4,mov,mkv,avi` |
| `MAX_FILE_SIZE_BYTES` | validate | `5368709120` (5 GiB) |
| `TABLE_NAME` | database | *(required, set by Terraform)* |
| `FFPROBE_PATH` | metadata | `/usr/local/bin/ffprobe` (baked into the image) |
| `FFMPEG_PATH` | thumbnail | `/usr/local/bin/ffmpeg` (baked into the image) |
| `PRESIGNED_URL_EXPIRY_SECONDS` | metadata, thumbnail | `300` |
| `THUMBNAIL_OFFSET_SECONDS` | thumbnail | `1` |

## Testing independently (Phase 2, before Step Functions exists)

```bash
# validate / database — no AWS resources needed beyond what's already
# deployed; invoke directly:
aws lambda invoke --function-name "$(cd terraform && terraform output -raw validate_function_name)" \
  --payload '{"job_id":"test-1","bucket":"<your-media-bucket>","key":"uploads/test-1/source.mp4"}' \
  --cli-binary-format raw-in-base64-out out.json && cat out.json

# metadata / thumbnail — same aws lambda invoke pattern, once the ffmpeg
# image has been built and pushed (scripts/build.sh lambda-image) and
# `terraform apply` has created the functions against it.
```

See the root README's "Testing Phase 2 independently" section for the full
walkthrough, including how to seed a test video into S3 first.
