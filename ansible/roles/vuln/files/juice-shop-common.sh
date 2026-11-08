# Managed by Ansible (vuln role). Sourced by the juice-shop-* scripts, which
# systemd runs as root (decisions 69, 129).
set -eu

# The ECR credential helper fetches a fresh token from the instance role on
# each pull instead of caching one in root's home directory.
export AWS_ECR_DISABLE_CACHE=true

# The registry name contains the account ID, which the public repo leaves
# out, so it is worked out here. get-caller-identity needs no permission.
account=$(/snap/bin/aws sts get-caller-identity --query Account --output text)
image="${account}.dkr.ecr.eu-central-1.amazonaws.com/juice-shop@$(cat /etc/juice-shop/image-digest)"
