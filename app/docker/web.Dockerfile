# syntax=docker/dockerfile:1
# Contexto de build esperado: ./app/web (não a raiz do repo).
#
# ${API_UPSTREAM} é resolvido em runtime pelo entrypoint oficial da imagem
# nginx, que roda envsubst sobre /etc/nginx/templates/*.template. Por isso a
# mesma imagem serve em qualquer ambiente (compose ou Kubernetes) só trocando
# a env — sem rebuild.

FROM nginx:1.27-alpine

ENV API_UPSTREAM=api:8080

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html app.js styles.css /usr/share/nginx/html/

EXPOSE 8080
