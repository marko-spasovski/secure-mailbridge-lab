# proxy: Nginx, ModSecurity and lego in the DMZ subnet (ARCHITECTURE.md §3, task 1.15).

# Same trust policy and SSM baseline as the other hosts (decision 22).
resource "aws_iam_role" "proxy" {
  name               = "${var.name}-proxy"
  description        = "proxy instance role: SSM agent, and TXT changes to the mail and vuln _acme-challenge names in the lab zone only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "proxy_ssm_min" {
  role       = aws_iam_role.proxy.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# DNS-01 for lego (decisions 59, 60). proxy is the most exposed host, so the
# change grant is limited to the two challenge names (mail, and vuln from
# decision 70), one type and two actions: an attacker there can't repoint
# vpn.<domain>. ForAllValues makes every record in a request match.
# Normalized names are lower case without the trailing dot.
data "aws_iam_policy_document" "proxy_acme" {
  statement {
    sid       = "ChangeAcmeChallengeTxtOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        "_acme-challenge.mail.${lower(var.domain)}",
        "_acme-challenge.vuln.${lower(var.domain)}",
      ]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"
      values   = ["UPSERT", "DELETE"]
    }
  }

  # lego reads the existing TXT values to merge them. This can't be scoped
  # below the zone, and the zone is public DNS anyway.
  statement {
    sid       = "ReadLabZoneRecords"
    effect    = "Allow"
    actions   = ["route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.zone_id}"]
  }

  # Waiting for the change to apply. Route 53 offers no narrower resource.
  statement {
    sid       = "WaitForChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
}

resource "aws_iam_role_policy" "proxy_acme" {
  name   = "proxy-acme-dns01"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy_acme.json
}

resource "aws_iam_instance_profile" "proxy" {
  name = "${var.name}-proxy"
  role = aws_iam_role.proxy.name
}

resource "aws_instance" "proxy" {
  count = var.hosts_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in Tier 2.
  ami                    = var.ubuntu_ami_id
  instance_type          = var.proxy_instance_type
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.proxy.name
  ebs_optimized          = true
  subnet_id              = var.proxy_subnet_id
  private_ip             = var.proxy_private_ip
  vpc_security_group_ids = [var.proxy_security_group_id]

  # Cost guardrail: no surplus credits are billed.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only, hop limit 1, as on the other hosts.
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

    # Lets the end-of-session check find a leftover volume by tag.
    tags = {
      Name    = "${var.name}-proxy-root"
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
    Name    = "${var.name}-proxy"
    Project = var.name
    Role    = "proxy"
  }
}
