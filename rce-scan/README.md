# rce-scan · 运行时高危漏洞自查

某语言爆 RCE 时，一条命令回答：「我们有没有暴露面」。

## 用法

```bash
cd ~/.openclaw/workspace/tools/rce-scan

# 只查本机
python3 run.py --runtime php

# 本机 + 远程 ECS
python3 run.py --runtime php --remote

# 指定实例
python3 run.py --runtime node --remote --instance <your-instance-id>

# 机器可读
python3 run.py --runtime php --remote --json
```

支持 `php / node / java / python / ruby / dotnet`，预设见 `runtimes.conf`。

## 判定分层

| 结论 | 含义 | 退出码 |
|---|---|---|
| `EXPOSED` | 运行时在跑 + 入口转发 + 对外监听 → 真暴露面 | **2** |
| `REACHABLE_INTERNAL` | 有入口但只听 127.0.0.1 | 1 |
| `LATENT` | 只有配置/镜像/已停止容器，未运行 | 0 |
| `PRESENT` | 仅二进制或包，无入口无监听 | 0 |
| `NONE` | 完全没有该运行时 | 0 |

**光有二进制不算暴露。** 必须三者相交才算 `EXPOSED`。

## 五步检查

1. **宿主机**：运行时二进制 + 包管理器记录（brew/rpm/dpkg）
2. **容器**：运行中 **+ 已停止** 的容器、镜像
3. **入口**：Web 服务器**生效配置**（nginx 用 `-T` 取真实合并配置，`*.default` 不算）
4. **监听**：`ss`/`netstat`/`lsof` 看是否 bind 到 `0.0.0.0`
5. **非常驻资产**：停机实例/快照/CI runner（脚本给出待查提示）

## 误报控制

- **web 服务没跑时，配置里有也不算入口**（macOS 自带的 `/etc/apache2/other/php7.conf` 就是典型误报源）
- `.default` 样例配置一律排除
- 包名/镜像是正则交替匹配（`php|php-fpm`），不是字面子串

## 仍需人工确认（脚本做不到的）

1. **容器内**运行时（脚本只看宿主与镜像名）
2. **镜像仓库里存的**镜像（Harbor/registry）
3. 停机实例与**磁盘快照**
4. **CI runner**（GitHub Actions 预装多种运行时）
5. 第三方 SaaS 是否内嵌该运行时

## 只读保证

不修改任何配置、不启停服务、不写目标机器磁盘（远程脚本跑完自删临时文件）。
远程执行走阿里云云助手（`~/.openclaw/aliyun-sms/ecs_run.py`）。
