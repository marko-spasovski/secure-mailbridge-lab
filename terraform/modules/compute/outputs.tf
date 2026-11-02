output "fw_instance_id" {
  description = "fw-ips instance ID, for the Ansible inventory."
  value       = aws_instance.fw.id
}

output "fw_public_ip" {
  description = "fw-ips Elastic IP, which the vpn record points at."
  value       = aws_eip.fw.public_ip
}
