#!/bin/bash
# rce-scan 核心检查器 v2（本地 / 远程共用同一份，自包含）
#
# 只读：不改配置、不启停服务、不写目标磁盘
# 输出：每行一条 JSON；最后一行为 SUMMARY
#
# 用法： rce_scan.sh --runtime php [--json-only]
#
# v2 修复（opus 审查）：
#   - 预设表内嵌（v1 远程执行时相对路径找不到 conf，导致步骤 1 整段被跳过 = 假阴性）
#   - 宿主机进程检查（不再只看 docker）
#   - 入口判定改为「web 服务在跑 + 配置引用运行时 + web 监听对外」→ EXPOSED（php-fpm 只听 unix socket 是常态）
#   - macOS 优先 lsof（v1 的 netstat -lntp 在 Darwin 上语法无效）
#   - 版本探测用 --version + stdin 重定向（python -v / java 无 -v 会挂住）
#   - JSON 转义不再依赖 python3
#   - RUNTIME 白名单校验
set -u

RUNTIME=""; JSON_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --json-only) JSON_ONLY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# 白名单（防注入到正则/JSON）
case "$RUNTIME" in
  php|node|java|python|ruby|dotnet) ;;
  *) echo "runtime must be one of: php node java python ruby dotnet" >&2; exit 64 ;;
esac

# ---- 内嵌预设：BINS(空格分隔) / PKGS_RE(正则) / GREP(正则) / ENTRY(正则) ----
case "$RUNTIME" in
  php)    BINS="php php-fpm php8 php8.2 php8.3 php8.4 php8.5"
          PKGS_RE="php|php-fpm|php-cli|php-common"
          GREP="php|php-fpm"
          ENTRY="fastcgi_pass|proxy_pass.*(9000|php)|\.php|php-fpm" ;;
  node)   BINS="node nodejs pm2"
          PKGS_RE="nodejs|^node$|pm2"
          GREP="node|nodejs|pm2"
          ENTRY="proxy_pass.*(3000|8080)|upstream.*node" ;;
  java)   BINS="java javac"
          PKGS_RE="java|openjdk|jre|jdk"
          GREP="java|openjdk|tomcat|jetty"
          ENTRY="proxy_pass.*(8080|8443)|tomcat|ajp" ;;
  python) BINS="python python3 gunicorn uwsgi"
          PKGS_RE="python3|^python$|gunicorn|uwsgi"
          GREP="python|gunicorn|uwsgi|flask|django"
          ENTRY="proxy_pass.*(8000|5000|8080)|uwsgi_pass|gunicorn" ;;
  ruby)   BINS="ruby puma unicorn"
          PKGS_RE="ruby|puma|unicorn"
          GREP="ruby|puma|unicorn|passenger"
          ENTRY="proxy_pass.*(3000|8080)|passenger" ;;
  dotnet) BINS="dotnet"
          PKGS_RE="dotnet|aspnet"
          GREP="dotnet|aspnet"
          ENTRY="proxy_pass.*(5000|5001)|aspnet|dotnet" ;;
esac

HOST=$(hostname 2>/dev/null || echo unknown)
OS=$(uname -s 2>/dev/null || echo unknown)
H_PRESENT=0; H_RUNPROC=0; H_ENTRY=0; H_PUBLIC=0; H_LATENT=0; UNKNOWN=0

# JSON 字符串转义（不依赖 python3 / jq）
jesc() {
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' | tr '\n' ' ' | cut -c1-300
}
emit() { # level step scope evidence
  printf '{"level":"%s","step":%s,"runtime":"%s","host":"%s","os":"%s","scope":"%s","evidence":"%s"}\n' \
    "$1" "$2" "$RUNTIME" "$(jesc "$HOST")" "$OS" "$(jesc "$3")" "$(jesc "$4")"
}
say() { [ "$JSON_ONLY" -eq 1 ] || echo "$@"; }
has() { command -v "$1" >/dev/null 2>&1; }

# ---------- [1/5] 宿主机：二进制 / 包 / 进程 ----------
say "── [1/5] 宿主机运行时 ──"
for b in $BINS; do
  if has "$b"; then
    p=$(command -v "$b")
    # 版本探测：--version + stdin 重定向（避免 python -v / java 挂住）
    v=$(timeout 5 "$p" --version </dev/null 2>&1 | head -1 | tr -d '\n' | cut -c1-80)
    [ -z "$v" ] && v=$(timeout 5 "$p" -version </dev/null 2>&1 | head -1 | tr -d '\n' | cut -c1-80)
    emit PRESENT 1 host "binary:$b at $p · $v"
    H_PRESENT=1
    say "  二进制: $b ($p) $v"
  fi
done

pkgout=""
if [ "$OS" = "Linux" ]; then
  if has rpm; then pkgout=$(rpm -qa 2>/dev/null | grep -Ei "$PKGS_RE" | head -6)
  elif has dpkg; then pkgout=$(dpkg -l 2>/dev/null | awk '{print $2}' | grep -Ei "$PKGS_RE" | head -6); fi
elif has brew; then
  pkgout=$(brew list --versions 2>/dev/null | grep -Ei "$PKGS_RE" | head -6)
fi
if [ -n "$pkgout" ]; then
  emit PRESENT 1 host "pkgs: $(echo "$pkgout" | tr '\n' ' ')"
  H_PRESENT=1
  say "  包: $(echo "$pkgout" | tr '\n' ' ')"
fi

# 进程（v1 缺这步：只在 docker 里找运行中）
# 用 -x 精确匹配进程名（-f 会匹配到本脚本自己的命令行，如 "--runtime php" → 假阳性）
proc=""
for b in $BINS; do
  h=$(pgrep -x "$b" 2>/dev/null | head -3)
  if [ -n "$h" ]; then
    for pid in $h; do
      pname=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-60)
      proc="$proc ${b}[$pid]:${pname};"
    done
  fi
done
if [ -n "$proc" ]; then
  emit LATENT 1 "process" "$(echo "$proc" | tr '\n' ' ')"
  H_RUNPROC=1
  say "  进程在跑: $(echo "$proc" | tr '\n' ' ')"
fi

# ---------- [2/5] 容器（运行中 / 已停止 / 镜像 / 容器内变量与端口） ----------
say "── [2/5] 容器与镜像 ──"
if has docker; then
  running=$(docker ps --format '{{.ID}}|{{.Image}}|{{.Ports}}' 2>/dev/null | grep -Ei "$GREP|$RUNTIME" | head -6)
  # 镜像名匹配不到时，用容器内环境变量兜底（自建镜像 myapp:latest 也能抓到）
  if [ -z "$running" ]; then
    for cid in $(docker ps -q 2>/dev/null | head -20); do
      envhit=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | grep -Ei "${RUNTIME}_VERSION|${RUNTIME}_HOME|${RUNTIME}_ENV" | head -1)
      if [ -n "$envhit" ]; then
        img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
        ports=$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{$p}}->{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$cid" 2>/dev/null | head -1)
        running="$running${cid}|$img|$ports|env:$envhit "
        if echo "$ports" | grep -q "0.0.0.0"; then H_PUBLIC=1; fi
      fi
    done
  fi
  if [ -n "$running" ]; then
    emit LATENT 2 "container:running" "$(echo "$running" | tr '\n' ' ')"
    H_RUNPROC=1
    say "  运行中命中: $(echo "$running" | tr '\n' ' ' | cut -c1-160)"
    if echo "$running" | grep -q "0.0.0.0"; then H_PUBLIC=1; say "    ⚠ 容器端口映射到 0.0.0.0"; fi
  fi
  stopped=$(docker ps -a --filter status=exited --filter status=created --filter status=dead \
            --format '{{.ID}}|{{.Image}}|{{.Status}}' 2>/dev/null | grep -Ei "$GREP|$RUNTIME" | head -6)
  [ -n "$stopped" ] && { emit LATENT 2 "container:stopped" "$(echo "$stopped" | tr '\n' ' ')"; H_LATENT=1; say "  已停止: $(echo "$stopped" | tr '\n' ' ' | cut -c1-140)"; }
  images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Ei "$GREP|$RUNTIME" | head -6)
  [ -n "$images" ] && { emit LATENT 2 image "$(echo "$images" | tr '\n' ' ')"; H_LATENT=1; say "  镜像: $(echo "$images" | tr '\n' ' ')"; }
  [ -z "$running$stopped$images" ] && say "  docker 可用，无相关容器/镜像"
else
  emit NONE 2 host "docker 不存在"
  say "  无 docker"
fi

# ---------- [3/5] 入口（只看生效配置 + web 是否在跑） ----------
say "── [3/5] Web 入口 ──"
WEB_RUNNING=0
if pgrep -x nginx >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1 || pgrep -x apache2 >/dev/null 2>&1 || pgrep -x caddy >/dev/null 2>&1; then
  WEB_RUNNING=1
fi

conf=""; conf_err=""
if has nginx; then
  if nginx -T >/dev/null 2>&1; then
    conf=$(nginx -T 2>/dev/null | grep -Ev '\.default' | grep -Ei "$ENTRY" | head -5)
  else
    conf_err="nginx -T 需要 root 或配置有误（结果未知，不能当作 NONE）"
  fi
fi
if [ -z "$conf" ] && { has apachectl || has apache2ctl || has httpd; }; then
  conf=$(grep -rEi "$ENTRY" /etc/apache2 /etc/httpd /etc/apache2/other 2>/dev/null | grep -Ev '\.default|\.sample' | head -5)
fi
if [ -z "$conf" ] && has caddy; then
  conf=$(grep -rEi "$ENTRY" /etc/caddy 2>/dev/null | head -5)
fi

if [ -n "$conf_err" ]; then
  emit UNKNOWN 3 host "$conf_err"
  UNKNOWN=1
  say "  ? $conf_err"
elif [ -n "$conf" ] && [ "$WEB_RUNNING" -eq 1 ]; then
  emit REACHABLE_INTERNAL 3 host "$(echo "$conf" | tr '\n' ' ')"
  H_ENTRY=1
  say "  入口命中（web 在跑）: $(echo "$conf" | tr '\n' ' ' | cut -c1-150)"
elif [ -n "$conf" ]; then
  emit LATENT 3 host "config mentions $RUNTIME but no web server running: $(echo "$conf" | tr '\n' ' ')"
  H_LATENT=1
  say "  配置命中但 web 未运行（不计入口）"
else
  emit NONE 3 host "生效配置里无 $RUNTIME 转发"
  say "  生效配置里无相关转发"
fi

# ---------- [4/5] 对外监听 ----------
say "── [4/5] 对外监听 ──"
listen=""
if [ "$OS" = "Darwin" ]; then
  has lsof && listen=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -Ei "$GREP|:80 |:443 " | head -6)
else
  if has ss; then listen=$(ss -lnt 2>/dev/null | grep -Ei ":(80|443|9000|8080|3000|8000|5000) " | head -6)
  elif has netstat; then listen=$(netstat -lnt 2>/dev/null | grep -Ei ":(80|443|9000|8080|3000|8000|5000) " | head -6); fi
fi
if [ -n "$listen" ]; then
  pub=$(echo "$listen" | grep -E "0\.0\.0\.0|\*:|\[::\]" | head -4)
  if [ -n "$pub" ]; then H_PUBLIC=1; say "  ⚠ 对外监听: $(echo "$pub" | tr '\n' ' ' | cut -c1-140)"; fi
  emit LATENT 4 host "listening: $(echo "$listen" | tr '\n' ' ')"
else
  say "  无相关监听或工具不可用"
fi

# ---------- [5/5] 非常驻资产 ----------
say "── [5/5] 非常驻资产 ──"
fivedirs=""
for d in /etc/systemd/system /lib/systemd/system /etc/supervisor/conf.d; do
  [ -d "$d" ] && fivedirs="$fivedirs $(grep -rlEi "$GREP" "$d" 2>/dev/null | head -2 | tr '\n' ' ')"
done
emit NONE 5 host "supervisors:${fivedirs:-none}; stopped instances/snapshots/CI: 需外层 run.py 用云 API 补"
say "  服务单元命中:${fivedirs:- 无}（停机实例/快照/CI 由 run.py 补查）"

# ---------- 判定 ----------
LEVEL=NONE
if [ "$H_ENTRY" -eq 1 ] && [ "$H_PUBLIC" -eq 1 ] && { [ "$H_RUNPROC" -eq 1 ] || [ "$H_PRESENT" -eq 1 ]; }; then
  LEVEL=EXPOSED
elif [ "$H_ENTRY" -eq 1 ]; then
  LEVEL=REACHABLE_INTERNAL
elif [ "$H_LATENT" -eq 1 ] || [ "$H_RUNPROC" -eq 1 ]; then
  LEVEL=LATENT
elif [ "$H_PRESENT" -eq 1 ]; then
  LEVEL=PRESENT
fi
[ "$UNKNOWN" -eq 1 ] && [ "$LEVEL" = "NONE" ] && LEVEL=UNKNOWN

printf '{"level":"%s","step":0,"runtime":"%s","host":"%s","os":"%s","scope":"summary","evidence":"SUMMARY entry=%s public=%s runproc=%s present=%s latent=%s"}\n' \
  "$LEVEL" "$RUNTIME" "$(jesc "$HOST")" "$OS" "$H_ENTRY" "$H_PUBLIC" "$H_RUNPROC" "$H_PRESENT" "$H_LATENT"

say ""
say "== 结论（$HOST · $RUNTIME）: $LEVEL =="
case "$LEVEL" in
  EXPOSED) say "  真暴露面：web 入口转发到该运行时 + 对外监听 → 立刻补丁或摘流量" ;;
  REACHABLE_INTERNAL) say "  有入口但未确认对外监听 → 尽快升级" ;;
  LATENT) say "  潜伏：只有配置/进程/镜像/停止容器 → 记录，启用前先升级" ;;
  PRESENT) say "  仅二进制/包，无入口 → 未暴露" ;;
  UNKNOWN) say "  检查不完整（见上方 ? 行）→ 手工复核" ;;
  NONE) say "  完全没有该运行时 → 不受影响" ;;
esac

case "$LEVEL" in
  EXPOSED) exit 2 ;;
  REACHABLE_INTERNAL|UNKNOWN) exit 1 ;;
  *) exit 0 ;;
esac
