FROM alpine:3.23

LABEL org.opencontainers.image.source=https://github.com/andrewthetechie/home-k8s-pub

RUN apk update && \
    apk add --no-cache rsync openssh gzip bash

COPY sync_media.sh /sync_media.sh

RUN chmod +x /sync_media.sh

ENTRYPOINT [ "/sync_media.sh" ]