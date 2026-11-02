output "fw_instance_id" {
  description = "fw-ips instance ID for ansible/inventories/aws/hosts.yml."
  value       = module.compute.fw_instance_id
}
