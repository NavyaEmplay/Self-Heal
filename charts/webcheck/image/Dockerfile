FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl ca-certificates gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl (latest stable)
RUN curl -sL https://dl.k8s.io/release/stable.txt > /tmp/kver && \
    curl -sLO "https://dl.k8s.io/release/$(cat /tmp/kver)/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm -f kubectl /tmp/kver

WORKDIR /opt/scripts
CMD ["/bin/bash"]
