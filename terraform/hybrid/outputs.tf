output "public_ip" {
  description = "IP publik EC2 — akses app di http://<ip>"
  value       = aws_instance.app.public_ip
}

output "public_dns" {
  description = "DNS publik EC2"
  value       = aws_instance.app.public_dns
}

output "ssh_command" {
  description = "Perintah SSH ke instance"
  value       = "ssh -i <path-key>.pem ec2-user@${aws_instance.app.public_ip}"
}
