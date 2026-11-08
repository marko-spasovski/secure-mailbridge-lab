variable "name" {
  description = "Prefix for security group names."
  type        = string
  default     = "mailbridge-lab"
}

variable "vpc_id" {
  description = "VPC ID from the network module."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC address range."
  type        = string
}

variable "fw_private_ip" {
  description = "fw-ips address, where private hosts send DNS queries (Unbound)."
  type        = string
}

variable "vpn_source_cidr" {
  description = "Who may reach OpenVPN. Narrow to a home IP if it is static."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpn_pools_cidr" {
  description = "User and admin VPN pools together."
  type        = string
  default     = "10.8.0.0/22"
}

variable "admin_pool_cidr" {
  description = "Admin VPN pool."
  type        = string
  default     = "10.8.1.0/24"
}

variable "open_https_test_window" {
  description = "Opens TCP 443 on fw-ips to the internet. Outside-attack test windows only."
  type        = bool
  default     = false
}

variable "subnet_ids" {
  description = "Subnet name to subnet ID, from the network module."
  type        = map(string)
}

variable "subnet_cidrs" {
  description = "Subnet name to CIDR, from the network module."
  type        = map(string)
}

variable "mon_private_ip" {
  description = "mon's fixed address: the NACLs admit its scrapes by IP (ARCHITECTURE.md §4, decision 120)."
  type        = string
  default     = "10.0.5.20"
}

variable "proxy_private_ip" {
  description = "proxy's fixed address: sg-vuln and the vuln NACL admit it by IP, because its traffic reaches vuln through fw-ips (decision 68)."
  type        = string
  default     = "10.0.2.10"
}

variable "siem_private_ip" {
  description = "siem's fixed address: the Juice Shop host's Wazuh agent reaches it through fw-ips, so sg-vuln names the IP (decision 68)."
  type        = string
  default     = "10.0.5.10"
}

variable "vuln_private_ip" {
  description = "The Juice Shop host's fixed address (ARCHITECTURE.md §1, decision 67)."
  type        = string
  default     = "10.0.6.10"
}
