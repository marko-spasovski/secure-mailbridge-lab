# CloudTrail (task 1.18, decision 140): every management API call in the
# account, in every region, kept in its own bucket. It lives in persistent so
# it records between sessions too, when nobody is watching, and a lab
# teardown can't stop it.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  trail_name = "mailbridge-lab"
  # Built from parts, not read from the trail, so the bucket policy (which the
  # trail depends on) can name it without a cycle.
  trail_arn = "arn:aws:cloudtrail:eu-central-1:${local.account_id}:trail/${local.trail_name}"
}

resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_18:Access logs for the audit-log bucket would need another bucket of their own; CloudTrail itself records who changes this bucket's policy or deletes it.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage for a lab; the digest files prove integrity instead.
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES-256); a customer-managed KMS key costs $1/month and adds no control while one admin owns the account.
  #checkov:skip=CKV2_AWS_62:No consumer for object-created events; the logs are read on demand.
  bucket = "mailbridge-lab-cloudtrail-${local.account_id}"
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# An overwritten or deleted log file stays recoverable as a noncurrent
# version until the lifecycle below removes it.
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-after-90-days"
    status = "Enabled"
    filter {}

    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.cloudtrail]
}

# Only CloudTrail may write, only for this trail (aws:SourceArn stops another
# account's trail from using the bucket: the confused deputy), only under this
# account's prefix; nothing reaches it without TLS.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "DenyWithoutTls"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

# Management events only: the first copy of them in a trail is free, data
# events (every S3 object read) are billed. Log file validation writes a
# signed digest every hour, so `aws cloudtrail validate-logs` can prove no
# log was changed or deleted afterwards.
resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV_AWS_35:SSE-S3 on the bucket; a KMS key costs $1/month and adds no control while one admin owns the account.
  #checkov:skip=CKV_AWS_252:No SNS topic: nothing subscribes to new-file notices.
  #checkov:skip=CKV2_AWS_10:No CloudWatch Logs copy (billed per GB); the logs are read from S3.
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
