provider "aws" {
  region = "eu-central-1"
}

module "network" {
  source = "../modules/network"

  flow_log_bucket_arn = var.flow_log_bucket_arn
}

module "security" {
  source = "../modules/security"

  vpc_id        = module.network.vpc_id
  vpc_cidr      = module.network.vpc_cidr
  fw_eni_id     = module.network.fw_eni_id
  fw_private_ip = module.network.fw_private_ip
  subnet_ids    = module.network.subnet_ids
  subnet_cidrs  = module.network.subnet_cidrs
}

module "compute" {
  source = "../modules/compute"

  fw_enabled     = var.fw_enabled
  fw_ami_id      = var.fw_ami_id
  fw_eni_id      = module.network.fw_eni_id
  fw_private_ip  = module.network.fw_private_ip
  ssh_public_key = var.ssh_public_key
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
  count = var.fw_enabled ? 1 : 0

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
