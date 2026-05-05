FROM python:3.12-slim

LABEL maintainer="Ssayan1"
LABEL description="Linux server automation scripts"

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Use faster mirror + minimal packages
RUN apt-get update --fix-missing && apt-get install -y \
    curl \
    openssl \
    net-tools \
    iproute2 \
    bc \
    procps \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN pip install pytest --break-system-packages

WORKDIR /opt/automation

COPY backup.sh health_check.sh ssl_checker.sh .
COPY firewall_audit.sh linux_admin.py generate_dashboard.py .
COPY docker-entrypoint.sh .
COPY tests/ ./tests/

RUN chmod +x backup.sh health_check.sh ssl_checker.sh \
    firewall_audit.sh docker-entrypoint.sh

RUN mkdir -p /var/log /var/backups/server

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["help"]
