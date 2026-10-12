#!/usr/bin/env bash
# One-shot server setup for KidsCall.
#
#   ./scripts/setup.sh
#
# Asks for your domain, generates the secrets, writes server/.env, and starts
# Caddy (HTTPS) + signaling server + coturn with docker compose.
# Re-running it keeps existing secrets and only updates what you change.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=server/.env

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
rand() { openssl rand -base64 36 | tr -d '/+=' | cut -c1-40; }

if ! command -v docker >/dev/null 2>&1; then
  echo "docker が見つかりません。先に Docker をインストールしてください: https://docs.docker.com/engine/install/" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose (v2) が必要です。" >&2
  exit 1
fi

# --- read existing values if any -------------------------------------------
get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
DOMAIN_CUR=$(get DOMAIN)
SETUP_CUR=$(get SETUP_TOKEN)
TURN_CUR=$(get TURN_SECRET)
EXTRA_CUR=$(get TURN_EXTRA_ARGS)

say "KidsCall サーバー セットアップ"
read -r -p "ドメイン名 [${DOMAIN_CUR:-call.example.com}]: " DOMAIN
DOMAIN=${DOMAIN:-${DOMAIN_CUR:-}}
if [[ -z "$DOMAIN" || "$DOMAIN" == "call.example.com" ]]; then
  echo "実際のドメインを入力してください（DNS の A レコードをこのサーバーに向けておくこと）。" >&2
  exit 1
fi

PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
LOCAL_IPS=$(hostname -I 2>/dev/null || true)
EXTRA=${EXTRA_CUR:-}
if [[ -n "$PUBLIC_IP" && -z "$EXTRA" ]] && ! grep -q "$PUBLIC_IP" <<<"$LOCAL_IPS"; then
  echo "このサーバーはグローバル IP ($PUBLIC_IP) を直接持っていないようです（クラウド VPS で一般的）。"
  echo "TURN にグローバル IP を教えます。"
  EXTRA="--external-ip=$PUBLIC_IP"
fi

SETUP_TOKEN=${SETUP_CUR:-$(rand)}
TURN_SECRET=${TURN_CUR:-$(rand)}

# keep any APNS_* lines the user already wrote
APNS_LINES=$(grep -E '^#?APNS_' "$ENV_FILE" 2>/dev/null || true)
if [[ -z "$APNS_LINES" ]]; then
  APNS_LINES=$(grep -E '^#?APNS_' server/.env.example)
fi

cat > "$ENV_FILE" <<ENV
DOMAIN=$DOMAIN
PUBLIC_URL=https://$DOMAIN
SETUP_TOKEN=$SETUP_TOKEN
TURN_SECRET=$TURN_SECRET
TURN_URLS=turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp
STUN_URLS=stun:$DOMAIN:3478
TURN_EXTRA_ARGS=$EXTRA
$APNS_LINES
ENV
chmod 600 "$ENV_FILE"
# docker compose reads ./.env for ${...} interpolation in the compose file
ln -sf server/.env .env
mkdir -p secrets

say "起動します（初回はビルドに数分かかります）"
docker compose up -d --build

say "完了"
cat <<MSG
アプリの「最初の1台として設定する（管理者）」画面に入力する値:

  サーバー URL          : https://$DOMAIN
  セットアップ用の合言葉 : $SETUP_TOKEN

管理者端末の登録が終わったら、$ENV_FILE の SETUP_TOKEN= を空にして
  docker compose restart signaling
を実行してください。以後このサーバーでは誰もグループを作れなくなります。

状態確認: curl https://$DOMAIN/v1/health
ログ    : docker compose logs -f
MSG
