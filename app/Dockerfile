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

# Salin kode aplikasi + aset UI.
COPY app.py ./
COPY static ./static

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 5000

# Jalankan via Waitress (WSGI server, lintas-platform); binding internal saja.
CMD ["python", "app.py"]