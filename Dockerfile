FROM adguard/adguardhome:v1.0.0@sha256:f00a586f0d1caa74f149340bfb225014960310488ffa838406b89256900a96c2 AS agh
FROM goacme/lego:v5.7.0@sha256:9fe6151508c0e1ddc51a6d3e474353520f4b008782bf0c6d31676da72e6d4766 AS lego
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS unbound-donor

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates unbound

FROM unbound-donor AS runtime-libs

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN mkdir -p /out && \
    find -L /lib* /usr/lib* -type f 2>/dev/null | \
      while read -r f; do \
        dir="/out$(dirname "$f")" && \
        mkdir -p "$dir" && \
        cp -L "$f" "$dir/"; \
      done

FROM golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG TARGETARCH

WORKDIR /src
COPY go.mod ./
COPY . .

RUN ARCH="${TARGETARCH:-$(uname -m)}" \
    && case "${ARCH}" in x86_64) ARCH="amd64" ;; aarch64) ARCH="arm64" ;; esac \
    && CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -ldflags="-s -w" -trimpath -o /out/supervisor cmd/supervisor/main.go \
    && mkdir -p /out/opt/adguardhome/work \
                /out/opt/adguardhome/conf \
                /out/opt/unbound \
                /out/opt/lego \
                /out/etc/unbound \
                /out/etc/ssl/certs \
                /out/tmp \
                /out/run \
    && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt \
    && cp build/unbound.conf.default /out/etc/unbound/unbound.conf.default \
    && chmod 0700 /out/opt/adguardhome/work \
                  /out/opt/adguardhome/conf \
                  /out/opt/unbound \
                  /out/opt/lego \
    && chmod 1777 /out/tmp /out/run \
    && chmod 0755 /out/etc /out/etc/unbound /out/etc/ssl /out/etc/ssl/certs \
    && chmod 0444 /out/etc/ssl/certs/ca-certificates.crt \
    && chmod 0444 /out/etc/unbound/unbound.conf.default

FROM scratch

ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

COPY --from=runtime-libs /out/ /
COPY --from=builder /out/etc /etc
COPY --from=builder /out/opt /opt
COPY --from=builder /out/tmp /tmp
COPY --from=builder /out/run /run

COPY --from=builder --chmod=0555 /out/supervisor /usr/local/bin/supervisor
COPY --from=agh --chmod=0555 /opt/adguardhome/AdGuardHome /opt/adguardhome/AdGuardHome
COPY --from=lego --chmod=0555 /lego /usr/local/bin/lego
COPY --from=unbound-donor --chmod=0555 /usr/sbin/unbound /usr/local/bin/unbound
COPY --from=unbound-donor --chmod=0555 /usr/sbin/unbound-anchor /usr/local/bin/unbound-anchor

VOLUME ["/opt/adguardhome/conf", "/opt/adguardhome/work", "/opt/unbound", "/opt/lego"]

EXPOSE 53/tcp 53/udp \
       67/udp 68/tcp 68/udp \
       80/tcp 443/tcp 443/udp 3000/tcp \
       853/tcp 853/udp \
       5443/tcp 5443/udp \
       6060/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/supervisor", "health"]

ENTRYPOINT ["/usr/local/bin/supervisor"]
