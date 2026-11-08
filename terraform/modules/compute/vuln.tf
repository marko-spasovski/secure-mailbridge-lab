# vuln: OWASP Juice Shop in Docker in its own subnet (ARCHITECTURE.md §3,
# task 2.10, decisions 67 to 69, 74, 129). Exists only with vuln_enabled.

resource "aws_iam_role" "vuln" {
  name               = "${var.name}-vuln"
  description        = "vuln instance role: SSM agent, pulls the juice-shop ECR image, Wazuh enrollment password"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "vuln_ssm_min" {
  role       = aws_iam_role.vuln.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# Juice Shop has no secrets, so unlike app there's no SSM path here: an RCE
# that reaches the instance role finds only an image it already runs.
data "aws_iam_policy_document" "vuln" {
  # AWS only accepts * here; the pull statement decides what it can read.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullJuiceShopImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.vuln_ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "vuln" {
  name   = "vuln-image"
  role   = aws_iam_role.vuln.id
  policy = data.aws_iam_policy_document.vuln.json
}

resource "aws_iam_instance_profile" "vuln" {
  name = "${var.name}-vuln"
  role = aws_iam_role.vuln.name
}

resource "aws_instance" "vuln" {
  count = var.hosts_enabled && var.vuln_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.vuln_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.vuln.name
  ebs_optimized          = true
  subnet_id              = var.vuln_subnet_id
  private_ip             = var.vuln_private_ip
  vpc_security_group_ids = [var.vuln_security_group_id]

  # Cost guardrail.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only. Hop limit 1: the container is one hop further away, so it
  # can't reach the instance role's credentials (decision 69).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name    = "${var.name}-vuln-root"
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
    Name    = "${var.name}-vuln"
    Project = var.name
    Role    = "vuln"
  }
}
