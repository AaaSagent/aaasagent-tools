#!/bin/bash
# 一键部署脚本：类型检查 → 测试 → i18n 审计 → 部署 → 线上验证
#
# 为什么需要它：直接 `wrangler deploy` 在这台 Mac 上会随机超时
#   - CLOUDFLARE_API_TOKEN/ACCOUNT_ID 必须 unset（.env 里那个 token 指向别的账号）
#   - 必须显式走本地代理 127.0.0.1:7897（Node/undici 不走系统代理）
#
# 用法：
#   bash tools/deploy-aaas.sh              # 检查 + 部署 + 线上验证
#   bash tools/deploy-aaas.sh --skip-tests # 跳过测试（不推荐）
#   bash tools/deploy-aaas.sh --dry         # 只跑检查，不部署
set -uo pipefail

REPO="${REPO:-$PWD}"          # 仓库根（默认当前目录）
CORE="${CORE:-$REPO/platform-core}"
PROXY="${LOCAL_PROXY:-}"      # 可选：本地代理，例如 http://127.0.0.1:7897
SITE="${SITE:-}"              # 必填：线上站点，例如 https://example.com
SKIP_TESTS=0
DRY=0

for a in "$@"; do
  case "$a" in
    --skip-tests) SKIP_TESTS=1 ;;
    --dry) DRY=1 ;;
    *) echo "unknown arg: $a"; exit 64 ;;
  esac
done

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

cd "$CORE" || fail "找不到 $CORE"

step "0/5 代理可达性"
if [ -n "$PROXY" ]; then
  hostport="${PROXY#*://}"
  if nc -z -G 3 "${hostport%%:*}" "${hostport##*:}" >/dev/null 2>&1; then ok "代理 $PROXY 可用"
  else fail "代理 $PROXY 不通"; fi
else
  echo "  (未设置 LOCAL_PROXY，直连)"
fi
[ -n "$SITE" ] || fail "请设置 SITE=https://your-domain（用于部署后验证）"

step "1/5 类型检查"
npx tsc --noEmit && ok "tsc 通过" || fail "tsc 失败"

step "2/5 单元测试"
if [ "$SKIP_TESTS" -eq 1 ]; then
  echo "  (已跳过)"
else
  npm test > /tmp/aaas-test.log 2>&1
  line=$(grep -E "^ℹ (tests|pass|fail)" /tmp/aaas-test.log | tr '\n' ' ')
  echo "  $line"
  grep -qE "^ℹ fail 0" /tmp/aaas-test.log && ok "测试全绿" || { tail -20 /tmp/aaas-test.log; fail "测试有失败"; }
fi

step "3/5 i18n 审计（英文页含中文 = 阻断）"
if BASE="$SITE" node scripts/i18n-audit.mjs > /tmp/aaas-i18n.log 2>&1; then
  ok "$(grep -oE 'error: [0-9]+ · warn: [0-9]+' /tmp/aaas-i18n.log | head -1)"
else
  grep -A2 "^\[error\]" /tmp/aaas-i18n.log | head -10
  fail "i18n 有 error（见上）；确认是历史问题可 SKIP_I18N=1 手动绕过"
fi

if [ "$DRY" -eq 1 ]; then
  step "dry-run：不部署"
  exit 0
fi

step "4/5 部署"
PROXY_ENV=""
[ -n "$PROXY" ] && PROXY_ENV="HTTPS_PROXY=$PROXY HTTP_PROXY=$PROXY"
OUT=$(env $PROXY_ENV \
      env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ACCOUNT_ID \
      npx wrangler deploy 2>&1)
echo "$OUT" | grep -E "Uploaded|Current Version ID|ERROR" | sed 's/^/  /'
VER=$(echo "$OUT" | grep -oE "Current Version ID: [0-9a-f-]+" | awk '{print $4}')
[ -n "$VER" ] || fail "部署未返回 Version ID —— 先查线上实际状态，不要假定失败"
ok "版本 $VER"

step "5/5 线上验证（部署成功 ≠ 生效）"
check() { # name url expect
  local n="$1" u="$2" e="$3"
  local code
  code=$(curl -s -o /dev/null -m 15 -w "%{http_code}" "$u?ts=$(date +%s)")
  if [ "$code" = "$e" ]; then ok "$n → HTTP $code"; else fail "$n → HTTP $code（期望 $e）"; fi
}
check "首页"        "$SITE/"         200
check "内测接入页"  "$SITE/beta"     200
check "意见箱"      "$SITE/feedback" 200
check "llms.txt"    "$SITE/llms.txt" 200

# 内容级验证（比状态码更能说明生效）
if curl -s -m 15 "$SITE/llms.txt?ts=$(date +%s)" | grep -q "1f. Contribution score"; then
  ok "llms.txt 含贡献度口径（1f）"
else
  echo "  ⚠ llms.txt 未见 1f（可能是 5 分钟边缘缓存）"
fi

printf '\n\033[32m部署完成：%s\033[0m\n回滚：wrangler rollback %s\n' "$VER" "$VER"
