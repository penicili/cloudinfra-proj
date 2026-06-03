"""URL Shortener — Flask + Redis.

Bagian dari Tugas Besar UAS Infrastruktur Awan (Telkom University).
Redis dipakai sebagai primary store dengan TTL (SETEX). Aplikasi stateless
sehingga cocok dikontainerisasi; seluruh state berada di Redis.
"""

import os
import secrets
import string

from flask import Flask, jsonify, redirect, request, send_from_directory
import redis
import waitress
import logging
import dotenv


logging.basicConfig(level=logging.INFO)

# --- Konfigurasi ----------------------------------------------------------
dotenv.load_dotenv()
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

# TTL default: 14 hari (2 minggu) dalam detik.
TTL_SECONDS = 14 * 24 * 60 * 60

CODE_LENGTH = 6
CODE_ALPHABET = string.ascii_letters + string.digits

# Objek koneksi dibuat module-level; decode_responses agar nilai berupa str.
db = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    decode_responses=True,
)

app = Flask(__name__)


def generate_code() -> str:
    """Hasilkan kode 6-char alphanumeric yang belum dipakai di Redis."""
    while True:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        if not db.exists(code):
            return code


@app.route("/", methods=["GET"])
def index():
    """Sajikan antarmuka web (single-page)."""
    return send_from_directory(app.static_folder, "index.html")


@app.route("/health", methods=["GET"])
def health():
    """Health check JSON + status koneksi Redis (dipakai badge status di UI)."""
    try:
        db.ping()
        redis_status = "connected"
    except redis.RedisError:
        redis_status = "unavailable"

    return jsonify(
        {
            "service": "url-shortener",
            "redis": redis_status,
            "endpoints": {
                "POST /shorten": 'body {"url": "..."} -> buat short URL',
                "GET /<code>": "redirect 301 ke URL asli",
                "GET /info/<code>": "info URL + sisa TTL",
            },
        }
    )


@app.route("/shorten", methods=["POST"])
def shorten():
    """Terima JSON {"url": "..."}, simpan ke Redis, kembalikan short URL."""
    data = request.get_json(silent=True) or {}
    url = data.get("url")

    if not url or not isinstance(url, str):
        return jsonify({"error": 'field "url" wajib diisi'}), 400

    code = generate_code()
    db.setex(code, TTL_SECONDS, url)

    short_url = request.host_url.rstrip("/") + "/" + code
    return jsonify({"code": code, "short_url": short_url, "url": url}), 201


@app.route("/<code>", methods=["GET"])
def resolve(code: str):
    """Lookup kode di Redis lalu redirect 301 ke URL asli."""
    url = db.get(code)
    if url is None:
        return jsonify({"error": "kode tidak ditemukan atau sudah kedaluwarsa"}), 404
    return redirect(url, code=301)


@app.route("/info/<code>", methods=["GET"])
def info(code: str):
    """Kembalikan URL asli beserta sisa TTL dalam detik dan hari."""
    url = db.get(code)
    if url is None:
        return jsonify({"error": "kode tidak ditemukan atau sudah kedaluwarsa"}), 404

    ttl_seconds = db.ttl(code)
    return jsonify(
        {
            "code": code,
            "url": url,
            "ttl_seconds": ttl_seconds,
            "ttl_days": round(ttl_seconds / 86400, 2) if ttl_seconds > 0 else ttl_seconds,
        }
    )


if __name__ == "__main__":
    # print(REDIS_HOST, REDIS_PORT)
    # exit(0)
    # Cek ke redis
    try:
        db.ping()
        logging.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
    except redis.RedisError as e:
        logging.error(f"Failed to connect to Redis at {REDIS_HOST}:{REDIS_PORT}: {e}")
        exit(1)
    # Hanya untuk development lokal; di container dijalankan via Gunicorn.
    waitress.serve(app, host="0.0.0.0", port=5000)
