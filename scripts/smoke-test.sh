#!/usr/bin/env bash
# Prueba de humo de Tero: recorre los seis servicios a través de la UI y del panel de admin.
#
# Requisitos: el stack levantado (docker compose up -d), el .env completo, curl y node.
# Uso:        bash scripts/smoke-test.sh [proyecto-de-compose]
#
# No imprime secretos: las credenciales del admin se leen de "docker compose config"
# y van directo al request.
set -u
cd "$(dirname "$0")/.." || exit 1

COMPOSE=(docker compose)
if [ $# -ge 1 ]; then COMPOSE+=(-p "$1"); fi
UI="http://localhost:8080"
ADMIN="http://localhost:8081"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

check() { # nombre esperado obtenido
  if [ "$2" = "$3" ]; then
    echo "OK    $1 ($3)"
    pass=$((pass + 1))
  else
    echo "FALLA $1: esperaba $2, obtuve $3"
    fail=$((fail + 1))
  fi
}
code() { curl -s --max-time 10 -o "$TMP/body" -w '%{http_code}' "$@"; }
body() { echo "      -> $(head -c "${1:-140}" "$TMP/body" | tr '\n' ' ')"; }
wait_for() { # espera hasta 60 s a que la URL responda algo distinto de 000/502/503/504
  local i c=000
  for i in $(seq 1 60); do
    c=$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "$1")
    case "$c" in 000|502|503|504) sleep 1 ;; *) return 0 ;; esac
  done
  echo "AVISO: $1 no respondió en 60 s (último código: $c)"
}

# Los servicios no tienen healthcheck en compose: la UI puede estar arriba antes que los
# backends (mientras tanto el proxy devuelve 504). Se espera a cada uno a través de la UI.
wait_for "$UI/health"
wait_for "$ADMIN/health"
for p in /api/catalog/size /api/carts/espera /api/orders /api/checkout/espera; do
  wait_for "$UI$p"
done

check "ui /health" 200 "$(code "$UI/health")"
check "catalog via ui: GET /api/catalog/size" 200 "$(code "$UI/api/catalog/size")"; body
check "catalog via ui: GET /api/catalog/products" 200 "$(code "$UI/api/catalog/products")"; body 120

CID="smoke-$$-$RANDOM"   # un cliente distinto en cada corrida
check "carts via ui: POST item (escribe en cartdb)" 201 "$(code -X POST -H 'Content-Type: application/json' -d '{"itemId":"smoke-item","quantity":2,"unitPrice":150}' "$UI/api/carts/$CID/items")"
check "carts via ui: GET carrito (lee cartdb)" 200 "$(code "$UI/api/carts/$CID")"; body
check "orders via ui: GET /api/orders" 200 "$(code "$UI/api/orders")"
check "checkout via ui: un checkout inexistente da 404" 404 "$(code "$UI/api/checkout/$CID")"
CHK='{"items":[{"id":"smoke-item","name":"Item de prueba","quantity":2,"price":150}],"shippingAddress":{"firstName":"Ana","lastName":"Prueba","address1":"Calle 1234","city":"Montevideo","state":"MVD","zip":"11000","email":"ana@example.com"},"deliveryOptionToken":"priority-mail"}'
check "checkout via ui: POST update (escribe en redis)" 201 "$(code -X POST -H 'Content-Type: application/json' -d "$CHK" "$UI/api/checkout/$CID/update")"
check "checkout via ui: GET checkout (lee redis)" 200 "$(code "$UI/api/checkout/$CID")"; body
check "checkout via ui: POST submit (checkout -> orders)" 201 "$(code -X POST "$UI/api/checkout/$CID/submit")"; body
check "orders via ui: GET /api/orders después del submit" 200 "$(code "$UI/api/orders")"
if [ "$(cat "$TMP/body")" != "[]" ]; then
  check "orders: la orden del submit quedó guardada en la base" si si
else
  check "orders: la orden del submit quedó guardada en la base" si no
fi

check "admin /health" 200 "$(code "$ADMIN/health")"
check "admin: login con las credenciales viejas (admin/admin)" 401 "$(code -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' "$ADMIN/auth/login")"
LOGIN="$("${COMPOSE[@]}" config --format json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const e=JSON.parse(s).services.admin.environment;process.stdout.write(JSON.stringify({username:e.ADMIN_USERNAME,password:e.ADMIN_PASSWORD}))})')"
check "admin: login con las credenciales del .env" 200 "$(code -c "$TMP/jar" -H 'Content-Type: application/json' -d "$LOGIN" "$ADMIN/auth/login")"
unset LOGIN
check "admin: GET /auth/me con la cookie" 200 "$(code -b "$TMP/jar" "$ADMIN/auth/me")"
check "admin: GET /admin/api/products (lee catalogdb)" 200 "$(code -b "$TMP/jar" "$ADMIN/admin/api/products")"
check "admin: GET /admin/api/orders (lee orders)" 200 "$(code -b "$TMP/jar" "$ADMIN/admin/api/orders")"
check "admin: GET /admin/api/orders sin cookie" 401 "$(code "$ADMIN/admin/api/orders")"

echo "---"
echo "Resultado: $pass OK, $fail fallas"
[ "$fail" -eq 0 ]
