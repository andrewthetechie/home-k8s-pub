FROM alpine:3.23

LABEL org.opencontainers.image.source=https://github.com/andrewthetechie/home-k8s-pub

RUN apk update && \
    apk add --no-cache rsync openssh gzip bash curl jq bash

COPY sync_media.sh /sync_media.sh
COPY check_isp.sh /check_isp.sh

RUN chmod +x /sync_media.sh && \
    chmod +x /check_isp.sh

ENTRYPOINT [ "/sync_media.sh" ]