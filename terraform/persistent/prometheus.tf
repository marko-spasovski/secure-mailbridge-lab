# mon's persistent piece (task 1.22, decision 109). The mon host itself lives
# in lab and is rebuilt every session.

# Prometheus's time series, kept across sessions so Juice Shop runs from
# different sessions can be compared. lab attaches it to each session's mon
# host and owns only the attachment. Must be in the mgmt subnet's
# Availability Zone; lab checks that before attaching.
resource "aws_ebs_volume" "prometheus_data" {
  #checkov:skip=CKV_AWS_189:Encrypted with the AWS-managed aws/ebs key, as for the Wazuh volume.
  availability_zone = "eu-central-1a"
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "mailbridge-lab-prometheus-data"
    Role = "mon-data"
  }

  # A destroy of this stack must fail rather than delete the metric history.
  lifecycle {
    prevent_destroy = true
  }
}

# Grafana's local admin password (decision 112). Letters and digits only,
# like the DB passwords; mon reads /mon/* and the mon role's helper sets it
# with a test login first, so it's idempotent.
ephemeral "random_password" "grafana_admin" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "grafana_admin" {
  #checkov:skip=CKV_AWS_337:The AWS-managed aws/ssm key, as for /mailbridge/db-password.
  name             = "/mon/grafana-admin-password"
  description      = "Grafana local admin password, read by mon"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.grafana_admin.result
  value_wo_version = 1
}
