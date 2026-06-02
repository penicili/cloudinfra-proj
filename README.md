project-uas-cloud/
├── terraform/
│   ├── main.tf          ← EC2, VPC, security group
│   ├── variables.tf
│   └── outputs.tf       ← output IP publik EC2
├── app/
│   ├── app.py           ← Flask
│   └── requirements.txt
├── nginx/
│   └── nginx.conf       ← konfigurasi reverse proxy
├── docker-compose.yml
└── README.md            ← cara deploy ulang

```mermaid
graph TD
    Internet([Internet])
    SG[Security Group\nport 80 + 22 only]
    EC2[EC2 t2.micro\nAmazon Linux 2]
    Docker[Docker Engine]
    Nginx[Container: Nginx\nreverse proxy :80]
    Flask[Container: Flask app\nstateless :5000]
    Redis[Container: Redis\npersistent :6379]

    Internet --> SG
    SG --> EC2
    EC2 --> Docker
    Docker --> Nginx
    Docker --> Flask
    Docker --> Redis