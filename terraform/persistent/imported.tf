# Task 1.2 (decision 143): the pieces built by hand in the console before
# any code existed, now owned by this stack. Each resource is written to
# match what is live, so the import changes nothing but the Project tag from
# the provider's default_tags. prevent_destroy makes any plan that would
# delete one fail instead.
# The hand-made SSM parameters (CA keys, certificates, the webhook URL) are
# deliberately not here: importing a parameter copies its value into state.
# They are listed in ARCHITECTURE.md §7 with the procedure that makes each.

locals {
  # The hand-built bucket names carry the account ID as 1234-5678-9012.
  account_dashed = join("-", regexall("\\d{4}", local.account_id))
  # From the name, not the bucket resource: a pending tag change on the bucket
  # would otherwise defer the policy document to apply time and show the
  # whole policy as changing.
  flow_logs_arn = "arn:aws:s3:::mailbridge-lab-flow-logs-${local.account_dashed}"
}

# --- Terraform state ----------------------------------------------------------
# Holds this stack's state too. That's not circular: the bucket only has to
# exist before `terraform init`, and it has since 2026-11-02 (task 1.5b).
import {
  to = aws_s3_bucket.tfstate
  id = "mailbridge-lab-tfstate-v2-${local.account_dashed}"
}

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Access logs would need a second bucket; CloudTrail records every change to this one's configuration.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles cost; versioning keeps every earlier state.
  #checkov:skip=CKV_AWS_145:SSE-S3; a customer-managed KMS key costs $1/month and adds no control while one admin owns the account.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object-created events.
  #checkov:skip=CKV2_AWS_61:No lifecycle on purpose: every noncurrent state version is kept as the history of the infrastructure, and they are a few KB each.
  bucket = "mailbridge-lab-tfstate-v2-${local.account_dashed}"

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = aws_s3_bucket_versioning.tfstate
  id = aws_s3_bucket.tfstate.id
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.tfstate
  id = aws_s3_bucket.tfstate.id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

import {
  to = aws_s3_bucket_public_access_block.tfstate
  id = aws_s3_bucket.tfstate.id
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

import {
  to = aws_s3_bucket_ownership_controls.tfstate
  id = aws_s3_bucket.tfstate.id
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- VPC flow logs --------------------------------------------------------------
# lab's flow log writes here (flow_log_bucket_arn in lab's tfvars), so the
# records outlive every teardown.
import {
  to = aws_s3_bucket.flow_logs
  id = "mailbridge-lab-flow-logs-${local.account_dashed}"
}

resource "aws_s3_bucket" "flow_logs" {
  #checkov:skip=CKV_AWS_18:Access logs would need a second bucket; CloudTrail records every change to this one's configuration.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles cost for 30-day lab records.
  #checkov:skip=CKV_AWS_145:SSE-S3; a customer-managed KMS key costs $1/month and adds no control while one admin owns the account.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object-created events.
  #checkov:skip=CKV_AWS_21:Unversioned as built: only the log delivery service writes, objects are never overwritten, and they expire after 30 days anyway.
  bucket = "mailbridge-lab-flow-logs-${local.account_dashed}"

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.flow_logs
  id = aws_s3_bucket.flow_logs.id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

import {
  to = aws_s3_bucket_public_access_block.flow_logs
  id = aws_s3_bucket.flow_logs.id
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

import {
  to = aws_s3_bucket_ownership_controls.flow_logs
  id = aws_s3_bucket.flow_logs.id
}

resource "aws_s3_bucket_ownership_controls" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

import {
  to = aws_s3_bucket_lifecycle_configuration.flow_logs
  id = aws_s3_bucket.flow_logs.id
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  #checkov:skip=CKV_AWS_300:The log delivery service writes each record in one PUT, so there are no multipart uploads to abort.
  bucket                                 = aws_s3_bucket.flow_logs.id
  transition_default_minimum_object_size = "all_storage_classes_128K"

  rule {
    id     = "expire-30-days"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# The policy the console wrote when the flow log was created: only the log
# delivery service, only for this account's log groups (aws:SourceAccount
# and aws:SourceArn stop another account's delivery using the bucket).
data "aws_iam_policy_document" "flow_logs_bucket" {
  policy_id = "AWSLogDeliveryWrite20150319"

  statement {
    sid       = "AWSLogDeliveryWrite1"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.flow_logs_arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:eu-central-1:${local.account_id}:*"]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck1"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.flow_logs_arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:eu-central-1:${local.account_id}:*"]
    }
  }
}

import {
  to = aws_s3_bucket_policy.flow_logs
  id = aws_s3_bucket.flow_logs.id
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_bucket.json
}

# --- Route 53 zone --------------------------------------------------------------
# The delegated subdomain (TASKS: "Delegate the subdomain"). lab still finds
# it by name with a data source, so nothing in lab changes.
data "aws_route53_zone" "lab" {
  name = var.domain
}

import {
  to = aws_route53_zone.lab
  id = data.aws_route53_zone.lab.zone_id
}

resource "aws_route53_zone" "lab" {
  #checkov:skip=CKV2_AWS_38:DNSSEC signing needs a KMS key ($1/month) and a DS record at the parent; not in scope for the lab.
  #checkov:skip=CKV2_AWS_39:Query logging goes to CloudWatch Logs (billed per GB); flow logs and CloudTrail cover the lab.
  name    = var.domain
  comment = "Mailbridge lab, delegated subdomain"

  lifecycle {
    prevent_destroy = true
  }
}
