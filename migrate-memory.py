#!/usr/bin/env python3
"""
migrate-memory.py — OpenClaw 原生记忆 → OpenViking 迁移工具

用法:
  python3 migrate-memory.py                  # 预览（dry-run），不写入
  python3 migrate-memory.py --execute        # 实际迁移 main agent
  python3 migrate-memory.py --agent ke-zong  # 迁移指定 agent
  python3 migrate-memory.py --all --execute  # 迁移所有 agent

原理:
  从 ~/.openclaw/memory/{agent}.sqlite 读取 chunks（记忆文本）
  → 每条 chunk 创建一个 OpenViking session
  → 将文本注入 session messages
  → 调用 /extract 让 VLM 提取记忆写入 viking://user/default/memories/
  → 删除临时 session
"""

import sqlite3
import json
import urllib.request
import urllib.error
import sys
import argparse
from pathlib import Path

OV_BASE = "http://127.0.0.1:1933"


# ── HTTP 工具 ───────────────────────────────────────────────────────────────

def ov_request(method: str, path: str, body=None, timeout: int = 60):
    url = f"{OV_BASE}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read())
            # OpenViking 响应格式：{ status, result } 或直接返回
            if isinstance(payload, dict) and "result" in payload:
                return payload["result"]
            return payload
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body_text[:200]}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"连接失败: {e.reason}")


def check_health() -> bool:
    try:
        result = ov_request("GET", "/health")
        return isinstance(result, dict) and result.get("status") == "ok"
    except Exception:
        return False


def create_session() -> str:
    result = ov_request("POST", "/api/v1/sessions", {})
    session_id = result.get("session_id") if isinstance(result, dict) else None
    if not session_id:
        raise RuntimeError(f"create_session 响应异常: {result}")
    return session_id


def add_message(session_id: str, role: str, content: str):
    ov_request(
        "POST",
        f"/api/v1/sessions/{session_id}/messages",
        {"role": role, "content": content},
    )


def get_session(session_id: str):
    return ov_request("GET", f"/api/v1/sessions/{session_id}")


def extract_memories(session_id: str):
    # VLM（GLM-4.5V）处理时间较长，使用 180s 超时
    return ov_request("POST", f"/api/v1/sessions/{session_id}/extract", {}, timeout=180)


def delete_session(session_id: str):
    try:
        ov_request("DELETE", f"/api/v1/sessions/{session_id}")
    except Exception:
        pass  # 清理失败不中断流程


# ── SQLite 读取 ─────────────────────────────────────────────────────────────

def read_chunks(db_path: Path) -> list[tuple[str, str, str]]:
    """返回 [(chunk_id, path, text), ...]"""
    conn = sqlite3.connect(str(db_path))
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, path, text FROM chunks ORDER BY path, start_line"
        )
        return cur.fetchall()
    finally:
        conn.close()


# ── 迁移逻辑 ────────────────────────────────────────────────────────────────

def migrate_chunks(
    chunks: list[tuple[str, str, str]],
    agent_name: str,
    dry_run: bool,
    min_chars: int = 20,
) -> tuple[int, int, int]:
    """
    返回 (migrated, skipped, failed)
    min_chars: 太短的 chunk 跳过（无意义）
    """
    migrated = skipped = failed = 0

    for chunk_id, path, text in chunks:
        text = text.strip()
        if len(text) < min_chars:
            print(f"  ↷ skip  [{path}] (太短，{len(text)} 字符)")
            skipped += 1
            continue

        label = f"[{path}] ({len(text)} 字符)"
        if dry_run:
            print(f"  ✦ [DRY-RUN] 将迁移 {label}")
            migrated += 1
            continue

        print(f"  ● 迁移 {label}... ", end="", flush=True)
        session_id = None
        try:
            session_id = create_session()
            add_message(
                session_id,
                "system",
                (
                    f"以下内容来自 OpenClaw 原生记忆（agent={agent_name}，"
                    f"文件={path}）。请作为历史用户记忆处理。"
                ),
            )
            add_message(session_id, "user", text)
            # 触发 AGFS 可见性（参考 client.ts 的 workaround）
            get_session(session_id)
            extract_memories(session_id)
            print("OK")
            migrated += 1
        except Exception as e:
            print(f"FAILED — {e}")
            failed += 1
        finally:
            if session_id:
                delete_session(session_id)

    return migrated, skipped, failed


def migrate_db(db_path: Path, agent_name: str, dry_run: bool):
    print(f"\n{'[DRY-RUN] ' if dry_run else ''}迁移 agent: {agent_name}")
    print(f"  数据库: {db_path}")

    chunks = read_chunks(db_path)
    print(f"  共 {len(chunks)} 条 chunk")

    if not chunks:
        print("  没有数据，跳过。")
        return

    migrated, skipped, failed = migrate_chunks(chunks, agent_name, dry_run)

    status = "预览完成" if dry_run else "迁移完成"
    print(f"\n  {status}: ✓ {migrated} 成功  ↷ {skipped} 跳过  ✗ {failed} 失败")


# ── 入口 ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="OpenClaw native memory → OpenViking 迁移工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--agent",
        default="main",
        help="要迁移的 agent 名称（默认: main）",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="迁移所有 agent 的 SQLite 数据库",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="实际写入（不加此参数默认为 dry-run 预览模式）",
    )
    args = parser.parse_args()

    dry_run = not args.execute

    print("╔══════════════════════════════════════════════════╗")
    print("║  OpenClaw 原生记忆 → OpenViking 迁移工具         ║")
    print(f"║  模式: {'dry-run 预览（不写入）' if dry_run else '实际迁移（写入 OpenViking）'}         ║")
    print("╚══════════════════════════════════════════════════╝")
    print()

    # 检查 OpenViking
    print("检查 OpenViking 服务...", end=" ", flush=True)
    if not check_health():
        print("FAILED")
        print("ERROR: OpenViking 未运行在 http://127.0.0.1:1933")
        print("请先启动: launchctl load ~/Library/LaunchAgents/ai.openviking.server.plist")
        sys.exit(1)
    print("OK (health: ok)")

    memory_dir = Path.home() / ".openclaw" / "memory"
    if not memory_dir.exists():
        print(f"ERROR: 目录不存在: {memory_dir}")
        sys.exit(1)

    db_files = sorted(memory_dir.glob("*.sqlite"))
    if not db_files:
        print(f"ERROR: {memory_dir} 下没有 .sqlite 文件")
        sys.exit(1)

    if args.all:
        for db_file in db_files:
            migrate_db(db_file, db_file.stem, dry_run)
    else:
        db_path = memory_dir / f"{args.agent}.sqlite"
        if not db_path.exists():
            available = [f.stem for f in db_files]
            print(f"ERROR: {db_path} 不存在")
            print(f"可用的 agent: {available}")
            sys.exit(1)
        migrate_db(db_path, args.agent, dry_run)

    print()
    if dry_run:
        print("这是 dry-run 预览，没有实际写入。")
        print("确认无误后运行: python3 migrate-memory.py --execute")
    else:
        print("✅ 迁移完成！")
        print("验收命令:")
        print("  ov ls viking://user/default/memories/")
        print("  ov find '你的搜索词'")


if __name__ == "__main__":
    main()
