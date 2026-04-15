FROM vespaengine/vespa:latest

USER root

ARG HTTP_PROXY=http://10.201.6.100:1080
ARG HTTPS_PROXY=http://10.201.6.100:1080
ARG NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.local

ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    no_proxy=${NO_PROXY}

RUN echo "sslverify=false" >> /etc/dnf/dnf.conf && \
    echo "proxy=${HTTP_PROXY}" >> /etc/dnf/dnf.conf && \
    dnf -y install --nogpgcheck curl unzip

RUN curl -fsSLk --proxy "${HTTP_PROXY}" \
    "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip" \
    -o /tmp/bun.zip && \
    unzip -q /tmp/bun.zip -d /tmp/bun && \
    mv /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun && \
    chmod +x /usr/local/bin/bun && \
    rm -rf /tmp/bun.zip /tmp/bun

WORKDIR /app/vespa

COPY server/vespa .

RUN chmod +x deploy-docker.sh && \
    chown -R vespa:vespa /app/vespa

USER vespa

ENTRYPOINT []
CMD ["./deploy-docker.sh"]
