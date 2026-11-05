FROM python:3.12-slim
WORKDIR /srv
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 tick
COPY app ./app
USER tick
# Our own access log (method, path, status, ms; no query string or body) replaces uvicorn's.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --no-access-log --proxy-headers --forwarded-allow-ips='*'"]
