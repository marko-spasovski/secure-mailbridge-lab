variable "flow_log_bucket_arn" {
  description = "ARN of the S3 bucket that stores VPC flow logs."
  type        = string
}

variable "domain" {
  description = "Delegated lab subdomain. Not a secret, but kept out of the public repo (decision 29)."
  type        = string
}

variable "ubuntu_ami_id" {
  description = "Pinned Canonical Ubuntu 24.04 LTS x86_64 AMI for every host."
  type        = string
}

variable "ssh_public_key" {
  description = "Contents of ~/.ssh/mailbridge-lab-ansible.pub, the public half of the laptop-only Ansible key (decision 36). Passed as a value, not a path, so CI and other machines can evaluate the config."
  type        = string
}

variable "hosts_enabled" {
  description = "Session switch (decision 41): terraform apply -var hosts_enabled=false at the end of a session removes every session host; plain terraform apply at the start."
  type        = bool
  default     = true
}

variable "vuln_enabled" {
  description = "Juice Shop switch (decision 74): plain apply leaves it off; -var vuln_enabled=true adds the vuln host to a session."
  type        = bool
  default     = false
}
