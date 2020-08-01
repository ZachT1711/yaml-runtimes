FROM alpine:3.12.0

RUN apk update && \
  apk add \
    less \
    git \
    python3 \
    python3-dev \
    py3-pip \
    gcc \
    musl \
    musl-dev \
    wget \
  && true

