# app: Mailbridge in Docker in the app subnet (ARCHITECTURE.md §3, task 1.14).

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  description        = "app instance role: SSM agent, reads /mailbridge/*, pulls the mailbridge ECR image"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "app_ssm_min" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

data "aws_iam_policy_document" "app" {
  # Every /mailbridge/* parameter is the app's (§7): both DB passwords
  # (decision 54), the session secret and token key (decision 55), and the
  # OAuth secrets later. Pulled on the host by start scripts (decision 56).
  statement {
    sid       = "ReadAppSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/mailbridge/*"]
  }

  # AWS only accepts * here. The token alone fetches nothing; the pull
  # actions below decide which repository it can read.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Pull only, from the one repository: no push, no delete.
  statement {
    sid    = "PullMailbridgeImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-secrets-and-image"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  count = var.hosts_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in Tier 2.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.app_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name
  ebs_optimized          = true
  subnet_id              = var.app_subnet_id
  private_ip             = var.app_private_ip
  vpc_security_group_ids = [var.app_security_group_id]

  # Cost guardrail: no surplus credits are billed.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only. Hop limit 1 also matters for Docker: a container is one hop
  # further away, so it can't reach the instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    # Lets the end-of-session check find a leftover volume by tag.
    tags = {
      Name    = "${var.name}-app-root"
      Project = var.name
    }
  }

  # No network at first boot (decision 50): only the HTTPS mirror config.
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
    Name    = "${var.name}-app"
    Project = var.name
    Role    = "app"
  }
}
