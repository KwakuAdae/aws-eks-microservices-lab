# Unprivileged nginx: non-root (UID 101), listens on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine

ENV API_UPSTREAM=api:8080
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html app.js styles.css /usr/share/nginx/html/
EXPOSE 8080
