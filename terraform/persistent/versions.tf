terraform {
  # 1.11 added write-only attributes, which keep the password out of state
  # (decision 46). Ephemeral resources arrived in 1.10.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 3.7 added the ephemeral random_password.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Same bucket as lab, its own key, so a lab teardown can't touch this state.
  # Partial config: the bucket name comes from backend.hcl.
  backend "s3" {
    key          = "persistent/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
