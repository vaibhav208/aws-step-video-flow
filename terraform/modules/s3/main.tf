# ---------------------------------------------------------------------------
# Media bucket
#
# A single bucket holds the whole pipeline's data, separated by key prefix
# rather than by bucket, per the project spec:
#
#   uploads/<job_id>/<original filename>       - raw source videos
#   processed/<job_id>/<resolution>/video.mp4  - transcoded outputs
#   thumbnails/<job_id>/thumbnail.jpg          - generated thumbnails
#   metadata/<job_id>/metadata.json            - extracted metadata (optional
#                                                 mirror of what's in DynamoDB)
#
# One bucket keeps IAM policies and lifecycle rules simple to reason about
# for a learning project; a stricter production setup might split
# uploads/processed into separate buckets so retention and access policies
# can diverge further. S3 prefixes are not real folders — they're just the
# left-hand side of the object key — so no "folder" resources are created
# here, only the convention documented above and enforced by the Lambda /
# ECS code in later phases.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "media" {
  bucket        = "${var.name_prefix}-media-${var.account_id}"
  force_destroy = var.force_destroy

  tags = var.tags
}

# Versioning protects against accidental overwrite/delete of source videos
# and outputs, and is a prerequisite for lifecycle rules that expire
# *noncurrent* versions (as opposed to current objects).
resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# Default server-side encryption (SSE-S3 / AES256). This costs nothing extra
# and requires no key management, unlike SSE-KMS — appropriate for a
# learning project. Swap to aws:kms here if you need customer-managed keys
# and audit trails on key usage.
resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block every public access vector. Nothing in this architecture serves
# video directly out of S3 to the public internet — outputs are fetched via
# the API/pre-signed URLs in later phases — so there is no reason to allow
# any public ACL or bucket policy.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cost controls:
#  - abort-incomplete-multipart: reclaims storage from multipart uploads
#    (e.g. a browser upload that was interrupted) that never completed.
#  - expire-noncurrent-versions: without this, versioning silently keeps
#    every prior version of every object forever, including every
#    transcoded output re-run, which adds up fast on video-sized objects.
resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = var.enable_versioning ? "Enabled" : "Disabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

# CORS: needed once the Phase 5 API issues pre-signed PUT URLs for browser
# uploads. Harmless to enable now since it only affects browser-originated
# requests, not server-to-server access. Restrict cors_allowed_origins to
# your real frontend origin outside of local learning/demo use.
resource "aws_s3_bucket_cors_configuration" "media" {
  count  = var.enable_cors ? 1 : 0
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# Flip on EventBridge notifications for this bucket. This alone doesn't
# create any rule or target — that's Phase 4's eventbridge module — but the
# bucket-side setting has to exist before an EventBridge rule can match
# "Object Created" events from it, so it's enabled here alongside the
# bucket itself.
resource "aws_s3_bucket_notification" "eventbridge" {
  bucket      = aws_s3_bucket.media.id
  eventbridge = true
}
