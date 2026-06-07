output "nginx_public_ip" {
  description = "IP publik vm-nginx — akses app di http://<ip>"
  value       = aws_instance.nginx.public_ip
}

output "app_private_ip" {
  description = "IP privat vm-app (Flask) — hanya diakses dari vm-nginx"
  value       = aws_instance.app.private_ip
}

output "redis_private_ip" {
  description = "IP privat vm-redis — hanya diakses dari vm-app"
  value       = aws_instance.redis.private_ip
}

output "ssh_command_nginx" {
  description = "Perintah SSH ke vm-nginx"
  value       = "ssh -i <path-key>.pem ec2-user@${aws_instance.nginx.public_ip}"
}
