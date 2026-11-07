# mon: Prometheus, Grafana and Alertmanager in the mgmt subnet (ARCHITECTURE.md
# §3, task 1.22, decisions 84 and 108 to 110). Configured by the mon Ansible
# role.

resource "aws_iam_role" "mon" {
  name               = "${var.name}-mon"
  description        = "mon instance role: SSM agent, the Wazuh enrollment password and /mon/* only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "mon_ssm_min" {
  role       = aws_iam_role.mon.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# mon's own secrets (decision 112): Grafana's admin password and certificate,
# later the Discord webhook URL. Only this path; account and region named, as
# in decision 43. Nothing else may ever be stored under /mon/.
data "aws_iam_policy_document" "mon_params" {
  statement {
    sid       = "ReadMonParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/mon/*"]
  }
}

resource "aws_iam_role_policy" "mon_params" {
  name   = "mon-read-mon-parameters"
  role   = aws_iam_role.mon.id
  policy = data.aws_iam_policy_document.mon_params.json
}

resource "aws_iam_instance_profile" "mon" {
  name = "${var.name}-mon"
  role = aws_iam_role.mon.name
}

resource "aws_instance" "mon" {
  count = var.hosts_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in 1.23.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.mon_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.mon.name
  ebs_optimized          = true
  subnet_id              = var.mon_subnet_id
  private_ip             = var.mon_private_ip
  vpc_security_group_ids = [var.mon_security_group_id]

  # Cost guardrail.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Packages and logs only; Prometheus's data is on its own volume.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name    = "${var.name}-mon-root"
      Project = var.name
    }
  }

  # Same as db: only the HTTPS mirror at first boot (decision 50).
  user_data = <<-EOT
    #cloud-config
    apt:
      primary:
        - arches: [default]
          uri: https://eu-central-1.ec2.archive.ubuntu.com/ubuntu/
      security:
        - arches: [default]
          uri: https://eu-central-1.ec2.archive.ubuntu.com/ubuntu/
  EOT

  tags = {
    Name    = "${var.name}-mon"
    Project = var.name
    Role    = "mon"
  }
}

# The persistent data volume (decision 109), handled like siem's: the
# instance is stopped before detaching, so Prometheus shuts down cleanly and
# its data is flushed; the volume itself is never touched by lab.
resource "aws_volume_attachment" "mon_data" {
  count = var.hosts_enabled ? 1 : 0

  device_name                    = "/dev/sdf"
  volume_id                      = var.mon_data_volume_id
  instance_id                    = aws_instance.mon[0].id
  stop_instance_before_detaching = true

  lifecycle {
    precondition {
      condition     = var.mon_data_volume_az == aws_instance.mon[0].availability_zone
      error_message = "The Prometheus data volume and the mon host must be in the same Availability Zone."
    }
  }
}
