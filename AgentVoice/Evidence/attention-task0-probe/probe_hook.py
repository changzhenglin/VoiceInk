#!/usr/bin/python3
"""Task 0 安全字段探针 sink（field-name-only，plan Step 2/7 的探针运行形态）。

从 stdin 读 Claude Code hook JSON，只输出：
  - key path 清单（path / structure / SHA-256(path)）——值零出现
  - hook_event_name（事件名，§8.8 allowlist 允许采集面）
  - session_id / event_id 的 SHA-256 哈希（M1 同式 basis，只输出哈希，不输出原值）

纪律：
  - 不输出/不记录任何 value；stdout/stderr 保持空（防 hook stdout 注入会话上下文）；
  - 失败时只记录 error_code（+ 事件名元数据，若已安全取得）；
  - 三上限与 Swift FieldNameOnlyTokenizer 同语义：body <= 1MiB、容器嵌套 <= 16 层
    （不含根）、字段数 <= 2048；超限整次 fail-closed；
  - shell 变量不得持有完整 payload：settings hook command 直接以 stdin 管道调用本脚本，
    不做命令替换/变量赋值（见 probe-settings-fragment.json 的 _shell_safety 说明）。

event_id 哈希 basis 与 M1 ClaudeCodeAdapter.stablePayloadFingerprint 同式：
  sha256("sid|hook_event_name|canonical" [+ "|delivery_id"])，canonical 为
  sort_keys 紧凑 JSON（排除 seq/delivery_id）。注意：与 Swift JSONSerialization
  的 canonical 字节在极端边角（浮点格式化）可能不逐字节一致——探针内自洽即可，
  不用于与生产 event_id 对撞（known hole，report 记录）。

用法: probe_hook.py <output_dir>
环境变量 VOICECODING_TEST=1 为探针会话标识（生产副作用分离用）。
退出码: 0=ok 2=malformed 3=body_too_large 4=depth_exceeded 5=too_many_fields
        6=root_not_object 64=usage
"""
import sys
import os
import json
import hashlib

MAX_BODY = 1024 * 1024
MAX_DEPTH = 16            # 容器嵌套层数（不含根），与 Swift 同语义
MAX_FIELDS = 2048
MAX_CONTAINER_STACK = MAX_DEPTH + 1

E_OK = 0
E_MALFORMED = 2
E_BODY_TOO_LARGE = 3
E_DEPTH_EXCEEDED = 4
E_TOO_MANY_FIELDS = 5
E_ROOT_NOT_OBJECT = 6


def sha_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class ProbeLimit(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def structure_of(value):
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    if isinstance(value, bool):        # bool 必须先于 int 判定
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if value is None:
        return "null"
    return "unknown"


def join_path(components):
    out = ""
    for c in components:
        if not out:
            out = c
        elif c.startswith("["):
            out += c
        else:
            out += "." + c
    return out


def walk_fields(doc):
    """field-name-only 遍历：只产 (path, structure, hash)；value 不进任何输出。
    根对象自身不出 probe（无父键路径），与 Swift tokenizer 一致。"""
    fields = []

    def emit(components, structure):
        if len(fields) >= MAX_FIELDS:
            raise ProbeLimit(E_TOO_MANY_FIELDS)
        path = join_path(components)
        fields.append({"path": path, "structure": structure, "hash": sha_hex(path)})

    def walk(node, components, container_depth):
        # container_depth = 若 node 为容器时的栈层数（根=1）
        if isinstance(node, dict):
            if container_depth > MAX_CONTAINER_STACK:
                raise ProbeLimit(E_DEPTH_EXCEEDED)
            emit(components, "object")
            for key, value in node.items():
                walk(value, components + [str(key)], container_depth + 1)
        elif isinstance(node, list):
            if container_depth > MAX_CONTAINER_STACK:
                raise ProbeLimit(E_DEPTH_EXCEEDED)
            emit(components, "array")
            for i, value in enumerate(node):
                walk(value, components + ["[%d]" % i], container_depth + 1)
        else:
            emit(components, structure_of(node))

    for key, value in doc.items():
        walk(value, [str(key)], 2)
    return fields


def event_id_hash(doc):
    """M1 同式 basis 的 SHA-256（只输出哈希）。"""
    sid = doc.get("session_id")
    name = doc.get("hook_event_name")
    if not isinstance(sid, str) or not isinstance(name, str):
        return None
    filtered = {k: v for k, v in doc.items() if k not in ("seq", "delivery_id")}
    canonical = json.dumps(filtered, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    basis = "%s|%s|%s" % (sid, name, canonical)
    delivery_id = doc.get("delivery_id")
    if isinstance(delivery_id, str):
        basis += "|" + delivery_id
    return sha_hex(basis)


def append_line(outdir, record):
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "probe-events.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def drain_stdin():
    """超限路径：丢弃剩余 stdin，避免写端 SIGPIPE/EPIPE。"""
    try:
        while sys.stdin.buffer.read(65536):
            pass
    except Exception:
        pass


def main():
    if len(sys.argv) != 2:
        sys.stderr.write(json.dumps({"error_code": "bad_usage"}) + "\n")
        return 64
    outdir = sys.argv[1]
    probe_env = os.environ.get("VOICECODING_TEST", "")

    raw = sys.stdin.buffer.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        drain_stdin()
        append_line(outdir, {"error_code": "body_too_large", "probe_env": probe_env})
        return E_BODY_TOO_LARGE

    try:
        doc = json.loads(raw.decode("utf-8"))
    except Exception:
        append_line(outdir, {"error_code": "malformed_json", "probe_env": probe_env})
        return E_MALFORMED
    if not isinstance(doc, dict):
        append_line(outdir, {"error_code": "root_not_object", "probe_env": probe_env})
        return E_ROOT_NOT_OBJECT

    # 事件名是 §8.8 allowlist 允许面，可在错误行记录（元数据，非 value）
    event_name = doc.get("hook_event_name") if isinstance(doc.get("hook_event_name"), str) else ""

    try:
        fields = walk_fields(doc)
    except ProbeLimit as limit:
        code_name = {E_DEPTH_EXCEEDED: "depth_exceeded",
                     E_TOO_MANY_FIELDS: "too_many_fields"}.get(limit.code, "limit_exceeded")
        append_line(outdir, {"error_code": code_name,
                             "hook_event_name": event_name, "probe_env": probe_env})
        return limit.code

    sid = doc.get("session_id")
    record = {
        "hook_event_name": event_name,
        "session_id_hash": sha_hex(sid) if isinstance(sid, str) else None,
        "event_id_hash": event_id_hash(doc),
        "probe_env": probe_env,
        "field_count": len(fields),
        "fields": fields,
    }
    append_line(outdir, record)
    return E_OK   # stdout/stderr 保持空


if __name__ == "__main__":
    sys.exit(main())
