terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.x: primary_network_interface replaces the deprecated network_interface.
      version = ">= 6.0"
    }
  }
}
