#!/usr/bin/env python3
"""
rce-scan 编排器：本地跑 + 远程 ECS 跑 + 合并报告

用法：
  python3 run.py --runtime php
  python3 run.py --runtime node --remote          # 额外跑 ECS
  python3 run.py --runtime php --remote --instance i-xxxx

退出码：任一环境 EXPOSED → 2；REACHABLE_INTERNAL → 1；否则 0
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCAN = os.path.join(HERE, "rce_scan.sh")
ECS_RUN = os.environ.get("ECS_RUN", os.path.expanduser("~/.openclaw/aliyun-sms/ecs_run.py"))
DEFAULT_INSTANCE = os.environ.get("ECS_INSTANCE_ID", "")  # 需要时用环境变量指定


def run_local(runtime: str) -> tuple[list[dict], int]:
    proc = subprocess.run(["bash", SCAN, "--runtime", runtime], capture_output=True, text=True, errors="replace")
    return parse(proc.stdout), proc.returncode


def parse(out: str) -> list[dict]:
    items = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            continue
    return items


def run_remote(runtime: str, instance: str) -> tuple[list[dict], str]:
    """把自包含的 rce_scan.sh 经云助手在 ECS 上执行（v2：预设已内嵌，无需附带 conf）"""
    if not os.path.exists(ECS_RUN):
        return [], "跳过：找不到 ecs_run.py"
    script = os.path.join(HERE, f".remote-{runtime}.sh")
    body = open(SCAN, encoding="utf-8").read()
    with open(script, "w", encoding="utf-8") as f:
        f.write("set -eu\n")
        f.write("TMP=$(mktemp /tmp/rce_scan.XXXXXX.sh)\n")
        f.write("trap 'rm -f \"$TMP\"' EXIT\n")
        # 引号 heredoc：内容不做变量展开，避免本地注入
        f.write("cat > \"$TMP\" <<'REMOTE_EOF'\n")
        f.write(body)
        f.write("\nREMOTE_EOF\n")
        f.write(f"bash \"$TMP\" --runtime {runtime} --json-only\n")
    try:
        proc = subprocess.run(
            ["python3", ECS_RUN, script], capture_output=True, text=True, timeout=300, errors="replace"
        )
        items = parse(proc.stdout)
        if not items:
            return [], f"远程无 JSON 输出（exit {proc.returncode}）：{(proc.stdout or proc.stderr)[:200]}"
        return items, "ok"
    except subprocess.TimeoutExpired:
        return [], "远程超时"
    finally:
        try:
            os.remove(script)
        except OSError:
            pass


LEVEL_ORDER = {"NONE": 0, "PRESENT": 1, "LATENT": 2, "UNKNOWN": 3, "REACHABLE_INTERNAL": 4, "EXPOSED": 5}


def summarize(items: list[dict], label: str) -> dict:
    summary = next((i for i in items if i.get("scope") == "summary"), None)
    level = summary["level"] if summary else "NONE"
    return {
        "env": label,
        "level": level,
        "evidence": [i for i in items if i.get("scope") != "summary"],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--remote", action="store_true", help="额外检查远程 ECS")
    ap.add_argument("--instance", default=DEFAULT_INSTANCE)
    ap.add_argument("--json", action="store_true", help="只输出 JSON 报告")
    ap.add_argument("--out", default=os.path.join(HERE, "last-report.json"))
    args = ap.parse_args()

    local_items, _ = run_local(args.runtime)
    envs = [summarize(local_items, "local")]

    notes = []
    if args.remote:
        remote_items, note = run_remote(args.runtime, args.instance)
        if remote_items:
            envs.append(summarize(remote_items, f"ecs:{args.instance}"))
        else:
            notes.append(note)

    worst = max(envs, key=lambda e: LEVEL_ORDER.get(e["level"], 0))
    report = {
        "runtime": args.runtime,
        "generatedAt": __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds"),
        "worst": worst["level"],
        "environments": envs,
        "notes": notes,
        "meaning": {
            "EXPOSED": "运行时在跑 + 入口转发 + 对外监听 → 立刻补丁或摘流量",
            "REACHABLE_INTERNAL": "有入口但未对外监听 → 尽快升级",
            "LATENT": "只有配置/镜像/已停止容器，运行时未在跑 → 记录，启用前先升级",
            "PRESENT": "仅二进制/包，无入口无监听 → 未暴露",
            "UNKNOWN": "检查不完整（如 nginx -T 无权限）→ 手工复核",
            "NONE": "完全没有该运行时 → 不受影响",
        },
        "residualChecks": [
            "容器内运行时（本脚本只看宿主与镜像名）",
            "镜像仓库里存放的镜像（Harbor/registry）",
            "停机实例与磁盘快照",
            "CI runner（GitHub Actions 预装多种运行时）",
            "第三方 SaaS 是否内嵌该运行时",
        ],
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"运行时：{args.runtime}")
        print(f"最坏结论：{report['worst']} — {report['meaning'][report['worst']]}")
        print("")
        for e in report["environments"]:
            print(f"  [{e['env']}] {e['level']}")
            for ev in e["evidence"][:8]:
                print(f"     - step{ev.get('step')} {ev.get('scope')}: {str(ev.get('evidence'))[:110]}")
        for n in notes:
            print(f"  ! {n}")
        print(f"\n报告已写入：{args.out}")
        print("仍需人工确认：" + "；".join(report["residualChecks"][:3]) + " 等")

    return 2 if report["worst"] == "EXPOSED" else (1 if report["worst"] in ("REACHABLE_INTERNAL", "UNKNOWN") else 0)


if __name__ == "__main__":
    sys.exit(main())
