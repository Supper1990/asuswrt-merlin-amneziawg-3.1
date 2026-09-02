# syntax=docker/dockerfile:1
# Reproducible userspace-only AWG 3.1 build for Asuswrt-Merlin ARM64.

ARG AWG_GO_TAG=v3.1.20260828
ARG AWG_TOOLS_TAG=v3.1.20260812

FROM golang:1.25-bookworm AS go-builder
ARG AWG_GO_TAG
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates make \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone --depth 1 --branch "${AWG_GO_TAG}" \
    https://github.com/amnezia-vpn/amneziawg-go.git
RUN cd amneziawg-go \
    && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 make \
    && cp amneziawg-go /amneziawg-go

FROM debian:bookworm AS tools-builder
ARG AWG_TOOLS_TAG
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates make gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone --depth 1 --branch "${AWG_TOOLS_TAG}" \
    https://github.com/amnezia-vpn/amneziawg-tools.git
RUN cd amneziawg-tools/src \
    && make CC=aarch64-linux-gnu-gcc PLATFORM=linux LDFLAGS="-static" \
    && cp wg /awg \
    && aarch64-linux-gnu-strip /awg

FROM scratch AS export
COPY --from=go-builder /amneziawg-go /amneziawg-go
COPY --from=tools-builder /awg /awg
