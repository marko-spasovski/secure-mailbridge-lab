variable "name" {
  description = "Prefix for resource names and Name tags."
  type        = string
  default     = "mailbridge-lab"
}

variable "fw_ami_id" {
  description = "Ubuntu 24.04 LTS x86_64 AMI from Canonical, pinned so a plan never replaces fw-ips on its own."
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
