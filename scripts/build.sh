#!/usr/bin/env bash
#
# Build and push the two container images this project needs. Both images
# go to ECR repos created by Phase 2's Terraform (module.ecs and
# module.lambda), which start out EMPTY — so the very first deploy needs:
#
#   1. terraform apply -target=module.ecs.aws_ecr_repository.video_processor \
#                       -target=module.lambda.aws_ecr_repository.lambda_ffmpeg
#   2. scripts/build.sh image
#   3. scripts/build.sh lambda-image
#   4. terraform apply        # now the task definition / image-based
#                              # Lambda functions can find real images
#
# After that first bootstrap, just re-run the relevant build.sh subcommand
# to push a new version — the task definition/Lambda functions read
# ":latest" by default, so ECS/Lambda will pick up the new image on their
# next invocation without a further `terraform apply` (unless you've pinned
# a specific tag via container_image / ffmpeg_image_uri).
#
# Usage:
#   scripts/build.sh image          # video-processor -> ECS ECR repo
#   scripts/build.sh lambda-image   # metadata+thumbnail -> Lambda ECR repo
#   scripts/build.sh all            # both, in order
#
# Env vars:
#   TF_DIR   - path to the terraform root module (default: terraform)
#   TAG      - image tag to push, in addition to :latest (default: git sha
#              if available, else "manual")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform}"
ACTION="${1:-}"

TAG="${TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo manual)}"

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

aws_region() {
  tf_output aws_region
}

ecr_login() {
  local repo_url="$1"
  local registry
  registry="${repo_url%%/*}"
  aws ecr get-login-password --region "$(aws_region)" \
    | docker login --username AWS --password-stdin "$registry"
}

build_video_processor() {
  local repo_url
  repo_url="$(tf_output ecr_video_processor_repository_url)"

  echo "Building video-processor image from $REPO_ROOT/src/video-processor ..."
  docker build -t "${repo_url}:${TAG}" -t "${repo_url}:latest" "$REPO_ROOT/src/video-processor"

  ecr_login "$repo_url"

  echo "Pushing ${repo_url}:${TAG} and :latest ..."
  docker push "${repo_url}:${TAG}"
  docker push "${repo_url}:latest"

  echo "Done. ECS will use this the next time Step Functions RunTask starts a task."
}

build_lambda_image() {
  local repo_url
  repo_url="$(tf_output ecr_lambda_ffmpeg_repository_url)"

  echo "Building shared metadata/thumbnail Lambda image from $REPO_ROOT/src/lambda/ffmpeg ..."
  echo "(This downloads a ~130MB ffmpeg static build during the Docker build — first build is slow.)"
  docker build -t "${repo_url}:${TAG}" -t "${repo_url}:latest" "$REPO_ROOT/src/lambda/ffmpeg"

  ecr_login "$repo_url"

  echo "Pushing ${repo_url}:${TAG} and :latest ..."
  docker push "${repo_url}:${TAG}"
  docker push "${repo_url}:latest"

  echo "Done. Run 'aws lambda update-function-code --function-name <metadata|thumbnail> --image-uri ${repo_url}:latest'"
  echo "if the functions already exist and need to pick up this new image immediately"
  echo "(otherwise they'll use whatever image_uri Terraform set them to)."
}

case "$ACTION" in
  image)
    build_video_processor
    ;;
  lambda-image)
    build_lambda_image
    ;;
  all)
    build_video_processor
    build_lambda_image
    ;;
  *)
    echo "Usage: $0 {image|lambda-image|all}" >&2
    exit 1
    ;;
esac
