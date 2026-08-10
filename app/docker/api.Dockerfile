# syntax=docker/dockerfile:1
# Contexto de build esperado: ./app/api (não a raiz do repo).

FROM golang:1.23-alpine AS builder
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -trimpath -o /out/api .

FROM scratch
COPY --from=builder /out/api /api

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/api"]
