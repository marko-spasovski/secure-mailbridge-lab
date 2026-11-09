variable "domain" {
  description = "The lab's delegated subdomain, e.g. lab.example.com. Set in terraform.tfvars (gitignored), like lab's."
  type        = string
}

# The budgets' alert recipients (decision 144). Personal addresses, so they
# live only in the gitignored terraform.tfvars, and sensitive keeps them out
# of plan output.
variable "budget_default_emails" {
  description = "Who the console-made 'My Monthly Cost Budget' alerts."
  type        = list(string)
  sensitive   = true
}

variable "budget_lab_emails" {
  description = "Who the lab budget (task 1.1b) alerts."
  type        = list(string)
  sensitive   = true
}
