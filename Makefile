# Session routine as commands (task 0.6, decision 142). Make is only a task
# runner here: every target is .PHONY and runs its steps in order, stopping
# at the first failure.
#
#   make plan-up    save the start plan, print it          (review it)
#   make up         apply that saved plan, then make configure
#   make configure  wait for fw-ips's first boot, run site.yml, prove idempotence (resumes a failed up)
#   make verify     read-only checks of a running lab
#   make plan-down  save the teardown plan, print it       (review it)
#   make down       evidence, clean stop, apply that saved plan, check nothing is left
#
# Terraform changes only through a plan file you reviewed: `up` and `down`
# refuse to run without one, and delete it after the apply, so a plan can't
# be applied twice or after the state moved on.
# VULN=false starts the lab without the Juice Shop host.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

VULN     ?= true
PLAN_DIR := $(HOME)/.cache/mailbridge-lab
TF       := terraform -chdir=terraform/lab
TF_VARS  := -var vuln_enabled=$(VULN)
DOMAIN    = $(shell awk '/^domain:/ {print $$2}' ansible/group_vars/all/domain.yml)
REGION   := eu-central-1

.PHONY: help preflight plan-up up configure verify plan-down down

help:
	@sed -n '/^#   make/p' Makefile

# The admin login and the Ansible key are what every later step needs.
preflight:
	@aws sts get-caller-identity --query Arn --output text | grep -q 'marko-admin$$' \
	  || { echo "Not logged in as marko-admin: run aws login"; exit 1; }
	@ssh-add -l 2>/dev/null | grep -q mailbridge-lab-ansible \
	  || { echo 'Ansible key not loaded: eval "$$(ssh-agent -s)" && ssh-add ~/.ssh/mailbridge-lab-ansible'; exit 1; }
	@echo "preflight: marko-admin, Ansible key loaded"

plan-up: preflight
	@mkdir -p -m 0700 $(PLAN_DIR)
	$(TF) plan $(TF_VARS) -var hosts_enabled=true -out=$(PLAN_DIR)/up.tfplan
	@echo "Review the plan above, then: make up"

up: preflight
	@test -f $(PLAN_DIR)/up.tfplan || { echo "No saved plan: make plan-up first"; exit 1; }
	$(TF) apply $(PLAN_DIR)/up.tfplan
	rm -f $(PLAN_DIR)/up.tfplan
	$(MAKE) --no-print-directory configure

# Only fw-ips is reachable at first: the private hosts reach SSM through its
# NAT, which site.yml's first play sets up; each later play then waits for its
# host with wait_for_connection (ARCHITECTURE §13).
configure: preflight
	cd ansible && ansible fw_ips -m ansible.builtin.command -a 'cloud-init status --wait'
	cd ansible && ansible-playbook site.yml
	@echo "Second run: every host must report changed=0"
	cd ansible && ansible-playbook site.yml | tee $(PLAN_DIR)/second-run.log
	@! grep -E 'changed=[1-9]' $(PLAN_DIR)/second-run.log \
	  || { echo "Not idempotent: a second run changed something"; exit 1; }
	@echo "up: done. Connect the VPN, then: make verify"

# Read-only. Needs the VPN for the last four checks.
verify: preflight
	$(TF) plan $(TF_VARS) -detailed-exitcode -input=false > /dev/null \
	  && echo "terraform: no changes" \
	  || { echo "terraform: the plan is not empty"; exit 1; }
	cd ansible && ansible all -m ansible.builtin.ping
	cd ansible && ansible siem -b -m ansible.builtin.command \
	  -a 'systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard'
	cd ansible && ansible mon -m ansible.builtin.shell \
	  -a "curl -s 127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys; t=json.load(sys.stdin)[\"data\"][\"activeTargets\"]; d=[x[\"labels\"][\"job\"] for x in t if x[\"health\"]!=\"up\"]; print(len(t), \"targets, down:\", d or \"none\"); sys.exit(bool(d))'"
	ping -c 3 -W 2 10.0.1.10 > /dev/null && echo "vpn: fw-ips answers"
	test "$$(dig +short @10.0.1.10 mail.$(DOMAIN))" = 10.0.2.10 && echo "dns: mail -> 10.0.2.10"
	test "$$(curl -sk -o /dev/null -w '%{http_code}' https://mail.$(DOMAIN)/)" = 200 && echo "https: mail 200"
	@if [ "$(VULN)" = true ]; then \
	  test "$$(dig +short @10.0.1.10 vuln.$(DOMAIN))" = 10.0.2.10 && echo "dns: vuln -> 10.0.2.10"; \
	  test "$$(curl -sk -o /dev/null -w '%{http_code}' https://vuln.$(DOMAIN)/)" = 200 && echo "https: vuln 200"; \
	fi
	@echo "verify: all checks passed"

plan-down: preflight
	@mkdir -p -m 0700 $(PLAN_DIR)
	$(TF) plan $(TF_VARS) -var hosts_enabled=false -out=$(PLAN_DIR)/down.tfplan
	@echo "Review the plan above, disconnect the VPN, then: make down"

down: preflight
	@test -f $(PLAN_DIR)/down.tfplan || { echo "No saved plan: make plan-down first"; exit 1; }
	cd ansible && ansible-playbook evidence.yml
	cd ansible && ansible-playbook stop.yml
	$(TF) apply $(PLAN_DIR)/down.tfplan
	rm -f $(PLAN_DIR)/down.tfplan
	@n=$$(aws ec2 describe-instances --region $(REGION) \
	    --filters Name=tag:Project,Values=mailbridge-lab Name=instance-state-name,Values=pending,running,stopping,stopped \
	    --query 'length(Reservations[].Instances[])' --output text); \
	  e=$$(aws ec2 describe-addresses --region $(REGION) --query 'length(Addresses)' --output text); \
	  echo "left: $$n instances, $$e Elastic IPs"; test "$$n" = 0 && test "$$e" = 0
	@echo "down: done"
