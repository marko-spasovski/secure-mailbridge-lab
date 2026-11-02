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
