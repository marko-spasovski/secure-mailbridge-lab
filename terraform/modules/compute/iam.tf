# Instance identity for fw-ips (ARCHITECTURE.md §7). Built by hand in 1.6
# and imported, so names and documents match the live resources exactly.

# AmazonSSMManagedInstanceCore without ssm:GetParameter(s): a host reads no
# parameter unless its own role grants it (decision 22). Shared by every
# instance role.
data "aws_iam_policy_document" "ssm_min" {
  #checkov:skip=CKV_AWS_111:Same actions and Resource "*" as AWS-managed AmazonSSMManagedInstanceCore; the agent calls them before it knows any resource ARN.
  #checkov:skip=CKV_AWS_356:Same reason as CKV_AWS_111; parameter reads, the actions that matter, are removed (decision 22).
  statement {
    sid    = "SsmAgentWithoutParameterRead"
    effect = "Allow"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
      "ssm:GetManifest",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutInventory",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
    ]
    resources = ["*"]
  }

  # Session Manager, which also carries Ansible's SSH (decision 36).
  statement {
    sid    = "SessionManagerChannels"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AgentMessages"
    effect = "Allow"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ssm_min" {
  name        = "${var.name}-ssm-min"
  description = "SSM agent access without parameter read"
  policy      = data.aws_iam_policy_document.ssm_min.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fw" {
  name               = "${var.name}-fw-ips"
  description        = "fw-ips instance role: SSM agent, and reads its own /vpn/fw-ips/* parameters"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "fw_ssm_min" {
  role       = aws_iam_role.fw.name
  policy_arn = aws_iam_policy.ssm_min.arn
}

# Looked up rather than written down, so the public repo holds no account ID.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# fw-ips pulls its own VPN files and nothing else (decisions 22, 39).
# /vpn/ca/* stays unreadable to every instance.
data "aws_iam_policy_document" "fw_own_secrets" {
  statement {
    sid       = "ReadOwnSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/vpn/fw-ips/*"]
  }
}

resource "aws_iam_role_policy" "fw_own_secrets" {
  name   = "fw-ips-read-own-secrets"
  role   = aws_iam_role.fw.id
  policy = data.aws_iam_policy_document.fw_own_secrets.json
}

resource "aws_iam_instance_profile" "fw" {
  name = "${var.name}-fw-ips"
  role = aws_iam_role.fw.name
}
