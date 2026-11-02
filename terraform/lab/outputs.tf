output "fw_instance_id" {
  description = "fw-ips instance ID, for aws ssm start-session. Ansible finds it by tags (decision 45)."
  value       = module.compute.fw_instance_id
}
