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
