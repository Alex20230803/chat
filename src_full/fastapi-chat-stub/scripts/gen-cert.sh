#!/usr/bin/env bash
set -euo pipefail
mkdir -p ./scripts
cd ./scripts

if [[ -f cert.pem && -f key.pem ]]; then
  echo "cert.pem/key.pem уже существуют — пропускаю."
  exit 0
fi

# Генерим самоподписанный сертификат (825 дней)
openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost"

echo "Готово: ./scripts/cert.pem и ./scripts/key.pem"
