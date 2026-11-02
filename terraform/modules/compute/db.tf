# db: PostgreSQL in the data subnet (ARCHITECTURE.md §3, task 1.13).

# Same trust policy and SSM baseline as fw-ips (decision 22).
resource "aws_iam_role" "db" {
  name               = "${var.name}-db"
  description        = "db instance role: SSM agent, and reads the two DB passwords only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "db_ssm_min" {
  role       = aws_iam_role.db.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# db pulls its own passwords on the host, so the values never pass through
# the laptop or Ansible output (decision 47): the owner's and the runtime
# role's (decision 54). Exact ARNs, no wildcard: the other /mailbridge/*
# secrets belong to app. The aws/ssm key needs no grant here; its key policy
# allows use through SSM by principals IAM allows.
data "aws_iam_policy_document" "db_password" {
  statement {
    sid     = "ReadDbPasswords"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/mailbridge/db-password",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/mailbridge/db-app-password",
    ]
  }
}

resource "aws_iam_role_policy" "db_password" {
  name   = "db-read-db-password"
  role   = aws_iam_role.db.id
  policy = data.aws_iam_policy_document.db_password.json
}

resource "aws_iam_instance_profile" "db" {
  name = "${var.name}-db"
  role = aws_iam_role.db.name
}

resource "aws_instance" "db" {
  count = var.hosts_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in Tier 2.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.db_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.db.name
  ebs_optimized          = true
  subnet_id              = var.db_subnet_id
  private_ip             = var.db_private_ip
  vpc_security_group_ids = [var.db_security_group_id]

  # Cost guardrail: no surplus credits are billed.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only, hop limit 1, as on fw-ips.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Rebuilt empty every session until T2.3 brings backups (decision 49).
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    # Lets the end-of-session check find a leftover volume by tag.
    tags = {
      Name    = "${var.name}-db-root"
      Project = var.name
    }
  }

  # No network at first boot: fw-ips forwards nothing until its role has
  # run, so this only writes the HTTPS mirror config (a local file). The db
  # role upgrades the host once Ansible can reach it (decision 50).
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

  # Role is the Ansible group (decision 45).
  tags = {
    Name    = "${var.name}-db"
    Project = var.name
    Role    = "db"
  }
}
