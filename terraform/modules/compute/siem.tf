# siem: Wazuh all-in-one in the mgmt subnet (ARCHITECTURE.md §3, task 1.16,
# decisions 85 to 89). Configured by the siem Ansible role.

resource "aws_iam_role" "siem" {
  name               = "${var.name}-siem"
  description        = "siem instance role: SSM agent, and reads /siem/* only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "siem_ssm_min" {
  role       = aws_iam_role.siem.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# Wazuh's passwords and certificates (decision 89). Only this path: no
# /mailbridge/* and no /vpn/*. Account and region named, as in decision 43.
data "aws_iam_policy_document" "siem_params" {
  statement {
    sid       = "ReadSiemParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/siem/*"]
  }
}

resource "aws_iam_role_policy" "siem_params" {
  name   = "siem-read-siem-parameters"
  role   = aws_iam_role.siem.id
  policy = data.aws_iam_policy_document.siem_params.json
}

resource "aws_iam_instance_profile" "siem" {
  name = "${var.name}-siem"
  role = aws_iam_role.siem.name
}

resource "aws_instance" "siem" {
  count = var.hosts_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in 1.23.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.siem_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.siem.name
  ebs_optimized          = true
  subnet_id              = var.siem_subnet_id
  private_ip             = var.siem_private_ip
  vpc_security_group_ids = [var.siem_security_group_id]

  # Cost guardrail. A new instance starts with no credits, so the first
  # Wazuh install runs at the 20 % baseline (decision 87).
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Packages and logs only; the indexer's data is on its own volume.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name    = "${var.name}-siem-root"
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
    Name    = "${var.name}-siem"
    Project = var.name
    Role    = "siem"
  }
}

# The persistent data volume (decision 88). Terraform stops the instance
# before detaching, so the OS shuts the indexer down cleanly and its data is
# flushed; the volume itself is never touched by lab.
resource "aws_volume_attachment" "siem_data" {
  count = var.hosts_enabled ? 1 : 0

  device_name                    = "/dev/sdf"
  volume_id                      = var.siem_data_volume_id
  instance_id                    = aws_instance.siem[0].id
  stop_instance_before_detaching = true

  lifecycle {
    precondition {
      condition     = var.siem_data_volume_az == aws_instance.siem[0].availability_zone
      error_message = "The Wazuh data volume and the siem host must be in the same Availability Zone."
    }
  }
}
