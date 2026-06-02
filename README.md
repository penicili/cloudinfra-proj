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