#!/usr/bin/env bash
# Prueba de humo de Tero: recorre los seis servicios a través de la UI y del panel de admin.
# Después comprueba que los seis escriben sus logs en JSON, sin los secretos del .env, y qué
# publica cada servicio en el host: solo ui y admin, y en 127.0.0.1.
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
# 127.0.0.1 y no localhost: los puertos se publican solo en IPv4 y, en Windows, algunos
# clientes prueban primero ::1 y tardan unos 2 s en pasar a IPv4.
UI="http://127.0.0.1:8080"
ADMIN="http://127.0.0.1:8081"
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
published() { # direcciones que el servicio publica en el host, todas: "docker port" las lista
  local id ids out ports=""
  ids="$("${COMPOSE[@]}" ps -q "$1")" || { echo "error-de-compose"; return; }
  if [ -z "$ids" ]; then echo "sin-contenedor"; return; fi
  for id in $ids; do   # puede haber más de un contenedor si el servicio está escalado
    # Si docker port falla, la prueba tiene que fallar: un error nunca cuenta como "ninguno"
    out="$(docker port "$id")" || { echo "error-de-docker-port"; return; }
    ports="$ports$out"$'\n'
  done
  # Solo se sacan las líneas vacías: una salida con otro formato queda en el resultado y la prueba falla
  ports="$(printf '%s' "$ports" | tr -d '\r' | sed '/^$/d; s/.* -> //' | sort -u | paste -sd, -)"
  echo "${ports:-ninguno}"
}
json_logs() { # "ok" si cada línea de los logs del servicio es JSON con time, level, service y msg,
              # y hay al menos un request con method, path, status y duration_ms
  "${COMPOSE[@]}" logs --no-color --no-log-prefix "$1" 2>&1 | node -e '
    const svc = process.argv[1];
    const niveles = ["debug", "info", "warn", "error"];
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const lineas = s.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l.trim());
      if (!lineas.length) return console.log("sin-logs");
      let malas = 0, primera = "", requests = 0;
      for (const l of lineas) {
        let e = null;
        try { e = JSON.parse(l); } catch {}
        const valida = e && typeof e.time === "string" && niveles.includes(e.level) &&
          e.service === svc && typeof e.msg === "string";
        if (!valida) { malas++; if (!primera) primera = l.slice(0, 80); continue; }
        if (e.msg === "request" && typeof e.method === "string" && typeof e.path === "string" &&
            Number.isInteger(e.status) && typeof e.duration_ms === "number") requests++;
      }
      if (malas) return console.log(`${malas} de ${lineas.length} líneas no cumplen: ${primera}`);
      console.log(requests ? "ok" : "sin-requests");
    });' "$1"
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
# Un id con un NUL hace fallar a carts: psycopg2 lo rechaza antes de ir a la base y carts
# responde 500. Más abajo se comprueba que ese 500 queda registrado una sola vez.
check "carts via ui: un id con un NUL da 500" 500 "$(code "$UI/api/carts/%00")"
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
# Un login con un JSON roto que lleva una marca corta. Tiene que dar 400 sin dejar texto ni un
# pedazo del body en los logs: lo comprueban, abajo, json_logs y la prueba de la marca.
MARCA="zq$RANDOM"
check "admin: login con un JSON roto" 400 "$(code -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":$MARCA}" "$ADMIN/auth/login")"
# Lo mismo con una clave que es JSON válido pero no es texto: un número. Tiene hasta 15 dígitos,
# así JSON.parse no pierde precisión y se puede buscar tal cual en los logs.
MARCA_NUM="97531$RANDOM$RANDOM"
check "admin: login con una clave que no es texto" 400 "$(code -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":$MARCA_NUM}" "$ADMIN/auth/login")"

# Logs: los seis servicios escriben una línea JSON por evento, con los mismos campos
for s in ui catalog carts orders checkout admin; do
  check "logs: $s escribe JSON con time, level, service, msg y los requests con campos" ok "$(json_logs "$s")"
done
# Ningún servicio escribe en sus logs los secretos del .env. Los valores pasan por una
# variable de entorno de node y nunca se imprimen.
SECRETS="$("${COMPOSE[@]}" config --format json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s).services;process.stdout.write(JSON.stringify([v.db.environment.POSTGRES_PASSWORD,v.admin.environment.ADMIN_PASSWORD,v.admin.environment.ADMIN_JWT_SECRET]))})')"
check "logs: no aparecen los secretos del .env" ninguno "$("${COMPOSE[@]}" logs --no-color 2>&1 | TERO_SECRETS="$SECRETS" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const sec=JSON.parse(process.env.TERO_SECRETS||"[]").filter(Boolean);console.log(sec.length<3?"faltan-secretos":sec.some(x=>s.includes(x))?"aparecen":"ninguno")})')"
unset SECRETS
check "logs: no aparece el body de los logins mal armados" ninguno "$("${COMPOSE[@]}" logs --no-color 2>&1 | grep -c -e "$MARCA" -e "$MARCA_NUM" | sed 's/^0$/ninguno/')"
check "logs: carts registra cada 500 una sola vez" ninguno "$("${COMPOSE[@]}" logs --no-color carts 2>&1 | grep -c 'Exception in ASGI application' | sed 's/^0$/ninguno/')"

# Red: de los 8 servicios de docker-compose.yml, solo ui y admin se publican en el host, en 127.0.0.1
for s in db redis catalog carts orders checkout; do
  check "red: $s no publica puertos en el host" ninguno "$(published "$s")"
done
check "red: ui se publica solo en 127.0.0.1:8080" 127.0.0.1:8080 "$(published ui)"
check "red: admin se publica solo en 127.0.0.1:8081" 127.0.0.1:8081 "$(published admin)"

echo "---"
echo "Resultado: $pass OK, $fail fallas"
[ "$fail" -eq 0 ]
