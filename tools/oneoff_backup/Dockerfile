FROM postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5
RUN apt-get update && apt-get install --no-install-recommends -y python3 git gnupg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
