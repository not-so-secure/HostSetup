FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

# Minimal bootstrap — AllInOne.sh handles everything else
RUN apt-get update -qq && apt-get install -y -qq \
    curl ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
COPY AllInOne.sh /root/AllInOne.sh
RUN chmod +x /root/AllInOne.sh
