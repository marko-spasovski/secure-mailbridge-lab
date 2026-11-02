# fw-ips (ARCHITECTURE.md §3), task 1.6. Configured afterwards by the fw_ips
# Ansible role over SSM; nothing here holds a secret.

# Only the public key: the private half never leaves the laptop.
resource "aws_key_pair" "ansible" {
  key_name   = "${var.name}-ansible"
  public_key = var.ssh_public_key
}

resource "aws_instance" "fw" {
  count = var.fw_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_126:Detailed monitoring is billed per metric; node_exporter covers metrics in Tier 2.
  ami                  = var.fw_ami_id
  instance_type        = var.fw_instance_type
  key_name             = aws_key_pair.ansible.key_name
  iam_instance_profile = aws_iam_instance_profile.fw.name
  ebs_optimized        = true

  # The standalone ENI keeps 10.0.1.10, its security group and the routes
  # that target it when the instance is replaced.
  primary_network_interface {
    network_interface_id = var.fw_eni_id
  }

  # Cost guardrail: no surplus credits are billed.
  credit_specification {
    cpu_credits = "standard"
  }

  # IMDSv2 only, and a hop limit of 1, so a container or forwarded packet
  # can't reach the instance credentials.
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
  }

  # First boot only: set the HTTPS mirror before Ubuntu's own apt timers run
  # (the fw_ips role enforces the same file afterwards), then fully upgrade
  # and reboot if a new kernel needs it, as the hand-built host was.
  user_data = <<-EOT
    #cloud-config
    package_upgrade: true
    package_reboot_if_required: true
    apt:
      primary:
        - arches: [default]
          uri: https://eu-central-1.ec2.archive.ubuntu.com/ubuntu/
      security:
        - arches: [default]
          uri: https://eu-central-1.ec2.archive.ubuntu.com/ubuntu/
  EOT

  # Project and Role build the Ansible inventory (decision 45): Role is the
  # Ansible group, so whatever carries Role = fw_ips gets the fw_ips role.
  tags = {
    Name    = "${var.name}-fw-ips"
    Project = var.name
    Role    = "fw_ips"
  }

  # On the primary interface this is the ENI's own check, which the network
  # module keeps off. It can't be set here alongside primary_network_interface,
  # and the instance default (true) must never be applied: with the check on,
  # AWS drops every packet fw-ips forwards.
  lifecycle {
    ignore_changes = [source_dest_check]
  }
}

# Lives with the lab stack and is released on destroy, so no idle IP is
# billed (ARCHITECTURE.md §3).
resource "aws_eip" "fw" {
  count = var.fw_enabled ? 1 : 0

  #checkov:skip=CKV2_AWS_19:Associated with the fw-ips ENI by aws_eip_association, which checkov does not recognise.
  domain = "vpc"

  tags = {
    Name = "${var.name}-fw-ips"
  }
}

# Associated with the ENI, not the instance, so the address survives an
# instance replacement.
resource "aws_eip_association" "fw" {
  count = var.fw_enabled ? 1 : 0

  allocation_id        = aws_eip.fw[0].id
  network_interface_id = var.fw_eni_id
  private_ip_address   = var.fw_private_ip

  # Nothing above references the instance, so without this Terraform creates
  # both at once, and AWS refuses to associate while the instance attached to
  # the ENI is still pending (IncorrectInstanceState, seen 2026-11-02).
  depends_on = [aws_instance.fw]
}

# count was added for fw_enabled (decision 41); these keep the existing
# resources instead of replacing them.
moved {
  from = aws_instance.fw
  to   = aws_instance.fw[0]
}

moved {
  from = aws_eip.fw
  to   = aws_eip.fw[0]
}

moved {
  from = aws_eip_association.fw
  to   = aws_eip_association.fw[0]
}
