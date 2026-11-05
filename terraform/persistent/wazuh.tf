# Wazuh's persistent pieces (task 1.16, decisions 88 and 89). The siem host
# itself lives in lab and is rebuilt every session.

# The indexer's data, kept across sessions (decision 88). lab attaches it to
# each session's siem host and owns only the attachment. Must be in the mgmt
# subnet's Availability Zone; lab checks that before attaching.
resource "aws_ebs_volume" "wazuh_data" {
  #checkov:skip=CKV_AWS_189:Encrypted with the AWS-managed aws/ebs key; a customer-managed key costs $1/month and adds no control while one admin owns the account, as for the SSM parameters.
  availability_zone = "eu-central-1a"
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "mailbridge-lab-wazuh-data"
    Role = "siem-data"
  }

  # A destroy of this stack must fail rather than delete the SIEM's history.
  lifecycle {
    prevent_destroy = true
  }
}

# The indexer's internal users (decision 89). The dashboard logs in to the
# indexer as kibanaserver. Letters and digits only, like the DB passwords;
# the siem role hashes them into the indexer's internal_users.yml.
ephemeral "random_password" "wazuh_indexer_admin" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "wazuh_indexer_admin" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/siem/indexer-admin-password"
  description      = "Wazuh indexer internal user admin"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.wazuh_indexer_admin.result
  value_wo_version = 1
}

ephemeral "random_password" "wazuh_kibanaserver" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "wazuh_kibanaserver" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/siem/kibanaserver-password"
  description      = "Wazuh indexer internal user kibanaserver, used by the dashboard"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.wazuh_kibanaserver.result
  value_wo_version = 1
}

# The Wazuh API's users. The API rejects a password without an upper-case
# letter, a lower-case letter, a digit and one of .*+?- so these use that
# set and minimums. 40 characters are still about 230 bits.
ephemeral "random_password" "wazuh_api_wazuh" {
  length           = 40
  special          = true
  override_special = ".*+?-"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_ssm_parameter" "wazuh_api_wazuh" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/siem/api-wazuh-password"
  description      = "Wazuh API user wazuh"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.wazuh_api_wazuh.result
  value_wo_version = 1
}

ephemeral "random_password" "wazuh_api_wazuh_wui" {
  length           = 40
  special          = true
  override_special = ".*+?-"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_ssm_parameter" "wazuh_api_wazuh_wui" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/siem/api-wazuh-wui-password"
  description      = "Wazuh API user wazuh-wui, used by the dashboard"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.wazuh_api_wazuh_wui.result
  value_wo_version = 1
}

# The agents' enrollment password (task 1.17, decision 100). siem's authd
# requires it, and each agent host may read this one parameter to enroll.
ephemeral "random_password" "wazuh_agent_enrollment" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "wazuh_agent_enrollment" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/siem/agent-enrollment-password"
  description      = "Wazuh authd enrollment password, read by siem and the agent hosts"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.wazuh_agent_enrollment.result
  value_wo_version = 1
}
