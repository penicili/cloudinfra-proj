# Image app Flask — berbasis Alpine untuk menghemat RAM (target t2.micro).
FROM python:3.13-alpine

# Salin binary uv dari image resmi astral (tanpa perlu pip install).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Install dependency dulu (lapisan cache terpisah dari kode aplikasi).
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Salin kode aplikasi.
COPY app.py ./

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 5000

# Jalankan via Gunicorn; binding internal saja (tidak di-expose ke host).
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "app:app"]
