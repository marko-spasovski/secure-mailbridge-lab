provider "aws" {
  region = "eu-central-1"
}

module "network" {
  source = "../modules/network"

  flow_log_bucket_arn   = var.flow_log_bucket_arn
  fw_security_group_ids = [module.security.security_group_ids["fw"]]
}

module "security" {
  source = "../modules/security"

  vpc_id        = module.network.vpc_id
  vpc_cidr      = module.network.vpc_cidr
  fw_private_ip = module.network.fw_private_ip
  subnet_ids    = module.network.subnet_ids
  subnet_cidrs  = module.network.subnet_cidrs
}

module "compute" {
  source = "../modules/compute"

  hosts_enabled  = var.hosts_enabled
  ubuntu_ami_id  = var.ubuntu_ami_id
  fw_eni_id      = module.network.fw_eni_id
  fw_private_ip  = module.network.fw_private_ip
  ssh_public_key = var.ssh_public_key

  db_subnet_id         = module.network.subnet_ids["data"]
  db_security_group_id = module.security.security_group_ids["db"]

  app_subnet_id         = module.network.subnet_ids["app"]
  app_security_group_id = module.security.security_group_ids["app"]
  ecr_repository_arn    = data.aws_ecr_repository.mailbridge.arn

  proxy_subnet_id         = module.network.subnet_ids["dmz"]
  proxy_security_group_id = module.security.security_group_ids["proxy"]
  zone_id                 = data.aws_route53_zone.lab.zone_id
  domain                  = var.domain

  siem_subnet_id         = module.network.subnet_ids["mgmt"]
  siem_security_group_id = module.security.security_group_ids["siem"]
  siem_data_volume_id    = data.aws_ebs_volume.wazuh_data.id
  siem_data_volume_az    = data.aws_ebs_volume.wazuh_data.availability_zone
}

# Belongs to the persistent stack (decision 88), so lab only looks it up and
# attaches it.
data "aws_ebs_volume" "wazuh_data" {
  most_recent = true

  filter {
    name   = "tag:Name"
    values = ["mailbridge-lab-wazuh-data"]
  }
}

# Belongs to the persistent stack (decision 53), so lab only looks it up.
data "aws_ecr_repository" "mailbridge" {
  name = "mailbridge"
}

# The zone belongs to the persistent stack (task 1.2), so lab only looks it up.
data "aws_route53_zone" "lab" {
  name = var.domain
}

# VPN clients connect to vpn.<domain>, never to an address, so profiles
# survive a new Elastic IP (ARCHITECTURE.md §3). allow_overwrite lets
# Terraform take over the record made by hand. Removed with fw-ips, so the
# name never points at a released address that someone else may now hold.
resource "aws_route53_record" "vpn" {
  count = var.hosts_enabled ? 1 : 0

  zone_id         = data.aws_route53_zone.lab.zone_id
  name            = "vpn.${var.domain}"
  type            = "A"
  ttl             = 60
  records         = [module.compute.fw_public_ip]
  allow_overwrite = true
}

moved {
  from = aws_route53_record.vpn
  to   = aws_route53_record.vpn[0]
}

# The ENI now declares sg-fw itself (decision 42). Destroying the old
# attachment would detach sg-fw, so Terraform only forgets it.
removed {
  from = module.security.aws_network_interface_sg_attachment.fw

  lifecycle {
    destroy = false
  }
}
