#!/usr/bin/env bash
# =============================================================================
# setup-omni.sh - Stack Sidero Omni On-Premises (Traefik + Dex + Omni)
# usando Docker Compose "include" (v2.20+).
#
# Baseado em:
#   - https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem
#   - https://docs.siderolabs.com/omni/reference/omni-configuration
#   - https://github.com/kenlasko/omni (docker-compose.yaml)
#
# Arquitetura de portas (modelo kenlasko):
#   Traefik publica 80, 443 (UI/API), 8090 (SideroLink/Machine API) e
#   8100 (Kubernetes proxy), todos com TLS Let's Encrypt (DNS-01 Cloudflare),
#   encaminhando ao Omni via h2c/http na rede interna.
#   O Omni publica diretamente apenas 8091/tcp (event sink) e 50180/udp (WireGuard).
#
# Hostnames (sobrescreva por variável de ambiente se quiser):
#   BASE_DOMAIN=aesthar.com.br
#   OMNI_HOST=omni.${BASE_DOMAIN}   AUTH_HOST=auth.${BASE_DOMAIN}
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "[ERRO] Falha na linha ${LINENO}. Abortando." >&2' ERR

# ----------------------------- Variáveis fixas -------------------------------
STACK_DIR="${STACK_DIR:-omni-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-aesthar.com.br}"
OMNI_HOST="${OMNI_HOST:-omni.${BASE_DOMAIN}}"
AUTH_HOST="${AUTH_HOST:-auth.${BASE_DOMAIN}}"
OMNI_ENDPOINT="https://${OMNI_HOST}"
AUTH_ENDPOINT="https://${AUTH_HOST}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.7.12}"
DEX_VERSION="${DEX_VERSION:-v2.41.1}"
NETWORK_NAME="omni-network"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------ Pré-requisitos -------------------------------
for bin in docker gpg openssl curl; do
  command -v "$bin" >/dev/null 2>&1 || die "Dependência ausente: $bin"
done
docker info >/dev/null 2>&1 || die "Docker daemon inacessível (verifique permissões/serviço)."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (>= 2.20) não encontrado."

compose_ver="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
if [[ "$(printf '%s\n2.20.0\n' "$compose_ver" | sort -V | head -n1)" != "2.20.0" ]]; then
  die "Docker Compose ${compose_ver} detectado; é necessário >= 2.20.0 para 'include'."
fi

# Versão mais recente do Omni (mesmo método da documentação oficial)
if [[ -z "${OMNI_VERSION:-}" ]]; then
  OMNI_VERSION="$(curl -fsSI https://github.com/siderolabs/omni/releases/latest 2>/dev/null \
    | grep -i '^location:' | awk -F/ '{print $NF}' | tr -d '\r\n' || true)"
fi
[[ -n "${OMNI_VERSION}" ]] || die "Não foi possível obter a versão do Omni. Execute com OMNI_VERSION=vX.Y.Z ./setup-omni.sh"
log "Versão do Omni: ${OMNI_VERSION}"

if [[ -e "${STACK_DIR}/.env" ]]; then
  read -r -p "'${STACK_DIR}/.env' já existe. Sobrescrever a stack? [s/N] " ans
  [[ "${ans,,}" == "s" ]] || die "Operação cancelada."
fi

# ---------------------------- 1. Árvore de diretórios ------------------------
log "Criando árvore de diretórios em ./${STACK_DIR}"
mkdir -p "${STACK_DIR}"/{traefik/certs,dex,omni/data/{etcd,sqlite}}
cd "${STACK_DIR}"

# ---------------------------- 2. Prompts interativos -------------------------
echo
read -r -s -p "Token de API do Cloudflare (Zone:DNS:Edit): " CF_DNS_API_TOKEN; echo
[[ -n "${CF_DNS_API_TOKEN}" ]] || die "Token do Cloudflare não pode ser vazio."

read -r -p "E-mail do administrador (ex: admin@${BASE_DOMAIN}): " OMNI_USER_EMAIL
[[ "${OMNI_USER_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "E-mail inválido."

read -r -s -p "Senha do administrador (Dex): " ADMIN_PASSWORD; echo
read -r -s -p "Confirme a senha: " ADMIN_PASSWORD_CONFIRM; echo
[[ -n "${ADMIN_PASSWORD}" ]] || die "Senha não pode ser vazia."
[[ "${ADMIN_PASSWORD}" == "${ADMIN_PASSWORD_CONFIRM}" ]] || die "As senhas não conferem."
LE_EMAIL="${OMNI_USER_EMAIL}"

# O WireGuard do Omni exige IP (não hostname) no advertisedEndpoint
HOST_PUBLIC_IP="$(ip route get 1 2>/dev/null \
  | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p' | head -1)"
if [[ -z "${HOST_PUBLIC_IP}" ]]; then
  read -r -p "Não foi possível detectar o IP automaticamente. Informe o IP do host Docker para o WireGuard: " HOST_PUBLIC_IP
fi

# EULA (opcional: se vazio, aceite pela UI em /eula)
read -r -p "Nome completo para aceite do EULA do Omni (vazio = aceitar pela UI): " EULA_NAME

# ---------------------------- 3. Hash Bcrypt (Docker) ------------------------
log "Gerando hash Bcrypt da senha via container httpd:2.4-alpine"
OMNI_USER_PASSWORD_HASH="$(
  docker run --rm httpd:2.4-alpine htpasswd -nbBC 10 "" "${ADMIN_PASSWORD}" \
    | tr -d ':\n' | sed 's/^\$2y/$2a/'
)"
unset ADMIN_PASSWORD ADMIN_PASSWORD_CONFIRM
[[ "${OMNI_USER_PASSWORD_HASH}" == \$2a\$* ]] || die "Falha ao gerar o hash Bcrypt."

# ---------------------------- Segredos auxiliares ----------------------------
OMNI_DEX_SECRET="$(openssl rand -hex 32)"
OMNI_ACCOUNT_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
DEX_USER_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

# ---------------------------- 4. Chave GPG (etcd) ----------------------------
log "Gerando chave GPG para a criptografia do etcd do Omni (sem passphrase)"
GNUPGHOME_TMP="$(mktemp -d)"
chmod 700 "${GNUPGHOME_TMP}"
trap 'rm -rf "${GNUPGHOME_TMP}"' EXIT
export GNUPGHOME="${GNUPGHOME_TMP}"

GPG_UID="Omni (Used for etcd data encryption) omni@internal.local"
gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --quick-generate-key "${GPG_UID}" rsa4096 cert never
GPG_FPR="$(gpg --batch --with-colons --list-keys "omni@internal.local" \
  | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ -n "${GPG_FPR}" ]] || die "Falha ao obter o fingerprint da chave GPG."
gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --quick-add-key "${GPG_FPR}" rsa4096 encr never
gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --armor --export-secret-keys "${GPG_FPR}" > omni/omni.asc
chmod 644 omni/omni.asc
unset GNUPGHOME
log "Chave exportada para omni/omni.asc"

# ---------------------------- Rede compartilhada -----------------------------
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  log "Criando rede Docker '${NETWORK_NAME}'"
  docker network create "${NETWORK_NAME}" >/dev/null
fi

# ---------------------------- 5. Arquivos de configuração --------------------
log "Escrevendo .env"
cat > .env << EOF
BASE_DOMAIN=${BASE_DOMAIN}
OMNI_HOST=${OMNI_HOST}
AUTH_HOST=${AUTH_HOST}
OMNI_ENDPOINT=${OMNI_ENDPOINT}
AUTH_ENDPOINT=${AUTH_ENDPOINT}
HOST_PUBLIC_IP=${HOST_PUBLIC_IP}
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
LE_EMAIL=${LE_EMAIL}
OMNI_USER_EMAIL=${OMNI_USER_EMAIL}
OMNI_USER_PASSWORD_HASH='${OMNI_USER_PASSWORD_HASH}'
OMNI_DEX_SECRET=${OMNI_DEX_SECRET}
TRAEFIK_VERSION=${TRAEFIK_VERSION}
DEX_VERSION=${DEX_VERSION}
OMNI_VERSION=${OMNI_VERSION}
EOF
chmod 600 .env

log "Escrevendo docker-compose.yaml (raiz)"
cat > docker-compose.yaml << 'EOF'
include:
  - path: ./traefik/docker-compose.yaml
    env_file: ./.env
  - path: ./dex/docker-compose.yaml
    env_file: ./.env
  - path: ./omni/docker-compose.yaml
    env_file: ./.env

networks:
  omni-network:
    name: omni-network
    external: true
EOF

# ---- Traefik ----
log "Escrevendo traefik/traefik.yml"
cat > traefik/traefik.yml << EOF
api:
  dashboard: true
  insecure: true

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt
  # Omni Machine API (SideroLink) - TLS terminado no Traefik
  mapi:
    address: ":8090"
    http:
      tls:
        certResolver: letsencrypt
  # Omni Kubernetes proxy - TLS terminado no Traefik
  kproxy:
    address: ":8100"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: ${NETWORK_NAME}

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${LE_EMAIL}"
      storage: /certs/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
EOF

touch traefik/certs/acme.json
chmod 600 traefik/certs/acme.json

log "Escrevendo traefik/docker-compose.yaml"
cat > traefik/docker-compose.yaml << 'EOF'
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
      - "8090:8090"
      - "8100:8100"
    environment:
      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./certs:/certs
    networks:
      - omni-network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=omni-network"
      - "traefik.http.routers.traefik-http.rule=Host(`traefik.${BASE_DOMAIN}`)"
      - "traefik.http.routers.traefik-http.entrypoints=websecure"
      - "traefik.http.routers.traefik-http.tls=true"
      - "traefik.http.routers.traefik-http.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-http.service=api@internal"

networks:
  omni-network:
    name: omni-network
    external: true
EOF

# ---- Dex ----
log "Escrevendo dex/dex.yaml"
cat > dex/dex.yaml << EOF
issuer: ${AUTH_ENDPOINT}

storage:
  type: memory

web:
  http: 0.0.0.0:5556

enablePasswordDB: true

staticClients:
  - id: omni
    name: Omni
    secret: ${OMNI_DEX_SECRET}
    redirectURIs:
      - ${OMNI_ENDPOINT}/oidc/consume

staticPasswords:
  - email: "${OMNI_USER_EMAIL}"
    username: "admin"
    preferredUsername: "admin"
    userID: "${DEX_USER_ID}"
    hash: "${OMNI_USER_PASSWORD_HASH}"
EOF

log "Escrevendo dex/docker-compose.yaml"
cat > dex/docker-compose.yaml << 'EOF'
services:
  dex:
    image: ghcr.io/dexidp/dex:${DEX_VERSION}
    container_name: dex
    restart: unless-stopped
    command: ["dex", "serve", "/etc/dex/dex.yaml"]
    volumes:
      - ./dex.yaml:/etc/dex/dex.yaml:ro
    networks:
      - omni-network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=omni-network"
      - "traefik.http.routers.dex.rule=Host(`${AUTH_HOST}`)"
      - "traefik.http.routers.dex.entrypoints=websecure"
      - "traefik.http.routers.dex.tls=true"
      - "traefik.http.routers.dex.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dex.service=dex"
      - "traefik.http.services.dex.loadbalancer.server.port=5556"

networks:
  omni-network:
    name: omni-network
    external: true
EOF

# ---- Omni ----
log "Escrevendo omni/config.yaml"
cat > omni/config.yaml << EOF
account:
  id: "${OMNI_ACCOUNT_ID}"
  name: "omni-${BASE_DOMAIN}"

services:
  api:
    endpoint: 0.0.0.0:8080
    advertisedURL: "${OMNI_ENDPOINT}/"
  machineAPI:
    endpoint: 0.0.0.0:8090
    advertisedURL: "${OMNI_ENDPOINT}:8090/"
  kubernetesProxy:
    endpoint: 0.0.0.0:8100
    advertisedURL: "${OMNI_ENDPOINT}:8100/"
  siderolink:
    eventSinkPort: 8091
    wireGuard:
      endpoint: 0.0.0.0:50180
      advertisedEndpoint: "${HOST_PUBLIC_IP}:50180"

auth:
  initialUsers:
    - "${OMNI_USER_EMAIL}"
  oidc:
    enabled: true
    providerURL: "${AUTH_ENDPOINT}"
    clientID: "omni"
    clientSecret: "${OMNI_DEX_SECRET}"
    scopes:
      - openid
      - profile
      - email

storage:
  default:
    kind: etcd
    etcd:
      embedded: true
      embeddedDBPath: /_out/etcd
      privateKeySource: "file:///omni.asc"
  sqlite:
    path: /_out/sqlite/omni.db
EOF

if [[ -n "${EULA_NAME}" ]]; then
  cat >> omni/config.yaml << EOF

eulaAccept:
  name: "${EULA_NAME}"
  email: "${OMNI_USER_EMAIL}"
EOF
fi

log "Escrevendo omni/docker-compose.yaml"
cat > omni/docker-compose.yaml << 'EOF'
services:
  omni:
    image: ghcr.io/siderolabs/omni:${OMNI_VERSION}
    container_name: omni
    restart: unless-stopped
    command: ["--config-path=/config.yaml"]
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./config.yaml:/config.yaml:ro
      - ./omni.asc:/omni.asc:ro
      - ./data/etcd:/_out/etcd
      - ./data/sqlite:/_out/sqlite
    ports:
      # 8090 (Machine API) e 8100 (K8s proxy) são publicados pelo Traefik, com TLS.
      - "8091:8091"
      - "50180:50180/udp"
    networks:
      - omni-network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=omni-network"

      # UI + API (porta interna 8080, h2c)
      - "traefik.http.routers.omni.rule=Host(`${OMNI_HOST}`)"
      - "traefik.http.routers.omni.entrypoints=websecure"
      - "traefik.http.routers.omni.tls=true"
      - "traefik.http.routers.omni.tls.certresolver=letsencrypt"
      - "traefik.http.routers.omni.service=omni"
      - "traefik.http.services.omni.loadbalancer.server.port=8080"
      - "traefik.http.services.omni.loadbalancer.server.scheme=h2c"

      # Machine API / SideroLink (8090, h2c)
      - "traefik.http.routers.mapi.rule=Host(`${OMNI_HOST}`)"
      - "traefik.http.routers.mapi.entrypoints=mapi"
      - "traefik.http.routers.mapi.tls=true"
      - "traefik.http.routers.mapi.tls.certresolver=letsencrypt"
      - "traefik.http.routers.mapi.service=mapi"
      - "traefik.http.services.mapi.loadbalancer.server.port=8090"
      - "traefik.http.services.mapi.loadbalancer.server.scheme=h2c"

      # Kubernetes proxy (8100, http)
      - "traefik.http.routers.kproxy.rule=Host(`${OMNI_HOST}`)"
      - "traefik.http.routers.kproxy.entrypoints=kproxy"
      - "traefik.http.routers.kproxy.tls=true"
      - "traefik.http.routers.kproxy.tls.certresolver=letsencrypt"
      - "traefik.http.routers.kproxy.service=kproxy"
      - "traefik.http.services.kproxy.loadbalancer.server.port=8100"
      - "traefik.http.services.kproxy.loadbalancer.server.scheme=http"

networks:
  omni-network:
    name: omni-network
    external: true
EOF

# ---------------------------- Validação final --------------------------------
log "Validando a stack com 'docker compose config'"
docker compose config -q || die "docker-compose.yaml inválido. Revise os arquivos gerados."

echo
log "Stack criada com sucesso em: $(pwd)"
cat << EOF

Próximos passos:
  1. DNS (Cloudflare, SEM proxy/nuvem laranja):
       ${OMNI_HOST}  ->  ${HOST_PUBLIC_IP}
       ${AUTH_HOST}  ->  ${HOST_PUBLIC_IP}
  2. Firewall: 80/tcp, 443/tcp, 8090/tcp, 8091/tcp, 8100/tcp, 50180/udp
  3. Suba a stack:
       cd ${STACK_DIR} && docker compose up -d
  4. Acesse ${OMNI_ENDPOINT} e entre com ${OMNI_USER_EMAIL}
$( [[ -z "${EULA_NAME}" ]] && echo "  5. Aceite o EULA na tela /eula do Omni no primeiro acesso." )

Guarde omni/omni.asc em local seguro: sem ele os dados do etcd não podem ser recuperados.
EOF
