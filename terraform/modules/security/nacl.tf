# Second layer from ARCHITECTURE.md §4: one stateless ACL per subnet.
# NACLs have no connection tracking, so replies need their own rules, and the
# first matching rule number wins.

locals {
  any = "0.0.0.0/0"
  tcp = "6"
  udp = "17"

  ephemeral = { from = 1024, to = 65535 }

  # Replies from the internet can come from anywhere, so this range must be open.
  # It includes service ports, which is why app, data and mgmt deny them first
  # (105, and 115 for Grafana on mgmt).
  return_inbound = [
    { protocol = local.tcp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
    { protocol = local.udp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
  ]

  baseline_outbound = [
    { number = 110, protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
    { number = 120, protocol = local.udp, cidr = local.any, from = 123, to = 123 },
    { number = 130, protocol = local.udp, cidr = "${var.fw_private_ip}/32", from = 53, to = 53 },
    { number = 140, protocol = local.tcp, cidr = "${var.fw_private_ip}/32", from = 53, to = 53 },
  ]

  # mon's scrapes (decision 120). 9100 is inside the ephemeral range that
  # rules 110/120 open for replies, so each scraped subnet allows mon first
  # and denies everyone else before those rules; replies go back to mon.
  mon = "${var.mon_private_ip}/32"
  node_exporter_inbound = [
    { number = 106, action = "allow", protocol = local.tcp, cidr = local.mon, from = 9100, to = 9100 },
    { number = 107, action = "deny", protocol = local.tcp, cidr = local.any, from = 9100, to = 9100 },
  ]
  replies_to_mon = {
    number = 170, protocol = local.tcp, cidr = local.mon, from = local.ephemeral.from, to = local.ephemeral.to
  }

  agents_outbound = {
    number = 150, protocol = local.tcp, cidr = var.subnet_cidrs["mgmt"], from = 1514, to = 1515
  }

  nacl_inbound = {
    public = concat(
      [
        { number = 100, action = "allow", protocol = local.udp, cidr = var.vpn_source_cidr, from = 1194, to = 1194 },
        { number = 110, action = "allow", protocol = "-1", cidr = var.vpc_cidr, from = null, to = null },
        merge(local.return_inbound[0], { number = 120, action = "allow" }),
        merge(local.return_inbound[1], { number = 130, action = "allow" }),
      ],
      var.open_https_test_window ? [
        { number = 140, action = "allow", protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
      ] : [],
    )
    dmz = concat(
      [
        { number = 100, action = "allow", protocol = local.tcp, cidr = var.vpn_pools_cidr, from = 443, to = 443 },
        # mon's HTTPS probe (decisions 84, 125).
        { number = 105, action = "allow", protocol = local.tcp, cidr = local.mon, from = 443, to = 443 },
      ],
      local.node_exporter_inbound,
      [
        merge(local.return_inbound[0], { number = 110, action = "allow" }),
        merge(local.return_inbound[1], { number = 120, action = "allow" }),
      ],
    )
    app = concat(
      [
        { number = 100, action = "allow", protocol = local.tcp, cidr = var.subnet_cidrs["dmz"], from = 3000, to = 3000 },
        { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 3000, to = 3000 },
      ],
      local.node_exporter_inbound,
      [
        merge(local.return_inbound[0], { number = 110, action = "allow" }),
        merge(local.return_inbound[1], { number = 120, action = "allow" }),
      ],
    )
    data = concat(
      [
        { number = 100, action = "allow", protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = 5432, to = 5432 },
        { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 5432, to = 5432 },
      ],
      local.node_exporter_inbound,
      # postgres_exporter (decision 124), the same pattern as 9100.
      [
        { number = 108, action = "allow", protocol = local.tcp, cidr = local.mon, from = 9187, to = 9187 },
        { number = 109, action = "deny", protocol = local.tcp, cidr = local.any, from = 9187, to = 9187 },
      ],
      [
        merge(local.return_inbound[0], { number = 110, action = "allow" }),
        merge(local.return_inbound[1], { number = 120, action = "allow" }),
      ],
    )
    mgmt = [
      { number = 100, action = "allow", protocol = local.tcp, cidr = var.vpc_cidr, from = 1514, to = 1515 },
      { number = 105, action = "deny", protocol = local.tcp, cidr = local.any, from = 1514, to = 1515 },
      { number = 110, action = "allow", protocol = local.tcp, cidr = var.admin_pool_cidr, from = 443, to = 443 },
      # Grafana: 3000 is inside the ephemeral range that 120 opens to everyone.
      { number = 112, action = "allow", protocol = local.tcp, cidr = var.admin_pool_cidr, from = 3000, to = 3000 },
      { number = 115, action = "deny", protocol = local.tcp, cidr = local.any, from = 3000, to = 3000 },
      merge(local.return_inbound[0], { number = 120, action = "allow" }),
      merge(local.return_inbound[1], { number = 130, action = "allow" }),
    ]
  }

  nacl_outbound = {
    public = concat(
      [
        { number = 100, protocol = "-1", cidr = var.vpc_cidr, from = null, to = null },
        { number = 110, protocol = local.tcp, cidr = local.any, from = 443, to = 443 },
        { number = 120, protocol = local.udp, cidr = local.any, from = 123, to = 123 },
        { number = 130, protocol = local.udp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
      ],
      var.open_https_test_window ? [
        { number = 140, protocol = local.tcp, cidr = local.any, from = local.ephemeral.from, to = local.ephemeral.to },
      ] : [],
    )
    dmz = concat(local.baseline_outbound, [
      { number = 100, protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = 3000, to = 3000 },
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.vpn_pools_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
      local.replies_to_mon,
    ])
    app = concat(local.baseline_outbound, [
      { number = 100, protocol = local.tcp, cidr = var.subnet_cidrs["data"], from = 5432, to = 5432 },
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.subnet_cidrs["dmz"], from = local.ephemeral.from, to = local.ephemeral.to },
      local.replies_to_mon,
    ])
    data = concat(local.baseline_outbound, [
      local.agents_outbound,
      { number = 160, protocol = local.tcp, cidr = var.subnet_cidrs["app"], from = local.ephemeral.from, to = local.ephemeral.to },
      local.replies_to_mon,
    ])
    mgmt = concat(local.baseline_outbound, [
      { number = 160, protocol = local.tcp, cidr = var.vpc_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
      { number = 170, protocol = local.tcp, cidr = var.admin_pool_cidr, from = local.ephemeral.from, to = local.ephemeral.to },
    ])
  }

  nacl_rules = merge(
    merge([
      for subnet, rules in local.nacl_inbound : {
        for rule in rules : "${subnet}-in-${rule.number}" => merge(rule, { subnet = subnet, egress = false })
      }
    ]...),
    merge([
      for subnet, rules in local.nacl_outbound : {
        for rule in rules : "${subnet}-out-${rule.number}" => merge(rule, { subnet = subnet, egress = true, action = "allow" })
      }
    ]...),
  )
}

resource "aws_network_acl" "this" {
  #checkov:skip=CKV2_AWS_1:Attached through subnet_ids, which checkov cannot trace across modules.
  # Keys come from subnet_cidrs because they are known before apply; subnet IDs are not.
  for_each = var.subnet_cidrs

  vpc_id     = var.vpc_id
  subnet_ids = [var.subnet_ids[each.key]]

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_network_acl_rule" "this" {
  for_each = local.nacl_rules

  network_acl_id = aws_network_acl.this[each.value.subnet].id
  rule_number    = each.value.number
  egress         = each.value.egress
  protocol       = each.value.protocol
  rule_action    = each.value.action
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to
}
