# Created once and never destroyed with the lab (ARCHITECTURE.md §13).
# Task 1.2 adds the hand-built pieces here one at a time.

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = { Project = "mailbridge-lab" }
  }
}

# Generated in memory during the run and never written to state or a plan
# (decision 46). Letters and digits only, so it needs no escaping in a
# connection string; 40 of them are about 238 bits.
ephemeral "random_password" "db" {
  length  = 40
  special = false
}

# The value is write-only: Terraform sends it to SSM and keeps only the
# version. It is sent on create and again only when the version changes,
# so bump value_wo_version to rotate. db and app read it with their own
# instance roles (decision 39 pattern).
resource "aws_ssm_parameter" "db_password" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /vpn/*; a customer-managed key costs $1/month and adds no control while one admin owns the account.
  name             = "/mailbridge/db-password"
  description      = "PostgreSQL password for the Mailbridge app user"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.db.result
  value_wo_version = 1
}

# The app's runtime database role (decision 54). Same format as the owner's,
# which set-db-password on db relies on.
ephemeral "random_password" "db_app" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "db_app_password" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/mailbridge/db-app-password"
  description      = "PostgreSQL password for mailbridge_app, the app's runtime role"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.db_app.result
  value_wo_version = 1
}

# The app takes these as raw text, at least 32 characters, and the two must
# differ (Mailbridge docs/deployment.md). 64 letters and digits are about
# 380 bits each, generated independently.
ephemeral "random_password" "session_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "session_secret" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/mailbridge/session-secret"
  description      = "Signs Mailbridge session cookies"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.session_secret.result
  value_wo_version = 1
}

# Encrypts stored mailbox OAuth tokens. A new value makes existing tokens
# unreadable, so users reconnect their mailboxes after a rotation.
ephemeral "random_password" "token_encryption_key" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "token_encryption_key" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/mailbridge/token-encryption-key"
  description      = "Encrypts Mailbridge's stored mailbox OAuth tokens"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.token_encryption_key.result
  value_wo_version = 1
}
