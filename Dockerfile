# syntax=docker/dockerfile:1

# ============================================================================
# Stage 1 — build both binaries
# ============================================================================
FROM golang:1.26-bookworm AS build

WORKDIR /src

# Dependencies first, so a source-only edit does not re-download the module graph.
COPY go.mod go.sum ./
RUN --mount=type=cache,id=go-pkg-mod,target=/go/pkg/mod go mod download

COPY . .

# CGO stays off: modernc.org/sqlite is pure Go, so the binaries are static.
ENV CGO_ENABLED=0 GOOS=linux
RUN --mount=type=cache,id=go-pkg-mod,target=/go/pkg/mod \
    --mount=type=cache,id=go-build-cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w" -o /out/zai-api . \
 && go build -trimpath -ldflags="-s -w" -o /out/token-collector ./cmd/token-collector

# ============================================================================
# Stage 2 — Playwright browser + OS dependencies
# ============================================================================
FROM golang:1.26-bookworm AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata curl \
 && rm -rf /var/lib/apt/lists/*

# Keep this pinned to the same playwright-go version as go.mod.
ARG PLAYWRIGHT_GO_VERSION=v0.6201.1
RUN set -eu; \
    for attempt in 1 2 3 4 5; do \
      if go run github.com/mxschmitt/playwright-go/cmd/playwright@${PLAYWRIGHT_GO_VERSION} install --with-deps chromium; then \
        break; \
      fi; \
      if [ "$attempt" = 5 ]; then \
        echo "playwright install failed after $attempt attempts" >&2; \
        exit 1; \
      fi; \
      echo "playwright install attempt $attempt failed; retrying in 10s..." >&2; \
      sleep 10; \
    done; \
    rm -rf /root/.cache/go-build /root/go/pkg/mod

WORKDIR /app

COPY --from=build --chmod=0755 /out/zai-api /out/token-collector /app/

RUN /app/token-collector --install-browsers \
 && rm -rf /root/.cache/ms-playwright-go

ENV LOG_DIR=/data/logs \
    HOST=0.0.0.0 \
    PORT=3007

EXPOSE 3007

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=5 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null || exit 1

CMD ["/app/zai-api", "--db-path", "/data/tokens.sqlite"]
