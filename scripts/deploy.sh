#!/usr/bin/env bash
#
# Thin wrapper around terraform for this project. Phase 1 only manages the
# terraform/ root module (S3, DynamoDB, IAM); later phases add more
# resources to the same root module, so this script doesn't need to change
# as the project grows.
#
# Usage:
#   scripts/deploy.sh init      # terraform init
#   scripts/deploy.sh plan      # terraform plan
#   scripts/deploy.sh apply     # terraform apply
#   scripts/deploy.sh destroy   # terraform destroy
#   scripts/deploy.sh output    # terraform output
#   scripts/deploy.sh fmt       # terraform fmt -recursive
#   scripts/deploy.sh validate  # terraform validate
#
# Env vars:
#   TF_DIR   - path to the terraform root module (default: terraform)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../terraform}"
ACTION="${1:-}"

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 {init|plan|apply|destroy|output|fmt|validate}" >&2
  exit 1
fi

cd "$TF_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "No terraform.tfvars found in $TF_DIR."
  echo "Copy terraform.tfvars.example to terraform.tfvars and adjust values first:"
  echo "  cp terraform.tfvars.example terraform.tfvars"
  exit 1
fi

case "$ACTION" in
  init)
    terraform init
    ;;
  fmt)
    terraform fmt -recursive
    ;;
  validate)
    terraform validate
    ;;
  plan)
    terraform plan
    ;;
  apply)
    terraform apply
    ;;
  destroy)
    echo "This will destroy every resource this project's Terraform manages."
    read -r -p "Type 'destroy' to confirm: " confirm
    if [[ "$confirm" == "destroy" ]]; then
      terraform destroy
    else
      echo "Aborted."
      exit 1
    fi
    ;;
  output)
    terraform output
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    echo "Usage: $0 {init|plan|apply|destroy|output|fmt|validate}" >&2
    exit 1
    ;;
esac
