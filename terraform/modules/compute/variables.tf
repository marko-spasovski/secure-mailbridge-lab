variable "name" {
  description = "Prefix for resource names and Name tags."
  type        = string
  default     = "mailbridge-lab"
}

variable "ubuntu_ami_id" {
  description = "Ubuntu 24.04 LTS x86_64 AMI from Canonical for every host, pinned so a plan never replaces a host on its own."
  type        = string
}

variable "fw_instance_type" {
  description = "fw-ips instance type (ARCHITECTURE.md §3)."
  type        = string
  default     = "t3.small"
}

variable "fw_eni_id" {
  description = "Standalone fw-ips network interface from the network module."
  type        = string
}

variable "fw_private_ip" {
  description = "fw-ips private address, which the Elastic IP maps to."
  type        = string
}

variable "ssh_public_key" {
  description = "Public half of the laptop-only Ansible key (decision 36)."
  type        = string
}

variable "hosts_enabled" {
  description = "Session switch: false removes every session host (fw-ips and its Elastic IP, db, app, proxy) between sessions, so nothing idle is billed (decision 41). IAM and the key pair stay; they're free."
  type        = bool
  default     = true
}

variable "db_instance_type" {
  description = "db instance type (ARCHITECTURE.md §3)."
  type        = string
  default     = "t3.micro"
}

variable "db_subnet_id" {
  description = "Data subnet from the network module."
  type        = string
}

variable "db_private_ip" {
  description = "db's fixed address, which the docs and later pg_hba on db refer to."
  type        = string
  default     = "10.0.4.10"
}

variable "db_security_group_id" {
  description = "sg-db from the security module."
  type        = string
}

variable "app_instance_type" {
  description = "app instance type (ARCHITECTURE.md §3)."
  type        = string
  default     = "t3.small"
}

variable "app_subnet_id" {
  description = "App subnet from the network module."
  type        = string
}

variable "app_private_ip" {
  description = "app's fixed address, which pg_hba on db and the proxy refer to."
  type        = string
  default     = "10.0.3.10"
}

variable "app_security_group_id" {
  description = "sg-app from the security module."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the mailbridge ECR repository in the persistent stack, the only one app may pull from."
  type        = string
}

variable "proxy_instance_type" {
  description = "proxy instance type (ARCHITECTURE.md §3)."
  type        = string
  default     = "t3.micro"
}

variable "proxy_subnet_id" {
  description = "DMZ subnet from the network module."
  type        = string
}

variable "proxy_private_ip" {
  description = "proxy's fixed address, which Unbound's mail.<domain> record and app's TRUST_PROXY refer to."
  type        = string
  default     = "10.0.2.10"
}

variable "proxy_security_group_id" {
  description = "sg-proxy from the security module."
  type        = string
}

variable "zone_id" {
  description = "Route 53 zone of the lab subdomain (persistent stack), the only zone proxy may write to."
  type        = string
}

variable "domain" {
  description = "Delegated lab subdomain; builds the one record name proxy may change (decision 60). Kept out of the repo (decision 29)."
  type        = string
}

variable "siem_instance_type" {
  description = "siem instance type: t3.large since 2026-11-05, after the t3.medium ran out of CPU credits and memory headroom (decision 99)."
  type        = string
  default     = "t3.large"
}

variable "siem_subnet_id" {
  description = "mgmt subnet from the network module."
  type        = string
}

variable "siem_private_ip" {
  description = "siem's fixed address, which agents and the admin pool's dashboard access use (ARCHITECTURE.md §1)."
  type        = string
  default     = "10.0.5.10"
}

variable "siem_security_group_id" {
  description = "sg-siem from the security module."
  type        = string
}

variable "siem_data_volume_id" {
  description = "The Wazuh data volume from the persistent stack (decision 88)."
  type        = string
}

variable "siem_data_volume_az" {
  description = "Availability Zone of the Wazuh data volume, checked against the siem host's."
  type        = string
}
