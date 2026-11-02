# Managed by Ansible (app role). Decision 56. Sourced by the mailbridge-*
# scripts, which systemd runs as root.
set -eu

# One SSM parameter, pulled with app's own instance role. Called inside
# $(...), so the value goes into a shell variable, never into argv or a file.
ssm() {
  /snap/bin/aws ssm get-parameter --region eu-central-1 --name "$1" \
    --with-decryption --query Parameter.Value --output text
}

# The ECR credential helper fetches a fresh token from the instance role on
# each pull instead of caching one in root's home directory.
export AWS_ECR_DISABLE_CACHE=true

# The registry name contains the account ID, which the public repo leaves
# out, so it is worked out here. get-caller-identity needs no permission.
account=$(/snap/bin/aws sts get-caller-identity --query Account --output text)
image="${account}.dkr.ecr.eu-central-1.amazonaws.com/mailbridge@$(cat /etc/mailbridge/image-digest)"

# Every container: read-only root, no Linux capabilities, no privilege
# escalation, capped memory, a minimal init. --rm deletes the container,
# and Docker's stored copy of its environment, as soon as it stops.
hardening="--rm --read-only --cap-drop ALL --security-opt no-new-privileges --memory 512m --init"
