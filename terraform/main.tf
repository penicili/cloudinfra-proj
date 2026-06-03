# Provisioning EC2 t2.micro (AWS Free Tier) untuk menjalankan Docker Compose
# stack URL shortener. Kontainer berjalan DI DALAM VM ini.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Kredensial diambil dari AWS CLI profile / environment variable.
  # JANGAN hardcode access key di file ini.
}

# --- Networking -----------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security Group: HANYA port 80 (HTTP) & 22 (SSH) ----------------------
resource "aws_security_group" "web" {
  name        = "${var.project_name}-sg"
  description = "Allow HTTP (80) and SSH (22) only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# --- AMI Amazon Linux 2 (terbaru) -----------------------------------------
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# File deploy dibaca dari repo (sumber tunggal) lalu ditanam ke instance.
locals {
  compose_file = file("${path.module}/../docker-compose.yml")
  nginx_conf   = file("${path.module}/../nginx/nginx.conf")
}

# --- EC2 instance ---------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = var.key_name

  # Trigger replace instance bila isi compose/nginx berubah (agar redeploy).
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -e
    exec > /var/log/user-data.log 2>&1   # log untuk debug: cat /var/log/user-data.log

    yum update -y
    amazon-linux-extras install docker -y
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user

    # Docker Compose v2 plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # Tunggu daemon docker siap
    until docker info >/dev/null 2>&1; do sleep 2; done

    # Tanam file deploy (di-decode dari base64; sumber tunggal = repo lokal)
    mkdir -p /opt/app/nginx
    echo '${base64encode(local.compose_file)}' | base64 -d > /opt/app/docker-compose.yml
    echo '${base64encode(local.nginx_conf)}'   | base64 -d > /opt/app/nginx/nginx.conf

    # Tarik image (app dari Docker Hub, redis & nginx official) lalu jalankan
    cd /opt/app
    docker compose pull
    docker compose up -d
  EOF

  tags = {
    Name = "${var.project_name}-ec2"
  }
}
