#!/usr/bin/env python3
"""Assemble results/{test_id}.json from stage/log artifacts."""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--test-id", required=True)
    p.add_argument("--full-name", required=True)
    p.add_argument("--strategy", required=True)
    p.add_argument("--status", required=True)
    p.add_argument("--stages-file", required=True)
    p.add_argument("--log-file", required=True)
    p.add_argument("--peak-mem-file", default="")
    p.add_argument("--image-size-file", default="")
    p.add_argument("--commit-sha", default="")
    p.add_argument("--run-url", default="")
    args = p.parse_args()

    stages = []
    stages_path = Path(args.stages_file)
    if stages_path.is_file():
        for line in stages_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line:
                stages.append(json.loads(line))

    peak_mem = None
    if args.peak_mem_file and Path(args.peak_mem_file).is_file():
        raw = Path(args.peak_mem_file).read_text(encoding="utf-8", errors="ignore").strip()
        digits = "".join(ch for ch in raw if ch.isdigit())
        if digits:
            val = int(digits)
            if val > 0:
                peak_mem = val

    image_size = None
    if args.image_size_file and Path(args.image_size_file).is_file():
        raw = Path(args.image_size_file).read_text(encoding="utf-8", errors="ignore").strip()
        if raw:
            try:
                image_size = float(raw)
            except ValueError:
                image_size = None

    error_tail = ""
    log_path = Path(args.log_file)
    if log_path.is_file():
        lines = log_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        error_tail = "\n".join(lines[-200:])

    result = {
        "test_id": str(args.test_id),
        "full_name": args.full_name,
        "strategy_used": args.strategy,
        "status": args.status,
        "stages": stages,
        "peak_mem_mb": peak_mem,
        "image_size_mb": image_size,
        "error_tail": error_tail,
        "commit_sha": args.commit_sha or None,
        "run_url": args.run_url or None,
        "finished_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
