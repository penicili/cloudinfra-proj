# URL Shortener — UAS Infrastruktur Awan

Tugas Besar UAS mata kuliah Infrastruktur Awan (BBK3CAB3), Telkom University.

Tujuan akademis: membuktikan secara empiris bahwa **kontainerisasi bersifat
komplementer terhadap virtualisasi (VM), bukan penggantinya**. Stack kontainer
(Flask + Redis + Nginx via Docker Compose) berjalan **di dalam** VM EC2 t2.micro —
merepresentasikan pola managed Kubernetes (kontainer di atas worker node VM).

## Struktur

```
project-uas-cloud/
├── app/
│   ├── app.py             ← Flask application
│   ├── Dockerfile         ← image app (python:3.13-alpine + uv + gunicorn)
│   └── pyproject.toml     ← flask, redis, gunicorn
├── nginx/
│   └── nginx.conf         ← konfigurasi reverse proxy
├── terraform/
│   ├── main.tf            ← EC2, VPC, security group, user_data
│   ├── variables.tf
│   └── outputs.tf         ← output IP publik EC2
├── docker-compose.yml
└── README.md
```

```mermaid
graph TD
    Internet([Internet])
    SG[Security Group<br/>port 80 + 22 only]
    EC2[EC2 t2.micro<br/>Amazon Linux 2]
    Docker[Docker Engine]
    Nginx[Container: Nginx<br/>reverse proxy :80]
    Flask[Container: Flask app<br/>stateless :5000]
    Redis[Container: Redis<br/>persistent :6379]

    Internet --> SG
    SG --> EC2
    EC2 --> Docker
    Docker --> Nginx
    Docker --> Flask
    Docker --> Redis
    Nginx --> Flask
    Flask --> Redis
```

## Endpoint

| Method | Path | Keterangan |
|--------|------|------------|
| `POST` | `/shorten` | Body `{"url": "..."}` → buat kode 6-char, simpan ke Redis (TTL 14 hari), return **201** |
| `GET`  | `/<code>` | Redirect **301** ke URL asli (atau **404**) |
| `GET`  | `/info/<code>` | URL asli + sisa TTL (detik & hari) |
| `GET`  | `/` | Health check + status koneksi Redis |

## Menjalankan secara lokal

```bash
docker compose up -d        # build & jalankan 3 container
docker compose logs -f      # pantau log
docker compose ps           # cek status (hanya nginx yang map :80)
docker compose down         # hentikan
```

### Contoh penggunaan

```bash
# Buat short URL
curl -X POST http://localhost/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://google.com"}'
# -> {"code":"Ab3xZ9","short_url":"http://localhost/Ab3xZ9","url":"https://google.com"}

# Ikuti redirect
curl -L http://localhost/Ab3xZ9

# Lihat info + sisa TTL
curl http://localhost/info/Ab3xZ9
```

## Dua arsitektur Terraform (perbandingan akademis)

Repo menyediakan dua konfigurasi Terraform dengan topologi service yang **sama**
(nginx → flask → redis), untuk membuktikan kontainer komplementer terhadap VM:

| Folder | Arsitektur | Isolasi |
|--------|-----------|---------|
| `terraform/hybrid/` | **3 kontainer di 1 VM** (Docker Compose di atas EC2) | level kontainer + VM |
| `terraform/vm-only/` | **3 VM terpisah** (nginx, flask, redis masing-masing 1 EC2) | level VM + Security Group |

Keduanya pakai key pair AWS yang sama (`key_name` di `terraform.tfvars`).

## Deploy HYBRID — otomatis, tanpa SSH

Alurnya: image `app` di-build di laptop & di-push ke Docker Hub; `terraform apply`
membuat EC2 yang **otomatis** menarik image + menjalankan stack via `user_data`
(tidak perlu `scp`/`ssh` manual).

Prasyarat: kredensial AWS (IAM user, bukan root) & EC2 key pair (untuk SSH darurat saja).

### 1. Build & push image app (di laptop)

```bash
docker login                                   # akun Docker Hub
docker build -t penicili/tubes-infra:v1 ./app  # samakan dengan image: di docker-compose.yml
docker push penicili/tubes-infra:v1
```

### 2. Provision + auto-deploy

```bash
cd terraform/hybrid
cp terraform.tfvars.example terraform.tfvars   # isi key_name & ssh_cidr (sekali saja)
terraform init
terraform apply        # pakai terraform.tfvars; ketik yes
# tunggu ~2-3 menit (user_data: install docker -> pull image -> up -d)
# buka http://<public_ip> dari output
```

`user_data` membaca `docker-compose.yml` + `nginx/nginx.conf` dari repo (via
Terraform `file()`), menanamnya ke `/opt/app` di instance, lalu menjalankan
`docker compose pull && up -d`. Log proses: `sudo cat /var/log/user-data.log`.

> Update image (mis. push `:v2` & ubah tag di `docker-compose.yml`): `terraform apply`
> akan **mengganti instance** otomatis (`user_data_replace_on_change = true`) sehingga
> redeploy tanpa SSH. Untuk update cepat tanpa replace, boleh SSH lalu `docker compose pull && up -d`.

> ⚠️ **Wajib `terraform destroy` setelah demo selesai** (free tier safety).
> ```bash
> terraform destroy
> ```

## Deploy VM-ONLY — 3 VM terpisah (pembanding)

Tiga EC2 (Amazon Linux 2023) masing-masing menjalankan satu service via `user_data`.
nginx (publik :80) → flask (:5000, hanya dari SG nginx) → redis (:6379, hanya dari SG app).
Tidak perlu Docker Hub — tiap VM meng-install service-nya langsung (`dnf`/`pip`).

```bash
cd terraform/vm-only
cp terraform.tfvars.example terraform.tfvars   # isi key_name (sama dgn hybrid) & ssh_cidr
terraform init
terraform apply        # ~13 resource (VPC, IGW, subnet, RT, assoc, 3 SG, 3 EC2)
# buka http://<nginx_public_ip> dari output -> tampil "hello from vm"
```

Outputs: `nginx_public_ip`, `app_private_ip`, `redis_private_ip`. SSH ke nginx:
`ssh -i ~/url-shortener-key.pem ec2-user@<nginx_public_ip>`. Log tiap VM:
`sudo cat /var/log/user-data.log`.

> ⚠️ Sama seperti hybrid — **wajib `terraform destroy`** di `terraform/vm-only/` setelah selesai.

## Skenario uji (Bab V)

1. `POST /shorten` → cek response **201** + `code`.
2. `GET /<code>` → cek redirect **301** (`curl -I`).
3. `GET /info/<code>` → cek `ttl_seconds` berkurang seiring waktu.
4. `docker compose restart redis` → ulangi `GET /info/<code>`, **data tetap ada**
   (named volume `redis-data` + AOF `appendonly`).
5. `docker stats` → catat RAM + CPU per container (target total < 600 MB).
6. Akses Redis port 6379 dari luar VM → **harus gagal** (Security Group hanya buka 80 & 22,
   dan Redis tidak expose port ke host).

## Catatan keamanan

- Hanya port **80** dan **22** dibuka di Security Group AWS.
- Flask (5000) dan Redis (6379) hanya accessible via Docker bridge network — tidak
  di-expose ke host maupun internet.
- Tidak ada credential hardcoded; Redis tanpa auth (internal network only).
- Terraform memakai IAM user least-privilege, bukan root account.
