terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # PHASE 1 NOTE: state is local (terraform.tfstate in this directory) to keep the
  # learning project zero-cost and zero-setup. For a real team project, replace this
  # with an S3 + DynamoDB remote backend (see docs/deployment.md, added in a later
  # phase). Example:
  #
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "video-pipeline/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
