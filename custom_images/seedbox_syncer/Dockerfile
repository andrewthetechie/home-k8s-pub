FROM alpine:3.23

RUN apk update && \
    apk add --no-cache rsync openssh gzip bash

COPY sync_media.sh /sync_media.sh

RUN chmod +x /sync_media.sh

ENTRYPOINT [ "/sync_media.sh" ]