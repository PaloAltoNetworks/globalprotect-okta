output "demo_users" {
  description = "Randomly generated passwords for the demo users"
  sensitive   = true
  value       = { for user in var.demo_users : user.login => random_password.demo_password[user.login].result }
}

output "globalprotect_hostname" {
  description = "Public IP of the GlobalProtect Portal and Gateway"
  value       = aws_eip.this["public"].public_ip
}

output "vmseries_management_ip" {
  description = "Management IP of the VM-Series Firewall"
  value       = aws_eip.this["management"].public_ip
}
