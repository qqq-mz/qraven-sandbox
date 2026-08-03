# qraven-sandbox

公开、透明的自动化沙箱：用 GitHub Actions 实测开源 AI 项目的**可部署性**，结果服务于 [qraven.dev](https://qraven.dev)。

## 用途

Qraven 会定期挑选公开 GitHub 仓库，通过 `repository_dispatch` 触发本仓库的 workflow，在干净的 Ubuntu runner 上按优先级尝试：

1. `docker compose up` + 健康检查  
2. `Dockerfile` build/run + 健康检查  
3. Python 包：`pip install .` + import 冒烟  
4. README 安装命令的受限执行（仅对 star ≥ 300 的项目，由调度侧控制）

每次测试采集成败、阶段耗时、峰值内存、镜像体积与失败日志摘要，结果 JSON 写入本仓库 `results/` 目录，再由 Qraven 管道拉取入库并计算可部署性评分。

## 社区与额度说明（风险透明）

- **只测公开开源项目本身的安装/启动路径**，不做压力测试、爬取或挖矿。  
- 每日派发有上限（默认 ≤20），避免滥用 Actions。  
- 本仓库**不存放任何自定义 secret**；workflow 仅使用内置 `GITHUB_TOKEN` 写回 `results/`。  
- 被测代码只在一次性 runner 内执行；结果提交步骤与测试步骤隔离（经文件传递）。  
- 此类「awesome-CI / 可安装性实测」用途在社区中常见；若 GitHub 限流，我们将降频或改用自费 runner。

## 触发方式

```http
POST /repos/qqq-mz/qraven-sandbox/dispatches
{
  "event_type": "deploy-test",
  "client_payload": {
    "owner": "owner",
    "repo": "name",
    "full_name": "owner/name",
    "test_id": "42",
    "allow_readme": false,
    "strategy_hint": "auto"
  }
}
```

## 结果格式

`results/{test_id}.json` 示例字段：`test_id`, `full_name`, `strategy_used`, `status`, `stages`, `peak_mem_mb`, `image_size_mb`, `error_tail`, `commit_sha`, `run_url`, `finished_at`。

## 归属

维护者账号：[qqq-mz](https://github.com/qqq-mz) · 产品站：[qraven.dev](https://qraven.dev) · 主项目文档见 Qraven 仓库。
