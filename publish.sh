#!/bin/zsh
# Put AI DJ online at yask.dev/dj:
#   /dj        showcase page (site/dj, with pre-rendered sets in site/dj/media)
#   /dj/booth  the live app (web/index.html), talking to the engine on this Mac through a Cloudflare quick tunnel
#
#   ./publish.sh            restart engine tunnel (new URL) + deploy
#   ./publish.sh --page     redeploy the pages only, keep the current tunnel
set -e
cd "${0:A:h}"
mkdir -p out

tunnel_url() { grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" out/tunnel.log 2>/dev/null | head -1 || true; }

if [[ "$1" != "--page" ]]; then
  # 1) engine
  if ! lsof -ti tcp:8765 >/dev/null; then
    nohup .venv/bin/python server.py > out/server.log 2>&1 &
    sleep 3
  fi
  # 2) tunnel (quick tunnels get a fresh URL each start)
  pkill -f "cloudflared tunnel --no-autoupdate --url http://localhost:8765" 2>/dev/null || true
  nohup cloudflared tunnel --no-autoupdate --url http://localhost:8765 > out/tunnel.log 2>&1 &
  for i in {1..40}; do URL=$(tunnel_url); [ -n "$URL" ] && break; sleep 1; done
  [ -z "$URL" ] && { echo "tunnel failed"; tail out/tunnel.log; exit 1; }
  H=${URL#https://}
  for i in {1..40}; do  # check via a public resolver: querying the local one too early caches a miss
    IP=$(dig +short @1.1.1.1 "$H" | head -1)
    [ -n "$IP" ] && curl -sf --resolve "$H:443:$IP" "$URL/api/health" >/dev/null && break
    sleep 1
  done
fi
URL=$(tunnel_url)
echo "tunnel: ${URL:-none}"

# 3) pages -> Vercel project ai-dj-web (yask.dev rewrites /dj/* to it)
rm -rf .deploy && mkdir -p .deploy/ai-dj-web
cp -R site/dj .deploy/ai-dj-web/dj
mkdir -p .deploy/ai-dj-web/dj/booth
cp web/index.html .deploy/ai-dj-web/dj/booth/index.html
printf '{"url": "%s"}' "$URL" > .deploy/ai-dj-web/dj/backend.json
cat > .deploy/ai-dj-web/vercel.json <<'JSON'
{"cleanUrls": true, "headers": [
  {"source": "/dj/backend.json", "headers": [{"key": "Cache-Control", "value": "no-store"}]},
  {"source": "/dj/media/(.*)", "headers": [{"key": "Cache-Control", "value": "public, max-age=86400"}]}]}
JSON
[ -d .vercel-link ] && cp -R .vercel-link .deploy/ai-dj-web/.vercel
(cd .deploy/ai-dj-web && vercel deploy --prod --yes >/dev/null 2>../vercel.log && rm -rf ../../.vercel-link && cp -R .vercel ../../.vercel-link) \
  || { cat .deploy/vercel.log; exit 1; }
echo "showcase: https://yask.dev/dj"
echo "booth:    https://yask.dev/dj/booth#key=$(cat .dj_key)"
