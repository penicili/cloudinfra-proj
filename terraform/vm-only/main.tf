# Provisioning 3 EC2 terpisah (nginx -> flask -> redis), masing-masing 1 service
# per VM. Pembanding akademis terhadap arsitektur HYBRID (3 kontainer di 1 VM).
# Topologi sama, tetapi isolasi terjadi di level VM/Security Group, bukan kontainer.

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

# --- Networking (1 VPC + 1 subnet publik untuk ketiga VM) -----------------
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

# --- Security Groups: satu per tier, akses antar-tier dibatasi -------------

# vm-nginx: port 80 publik + SSH
resource "aws_security_group" "nginx" {
  name        = "${var.project_name}-nginx-sg"
  description = "nginx: HTTP 80 public, SSH"
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
    Name = "${var.project_name}-nginx-sg"
  }
}

# vm-app: port 5000 HANYA dari Security Group nginx + SSH
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "flask: 5000 from nginx SG only, SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Flask from nginx only"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
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
    Name = "${var.project_name}-app-sg"
  }
}

# vm-redis: port 6379 HANYA dari Security Group app + SSH
resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "redis: 6379 from app SG only, SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from app only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
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
    Name = "${var.project_name}-redis-sg"
  }
}

# --- AMI Amazon Linux 2023 (terbaru) --------------------------------------
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# --- VM 3: redis ----------------------------------------------------------
# Dibuat lebih dulu agar IP privat-nya siap dirujuk vm-app (urutan logis tier).
resource "aws_instance" "redis" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.redis.id]
  key_name               = var.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    exec > /var/log/user-data.log 2>&1   # debug: cat /var/log/user-data.log

    dnf update -y
    dnf install -y redis6

    # Dengarkan semua interface agar bisa diakses vm-app (akses dibatasi SG).
    sed -i 's/^bind .*/bind 0.0.0.0/' /etc/redis6/redis6.conf
    sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis6/redis6.conf

    systemctl enable --now redis6
  EOF

  tags = {
    Name = "${var.project_name}-vm-redis"
  }
}

# --- VM 2: flask app ------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.key_name

  # IP privat redis ditanam sebagai env (walau app hardcoded, untuk paritas topologi).
  user_data = <<-EOF
    #!/bin/bash
    set -e
    exec > /var/log/user-data.log 2>&1

    dnf update -y
    dnf install -y python3 python3-pip
    pip3 install flask

    cat > /opt/app.py <<'PY'
    from flask import Flask
    app = Flask(__name__)

    @app.route("/")
    def hello():
        return "hello from vm"

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=5000)
    PY

    cat > /etc/systemd/system/flaskapp.service <<'UNIT'
    [Unit]
    Description=Flask hello app
    After=network.target

    [Service]
    Environment=REDIS_HOST=${aws_instance.redis.private_ip}
    Environment=REDIS_PORT=6379
    ExecStart=/usr/bin/python3 /opt/app.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now flaskapp
  EOF

  tags = {
    Name = "${var.project_name}-vm-app"
  }
}

# --- VM 1: nginx reverse proxy --------------------------------------------
resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nginx.id]
  key_name               = var.key_name

  # proxy_pass mengarah ke IP privat vm-app (dependency implisit -> dibuat setelah app).
  user_data = <<-EOF
    #!/bin/bash
    set -e
    exec > /var/log/user-data.log 2>&1

    dnf update -y
    dnf install -y nginx

    cat > /etc/nginx/conf.d/proxy.conf <<'NGINX'
    server {
        listen 80 default_server;
        server_name _;

        location / {
            proxy_pass http://${aws_instance.app.private_ip}:5000;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
    NGINX

    systemctl enable nginx
    systemctl restart nginx
  EOF

  tags = {
    Name = "${var.project_name}-vm-nginx"
  }
}
