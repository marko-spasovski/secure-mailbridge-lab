# Wazuh agents (task 1.17, decision 100). Each agent host may read the one
# enrollment password, nothing else under /siem/; siem reads all of /siem/*.
data "aws_iam_policy_document" "wazuh_agent_enrollment" {
  statement {
    sid       = "ReadWazuhEnrollmentPassword"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/siem/agent-enrollment-password"]
  }
}

resource "aws_iam_role_policy" "wazuh_agent_enrollment" {
  for_each = {
    fw-ips = aws_iam_role.fw.id
    db     = aws_iam_role.db.id
    app    = aws_iam_role.app.id
    proxy  = aws_iam_role.proxy.id
    mon    = aws_iam_role.mon.id
  }

  name   = "${each.key}-read-wazuh-enrollment-password"
  role   = each.value
  policy = data.aws_iam_policy_document.wazuh_agent_enrollment.json
}
