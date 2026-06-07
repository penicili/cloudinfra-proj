variable "aws_region" {
  description = "Region AWS untuk deploy"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix nama resource"
  type        = string
  default     = "url-shortener"
}

variable "instance_type" {
  description = "Tipe EC2 free tier. t2.micro tidak eligible di sebagian region/akun baru; t3.micro umumnya eligible (sama-sama 1 GiB RAM)."
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Nama EC2 key pair untuk akses SSH (harus sudah ada di AWS)"
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR yang diizinkan SSH. Disarankan IP publik kamu saja (mis. 1.2.3.4/32)."
  type        = string
  default     = "0.0.0.0/0"
}
