FROM docker.io/library/debian:bookworm-slim

# Install iptables (required for TPROXY packet interception)
RUN apt-get update && apt-get install -y \
    iptables \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY src/counter /usr/local/bin/counter

ENTRYPOINT ["/usr/local/bin/counter"]