#!/usr/bin/env python3
"""Create, append, and replace Feishu Docx documents with a user access token.

The script uses Python's standard library only. Secrets are read from environment
variables, while OAuth user tokens are stored under ~/.codex/feishu/token.json.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlparse
from urllib.request import Request, urlopen


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


API_BASE = "https://open.feishu.cn/open-apis"
AUTH_URL = f"{API_BASE}/authen/v1/authorize"
TOKEN_CACHE = Path.home() / ".codex" / "feishu" / "token.json"
DEFAULT_OAUTH_SCOPES = (
    "docx:document",
    "docs:document.media:upload",
)
PROJECT_APP_ID = ""
PROJECT_REDIRECT_URI = "http://localhost:53682/callback"
EDIT_INTERVAL_SECONDS = 0.4
BLOCK_BATCH_SIZE = 20
BLOCK_UPDATE_BATCH_SIZE = 100
DELETE_BATCH_SIZE = 500
MAX_PARAGRAPH_CHARS = 8_000
TEXT_BLOCK_TYPE = 2
HEADING_BLOCK_TYPES = {
    1: 3,
    2: 4,
    3: 5,
    4: 6,
    5: 7,
    6: 8,
}
BULLET_BLOCK_TYPE = 12
ORDERED_BLOCK_TYPE = 13
CODE_BLOCK_TYPE = 14
IMAGE_BLOCK_TYPE = 27
TABLE_BLOCK_TYPE = 31
MERMAID_SOURCE_KEY = "_codex_mermaid_source"
TABLE_ROWS_KEY = "_codex_table_rows"
MERMAID_CLI_PACKAGE = "@mermaid-js/mermaid-cli"
MERMAID_RENDER_WIDTH = 1_800
MERMAID_DISPLAY_WIDTH = 760
FENCE_START_PATTERN = re.compile(r"^[ \t]*(`{3,})([^`]*)$")
HEADING_PATTERN = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*$")
BULLET_PATTERN = re.compile(r"^[ \t]*[-*+][ \t]+(.+?)[ \t]*$")
ORDERED_PATTERN = re.compile(r"^[ \t]*\d+[.)][ \t]+(.+?)[ \t]*$")
TABLE_SEPARATOR_CELL_PATTERN = re.compile(r"^[ \t]*:?-{3,}:?[ \t]*$")
FOLDER_ALIASES = {}


class FeishuApiError(RuntimeError):
    """Raised when Feishu rejects an API request."""

    def __init__(self, message: str, *, code: Any = None, status: Any = None):
        super().__init__(message)
        self.code = code
        self.status = status


def _json_request(
    method: str,
    path: str,
    *,
    token: str | None = None,
    body: dict[str, Any] | None = None,
    query: dict[str, Any] | None = None,
) -> dict[str, Any]:
    url = f"{API_BASE}{path}"
    if query:
        url = f"{url}?{urlencode(query)}"

    headers = {"Content-Type": "application/json; charset=utf-8"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    request = Request(url, data=data, headers=headers, method=method)

    try:
        with urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
            result = json.loads(payload) if payload else {}
    except HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = {}
        code = parsed.get("code")
        message = parsed.get("msg") or parsed.get("message") or raw or str(error)
        raise FeishuApiError(message, code=code, status=error.code) from error
    except URLError as error:
        raise FeishuApiError(f"无法连接飞书 API：{error.reason}") from error

    code = result.get("code", 0)
    if code != 0:
        raise FeishuApiError(result.get("msg") or "飞书 API 请求失败", code=code)
    return result


def _config_value(name: str) -> str:
    """Read a process variable, then the current Windows user's environment."""
    value = os.environ.get(name, "").strip()
    if value:
        return value

    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                registry_value, _ = winreg.QueryValueEx(key, name)
            value = str(registry_value).strip()
        except (ImportError, FileNotFoundError, OSError):
            value = ""
        if value:
            return value

    project_defaults = {
        "FEISHU_APP_ID": PROJECT_APP_ID,
        "FEISHU_REDIRECT_URI": PROJECT_REDIRECT_URI,
        "FEISHU_OAUTH_SCOPES": " ".join(DEFAULT_OAUTH_SCOPES),
    }
    return project_defaults.get(name, "")


def _required_env(name: str) -> str:
    value = _config_value(name)
    if not value:
        raise FeishuApiError(
            f"缺少环境变量 {name}。请阅读 references/setup.md 完成首次配置。"
        )
    return value


def _host_fingerprint() -> str:
    """Return a non-reversible identifier for the current OS user and device."""
    machine_id = ""
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"SOFTWARE\Microsoft\Cryptography",
            ) as key:
                machine_id, _ = winreg.QueryValueEx(key, "MachineGuid")
        except (ImportError, FileNotFoundError, OSError):
            machine_id = platform.node()
    else:
        for candidate in (Path("/etc/machine-id"), Path("/var/lib/dbus/machine-id")):
            try:
                machine_id = candidate.read_text(encoding="utf-8").strip()
            except OSError:
                continue
            if machine_id:
                break
        if not machine_id:
            machine_id = platform.node()

    identity = f"{os.name}|{machine_id}|{Path.home().resolve()}"
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _required_oauth_scopes(value: str | None = None) -> tuple[str, ...]:
    configured = value or _config_value("FEISHU_OAUTH_SCOPES")
    raw_scopes = re.split(r"[\s,]+", configured.strip()) if configured else []
    # Always include the capabilities required by this Skill. This also upgrades
    # older installations whose user environment still contains only
    # ``docx:document``.
    return tuple(
        dict.fromkeys(
            [*DEFAULT_OAUTH_SCOPES, *(scope for scope in raw_scopes if scope)]
        )
    )


def _require_current_host(cached: dict[str, Any]) -> None:
    cached_host = str(cached.get("host_fingerprint") or "")
    if not cached_host:
        raise FeishuApiError(
            "本机令牌没有设备绑定信息，请运行 authorize 重新完成 OAuth 授权。"
        )
    if not secrets.compare_digest(cached_host, _host_fingerprint()):
        raise FeishuApiError(
            "令牌属于另一台电脑，已拒绝使用。请在当前电脑运行 authorize 完成独立授权。"
        )


def _require_oauth_scopes(cached: dict[str, Any]) -> None:
    required = set(_required_oauth_scopes())
    recorded = set(cached.get("requested_scopes") or [])
    missing = sorted(required - recorded)
    if missing:
        raise FeishuApiError(
            "当前令牌没有记录必需的用户权限："
            f"{', '.join(missing)}。请运行 authorize 重新授权。"
        )


def _load_token_cache() -> dict[str, Any]:
    if not TOKEN_CACHE.exists():
        return {}
    try:
        return json.loads(TOKEN_CACHE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FeishuApiError(f"无法读取令牌缓存 {TOKEN_CACHE}：{error}") from error


def _save_token_cache(token_data: dict[str, Any]) -> None:
    if not token_data.get("access_token"):
        raise FeishuApiError("令牌响应中没有 access_token，未写入缓存。")
    if not token_data.get("refresh_token"):
        raise FeishuApiError("令牌响应中没有 refresh_token，未写入缓存。")

    TOKEN_CACHE.parent.mkdir(parents=True, exist_ok=True)
    now = int(time.time())
    stored = dict(token_data)
    stored["saved_at"] = now
    stored["host_fingerprint"] = _host_fingerprint()
    expires_in = int(stored.get("expires_in") or 0)
    if expires_in:
        stored["expires_at"] = now + expires_in
    refresh_expires_in = int(stored.get("refresh_expires_in") or 0)
    if refresh_expires_in:
        stored["refresh_expires_at"] = now + refresh_expires_in

    temporary_cache = TOKEN_CACHE.with_suffix(".tmp")
    temporary_cache.write_text(
        json.dumps(stored, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    try:
        temporary_cache.chmod(0o600)
    except OSError:
        pass
    temporary_cache.replace(TOKEN_CACHE)


def _get_app_access_token() -> str:
    result = _json_request(
        "POST",
        "/auth/v3/app_access_token/internal",
        body={
            "app_id": _required_env("FEISHU_APP_ID"),
            "app_secret": _required_env("FEISHU_APP_SECRET"),
        },
    )
    token = result.get("app_access_token")
    if not token:
        raise FeishuApiError("飞书没有返回 app_access_token。")
    return str(token)


def _refresh_user_token(
    refresh_token: str,
    requested_scopes: list[str] | tuple[str, ...] | None = None,
) -> dict[str, Any]:
    app_token = _get_app_access_token()
    result = _json_request(
        "POST",
        "/authen/v1/refresh_access_token",
        token=app_token,
        body={
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        },
    )
    token_data = result.get("data") or {}
    if requested_scopes:
        token_data["requested_scopes"] = list(requested_scopes)
    _save_token_cache(token_data)
    return token_data


def _resolve_user_token() -> str:
    cached = _load_token_cache()
    _require_current_host(cached)
    _require_oauth_scopes(cached)
    access_token = str(cached.get("access_token") or "")
    expires_at = int(cached.get("expires_at") or 0)
    if access_token and (not expires_at or time.time() < expires_at - 60):
        return access_token

    refresh_token = str(cached.get("refresh_token") or "")
    if refresh_token:
        return str(
            _refresh_user_token(
                refresh_token,
                cached.get("requested_scopes") or DEFAULT_OAUTH_SCOPES,
            )["access_token"]
        )

    raise FeishuApiError(
        "没有可用的用户访问令牌。请先运行 authorize，"
        "具体步骤见 references/setup.md。"
    )


def _extract_document_id(value: str) -> str:
    value = value.strip()
    match = re.search(r"/docx/([A-Za-z0-9_-]+)", value)
    if match:
        return match.group(1)
    if re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return value
    raise FeishuApiError("无法从输入中识别飞书新版文档 ID。")


def _extract_folder_token(value: str | None) -> str | None:
    if not value:
        return None
    value = value.strip()
    alias_token = FOLDER_ALIASES.get(value.casefold())
    if alias_token:
        return alias_token
    match = re.search(r"/drive/folder/([A-Za-z0-9_-]+)", value)
    if match:
        return match.group(1)
    if re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return value
    raise FeishuApiError("无法从输入中识别飞书 folder_token。")


def _read_content(args: argparse.Namespace, *, optional: bool = False) -> str:
    sources = [args.content is not None, args.content_file is not None, args.stdin]
    if sum(bool(item) for item in sources) > 1:
        raise FeishuApiError("--content、--content-file 和 --stdin 只能选择一个。")
    if args.content is not None:
        content = args.content
    elif args.content_file is not None:
        try:
            content = Path(args.content_file).read_text(encoding="utf-8")
        except OSError as error:
            raise FeishuApiError(f"无法读取内容文件：{error}") from error
    elif args.stdin:
        content = sys.stdin.read()
    elif optional:
        return ""
    else:
        raise FeishuApiError("请通过 --content、--content-file 或 --stdin 提供内容。")

    if not content.strip() and not optional:
        raise FeishuApiError("写入内容不能为空。")
    return content


def _split_long_text(text: str) -> list[str]:
    if len(text) <= MAX_PARAGRAPH_CHARS:
        return [text]
    result: list[str] = []
    remaining = text
    while remaining:
        if len(remaining) <= MAX_PARAGRAPH_CHARS:
            result.append(remaining)
            break
        split_at = remaining.rfind("\n", 0, MAX_PARAGRAPH_CHARS)
        if split_at <= 0:
            split_at = remaining.rfind(" ", 0, MAX_PARAGRAPH_CHARS)
        if split_at <= 0:
            split_at = MAX_PARAGRAPH_CHARS
        result.append(remaining[:split_at])
        remaining = remaining[split_at:].lstrip("\n")
    return result


def _split_long_code(code: str) -> list[str]:
    """Split oversized code without removing indentation or line breaks."""
    if len(code) <= MAX_PARAGRAPH_CHARS:
        return [code]

    result: list[str] = []
    remaining = code
    while remaining:
        if len(remaining) <= MAX_PARAGRAPH_CHARS:
            result.append(remaining)
            break
        split_at = remaining.rfind("\n", 0, MAX_PARAGRAPH_CHARS + 1)
        if split_at <= 0:
            split_at = MAX_PARAGRAPH_CHARS
        else:
            split_at += 1
        result.append(remaining[:split_at])
        remaining = remaining[split_at:]
    return result


def _text_block(text: str) -> dict[str, Any]:
    return {
        "block_type": TEXT_BLOCK_TYPE,
        "text": {
            "elements": [
                {
                    "text_run": {
                        "content": text,
                        "text_element_style": {},
                    }
                }
            ],
            "style": {},
        },
    }


def _heading_block(text: str, level: int) -> dict[str, Any]:
    block_type = HEADING_BLOCK_TYPES[level]
    key = f"heading{level}"
    return {
        "block_type": block_type,
        key: {
            "elements": [
                {
                    "text_run": {
                        "content": text,
                        "text_element_style": {},
                    }
                }
            ],
            "style": {},
        },
    }


def _list_block(text: str, *, ordered: bool) -> dict[str, Any]:
    block_type = ORDERED_BLOCK_TYPE if ordered else BULLET_BLOCK_TYPE
    key = "ordered" if ordered else "bullet"
    return {
        "block_type": block_type,
        key: {
            "elements": [
                {
                    "text_run": {
                        "content": text,
                        "text_element_style": {},
                    }
                }
            ],
            "style": {},
        },
    }


def _code_block(code: str) -> dict[str, Any]:
    return {
        "block_type": CODE_BLOCK_TYPE,
        "code": {
            "elements": [
                {
                    "text_run": {
                        "content": code,
                        "text_element_style": {},
                    }
                }
            ],
            "style": {"wrap": True},
        },
    }


def _mermaid_image_block(source: str) -> dict[str, Any]:
    """Return an internal placeholder rendered during the API write phase."""
    return {MERMAID_SOURCE_KEY: source}


def _table_block(rows: list[list[str]]) -> dict[str, Any]:
    """Return an internal native-table placeholder written during the API phase."""
    return {TABLE_ROWS_KEY: rows}


def _split_markdown_table_row(line: str) -> list[str] | None:
    """Split one Markdown table row while preserving escaped and inline-code pipes."""
    value = line.strip()
    if "|" not in value:
        return None
    if value.startswith("|"):
        value = value[1:]
    if value.endswith("|") and not value.endswith(r"\|"):
        value = value[:-1]

    cells: list[str] = []
    current: list[str] = []
    escaped = False
    in_inline_code = False
    for character in value:
        if escaped:
            current.append(character)
            escaped = False
            continue
        if character == "\\":
            escaped = True
            continue
        if character == "`":
            in_inline_code = not in_inline_code
            current.append(character)
            continue
        if character == "|" and not in_inline_code:
            cells.append("".join(current).strip())
            current.clear()
            continue
        current.append(character)
    if escaped:
        current.append("\\")
    cells.append("".join(current).strip())
    return cells


def _markdown_table_at(lines: list[str], index: int) -> tuple[list[list[str]], int] | None:
    """Parse a Markdown table beginning at index and return rows plus consumed lines."""
    if index + 1 >= len(lines):
        return None
    header = _split_markdown_table_row(lines[index].rstrip("\n"))
    separator = _split_markdown_table_row(lines[index + 1].rstrip("\n"))
    if (
        not header
        or len(header) < 2
        or not separator
        or len(separator) != len(header)
        or not all(TABLE_SEPARATOR_CELL_PATTERN.fullmatch(cell) for cell in separator)
    ):
        return None

    rows = [header]
    cursor = index + 2
    while cursor < len(lines):
        row = _split_markdown_table_row(lines[cursor].rstrip("\n"))
        if row is None or len(row) != len(header):
            break
        rows.append(row)
        cursor += 1
    return rows, cursor - index


def _append_plain_text_blocks(blocks: list[dict[str, Any]], text: str) -> None:
    normalized = text.strip("\n")
    if not normalized.strip():
        return
    for paragraph in re.split(r"\n[ \t]*\n", normalized):
        for part in _split_long_text(paragraph):
            blocks.append(_text_block(part))


def _append_markdown_blocks(blocks: list[dict[str, Any]], text: str) -> None:
    """Convert basic Markdown structure into native Feishu document blocks."""
    paragraph_lines: list[str] = []

    def flush_paragraph() -> None:
        if not paragraph_lines:
            return
        _append_plain_text_blocks(blocks, "".join(paragraph_lines))
        paragraph_lines.clear()

    lines = text.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        line = lines[index]
        line_without_newline = line.rstrip("\n")
        if not line_without_newline.strip():
            flush_paragraph()
            index += 1
            continue

        table = _markdown_table_at(lines, index)
        if table is not None:
            flush_paragraph()
            rows, consumed = table
            blocks.append(_table_block(rows))
            index += consumed
            continue

        heading_match = HEADING_PATTERN.fullmatch(line_without_newline)
        if heading_match:
            flush_paragraph()
            level = len(heading_match.group(1))
            heading = heading_match.group(2).strip()
            for part in _split_long_text(heading):
                blocks.append(_heading_block(part, level))
            index += 1
            continue

        bullet_match = BULLET_PATTERN.fullmatch(line_without_newline)
        if bullet_match:
            flush_paragraph()
            blocks.append(_list_block(bullet_match.group(1), ordered=False))
            index += 1
            continue

        ordered_match = ORDERED_PATTERN.fullmatch(line_without_newline)
        if ordered_match:
            flush_paragraph()
            blocks.append(_list_block(ordered_match.group(1), ordered=True))
            index += 1
            continue

        paragraph_lines.append(line)
        index += 1

    flush_paragraph()


def _content_to_blocks(content: str) -> list[dict[str, Any]]:
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.strip():
        return []

    blocks: list[dict[str, Any]] = []
    text_lines: list[str] = []
    code_lines: list[str] = []
    opening_fence = ""
    opening_line = ""
    opening_language = ""

    for line in normalized.splitlines(keepends=True):
        line_without_newline = line.rstrip("\n")
        if not opening_fence:
            match = FENCE_START_PATTERN.fullmatch(line_without_newline)
            if match:
                _append_markdown_blocks(blocks, "".join(text_lines))
                text_lines.clear()
                opening_fence = match.group(1)
                opening_line = line
                info_string = match.group(2).strip()
                opening_language = (
                    info_string.split(maxsplit=1)[0].casefold()
                    if info_string
                    else ""
                )
                code_lines.clear()
            else:
                text_lines.append(line)
            continue

        closing_pattern = rf"^[ \t]*`{{{len(opening_fence)},}}[ \t]*$"
        if re.fullmatch(closing_pattern, line_without_newline):
            code = "".join(code_lines)
            if code.endswith("\n"):
                code = code[:-1]
            if opening_language == "mermaid":
                # Keep both representations: the rendered image is convenient
                # for readers, and the source block directly below it remains
                # available for later maintenance.
                blocks.append(_mermaid_image_block(code))
            for part in _split_long_code(code):
                blocks.append(_code_block(part))
            opening_fence = ""
            opening_line = ""
            opening_language = ""
            code_lines.clear()
        else:
            code_lines.append(line)

    if opening_fence:
        # An unclosed fence is ordinary text; do not silently change its meaning.
        text_lines.extend([opening_line, *code_lines])
    _append_markdown_blocks(blocks, "".join(text_lines))
    return blocks


def _count_code_blocks(blocks: list[dict[str, Any]]) -> int:
    return sum(block.get("block_type") == CODE_BLOCK_TYPE for block in blocks)


def _count_mermaid_blocks(blocks: list[dict[str, Any]]) -> int:
    return sum(MERMAID_SOURCE_KEY in block for block in blocks)


def _count_table_blocks(blocks: list[dict[str, Any]]) -> int:
    return sum(TABLE_ROWS_KEY in block for block in blocks)


def _count_table_cells(blocks: list[dict[str, Any]]) -> int:
    return sum(
        sum(len(row) for row in block.get(TABLE_ROWS_KEY, []))
        for block in blocks
    )


def _count_heading_blocks(blocks: list[dict[str, Any]]) -> int:
    heading_types = set(HEADING_BLOCK_TYPES.values())
    return sum(block.get("block_type") in heading_types for block in blocks)


def _count_list_blocks(blocks: list[dict[str, Any]]) -> int:
    list_types = {BULLET_BLOCK_TYPE, ORDERED_BLOCK_TYPE}
    return sum(block.get("block_type") in list_types for block in blocks)


def _root_child_count(document_id: str, token: str) -> int:
    count = 0
    page_token: str | None = None
    while True:
        query: dict[str, Any] = {"page_size": 500}
        if page_token:
            query["page_token"] = page_token
        result = _json_request(
            "GET",
            f"/docx/v1/documents/{quote(document_id)}/blocks/"
            f"{quote(document_id)}/children",
            token=token,
            query=query,
        )
        data = result.get("data") or {}
        count += len(data.get("items") or [])
        if not data.get("has_more"):
            return count
        page_token = data.get("page_token")
        if not page_token:
            return count


def _browser_executable() -> str:
    configured = os.environ.get("MERMAID_BROWSER_PATH", "").strip()
    candidates = [
        configured,
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        shutil.which("google-chrome") or "",
        shutil.which("chromium") or "",
        shutil.which("chromium-browser") or "",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    raise FeishuApiError(
        "无法渲染 Mermaid：未找到 Chrome、Edge 或 Chromium。"
        "请安装浏览器，或通过 MERMAID_BROWSER_PATH 指定可执行文件。"
    )


def _mermaid_command() -> list[str]:
    direct = shutil.which("mmdc.cmd" if os.name == "nt" else "mmdc")
    if direct:
        return [direct]

    npx = shutil.which("npx.cmd" if os.name == "nt" else "npx")
    if npx:
        return [npx, "--yes", "-p", MERMAID_CLI_PACKAGE, "mmdc"]

    raise FeishuApiError(
        "无法渲染 Mermaid：未找到 mmdc 或 npx。"
        "请安装 Node.js 和 @mermaid-js/mermaid-cli。"
    )


def _render_mermaid_png(source: str, output_path: Path) -> None:
    if not source.strip():
        raise FeishuApiError("Mermaid 代码为空，无法生成流程图图片。")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    source_path = output_path.with_suffix(".mmd")
    config_path = output_path.with_suffix(".puppeteer.json")
    source_path.write_text(source, encoding="utf-8")
    browser = _browser_executable()
    config_path.write_text(
        json.dumps(
            {
                "executablePath": browser,
                "args": ["--disable-gpu", "--no-sandbox"],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    command = [
        *_mermaid_command(),
        "-i",
        str(source_path),
        "-o",
        str(output_path),
        "-b",
        "white",
        "-w",
        str(MERMAID_RENDER_WIDTH),
        "-s",
        "2",
        "-p",
        str(config_path),
    ]
    environment = os.environ.copy()
    environment["PUPPETEER_SKIP_DOWNLOAD"] = "true"
    environment["PUPPETEER_EXECUTABLE_PATH"] = browser
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=180,
            env=environment,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise FeishuApiError("Mermaid 渲染超过 180 秒，已停止上传。") from error
    except OSError as error:
        raise FeishuApiError(f"无法启动 Mermaid 渲染器：{error}") from error

    if completed.returncode != 0 or not output_path.is_file():
        details = (completed.stderr or completed.stdout or "未知渲染错误").strip()
        raise FeishuApiError(f"Mermaid 渲染失败：{details[-1_500:]}")


def _png_dimensions(path: Path) -> tuple[int, int]:
    try:
        header = path.read_bytes()[:24]
    except OSError as error:
        raise FeishuApiError(f"无法读取 Mermaid 图片：{error}") from error
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise FeishuApiError("Mermaid 渲染结果不是有效的 PNG 图片。")
    width, height = struct.unpack(">II", header[16:24])
    if width <= 0 or height <= 0:
        raise FeishuApiError("Mermaid PNG 图片尺寸无效。")
    return width, height


def _upload_docx_image(
    image_path: Path,
    image_block_id: str,
    token: str,
) -> str:
    boundary = f"codex-feishu-{secrets.token_hex(16)}"
    line_break = b"\r\n"
    payload = bytearray()

    def add_field(name: str, value: str) -> None:
        payload.extend(f"--{boundary}".encode("ascii") + line_break)
        payload.extend(
            f'Content-Disposition: form-data; name="{name}"'.encode("ascii")
            + line_break
            + line_break
        )
        payload.extend(value.encode("utf-8") + line_break)

    add_field("file_name", image_path.name)
    add_field("parent_type", "docx_image")
    add_field("parent_node", image_block_id)
    add_field("size", str(image_path.stat().st_size))
    payload.extend(f"--{boundary}".encode("ascii") + line_break)
    payload.extend(
        (
            f'Content-Disposition: form-data; name="file"; '
            f'filename="{image_path.name}"'
        ).encode("ascii")
        + line_break
    )
    payload.extend(b"Content-Type: image/png" + line_break + line_break)
    payload.extend(image_path.read_bytes() + line_break)
    payload.extend(f"--{boundary}--".encode("ascii") + line_break)

    request = Request(
        f"{API_BASE}/drive/v1/medias/upload_all",
        data=bytes(payload),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=120) as response:
            raw = response.read().decode("utf-8")
    except HTTPError as error:
        raw_error = error.read().decode("utf-8", errors="replace")
        try:
            parsed_error = json.loads(raw_error)
        except json.JSONDecodeError:
            parsed_error = {}
        raise FeishuApiError(
            parsed_error.get("msg") or raw_error or str(error),
            code=parsed_error.get("code"),
            status=error.code,
        ) from error
    except URLError as error:
        raise FeishuApiError(f"无法上传 Mermaid 图片：{error.reason}") from error

    result = json.loads(raw) if raw else {}
    if result.get("code", 0) != 0:
        raise FeishuApiError(
            result.get("msg") or "飞书图片上传失败",
            code=result.get("code"),
        )
    file_token = str((result.get("data") or {}).get("file_token") or "")
    if not file_token:
        raise FeishuApiError("飞书图片上传响应中没有 file_token。")
    return file_token


def _delete_root_range(
    document_id: str,
    start_index: int,
    end_index: int,
    token: str,
) -> None:
    _json_request(
        "DELETE",
        f"/docx/v1/documents/{quote(document_id)}/blocks/"
        f"{quote(document_id)}/children/batch_delete",
        token=token,
        query={"document_revision_id": -1},
        body={"start_index": start_index, "end_index": end_index},
    )


def _append_mermaid_image(
    document_id: str,
    source: str,
    token: str,
    insertion_index: int,
) -> None:
    with tempfile.TemporaryDirectory(prefix="codex-feishu-mermaid-") as temp_dir:
        image_path = Path(temp_dir) / "mermaid.png"
        _render_mermaid_png(source, image_path)
        width, height = _png_dimensions(image_path)

        create_result = _json_request(
            "POST",
            f"/docx/v1/documents/{quote(document_id)}/blocks/"
            f"{quote(document_id)}/children",
            token=token,
            query={"document_revision_id": -1},
            body={
                "children": [{"block_type": IMAGE_BLOCK_TYPE, "image": {}}],
                "index": insertion_index,
            },
        )
        children = (create_result.get("data") or {}).get("children") or []
        image_block_id = str((children[0] if children else {}).get("block_id") or "")
        if not image_block_id:
            try:
                _delete_root_range(
                    document_id,
                    insertion_index,
                    insertion_index + 1,
                    token,
                )
            except FeishuApiError:
                pass
            raise FeishuApiError("飞书创建图片块成功响应中没有 block_id。")

        try:
            file_token = _upload_docx_image(image_path, image_block_id, token)
            scale = round(
                max(0.1, min(1.0, MERMAID_DISPLAY_WIDTH / width)),
                4,
            )
            _json_request(
                "PATCH",
                f"/docx/v1/documents/{quote(document_id)}/blocks/"
                f"{quote(image_block_id)}",
                token=token,
                query={"document_revision_id": -1},
                body={
                    "replace_image": {
                        "token": file_token,
                        "width": width,
                        "height": height,
                        "align": 2,
                        "scale": scale,
                    }
                },
            )
            verify_result = _json_request(
                "GET",
                f"/docx/v1/documents/{quote(document_id)}/blocks/"
                f"{quote(image_block_id)}",
                token=token,
                query={"document_revision_id": -1},
            )
            image = ((verify_result.get("data") or {}).get("block") or {}).get(
                "image"
            ) or {}
            if (
                not image.get("token")
                or int(image.get("width") or 0) <= 0
                or int(image.get("height") or 0) <= 0
            ):
                raise FeishuApiError(
                    "Mermaid 图片块已创建，但 token 或尺寸回读校验失败。"
                )
        except Exception:
            # Avoid leaving a permanent loading placeholder when upload or
            # replace_image fails. Preserve the original error if rollback also
            # fails.
            try:
                _delete_root_range(
                    document_id,
                    insertion_index,
                    insertion_index + 1,
                    token,
                )
            except FeishuApiError:
                pass
            raise


def _table_display_units(text: str) -> int:
    """Estimate rendered width, counting wide CJK characters as two units."""
    plain = re.sub(r"`([^`]*)`", r"\1", text)
    return sum(
        2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1
        for character in plain
    )


def _table_column_widths(rows: list[list[str]]) -> list[int]:
    column_count = len(rows[0])
    widths = []
    for column in range(column_count):
        maximum_units = max(_table_display_units(row[column]) for row in rows)
        widths.append(max(88, min(480, maximum_units * 8 + 48)))

    maximum_total_width = 900
    minimum_width = 88
    if sum(widths) <= maximum_total_width:
        return widths
    flexible_total = sum(width - minimum_width for width in widths)
    available_flexible = maximum_total_width - minimum_width * column_count
    if flexible_total <= 0 or available_flexible <= 0:
        return [minimum_width] * column_count
    scale = available_flexible / flexible_total
    return [
        minimum_width + int((width - minimum_width) * scale)
        for width in widths
    ]


def _table_cell_elements(text: str, *, header: bool) -> list[dict[str, Any]]:
    """Convert inline-code spans into native Feishu text runs."""
    elements: list[dict[str, Any]] = []
    cursor = 0
    for match in re.finditer(r"`([^`]+)`", text):
        if match.start() > cursor:
            style = {"bold": True} if header else {}
            elements.append(
                {
                    "text_run": {
                        "content": text[cursor : match.start()],
                        "text_element_style": style,
                    }
                }
            )
        style = {"inline_code": True}
        if header:
            style["bold"] = True
        elements.append(
            {
                "text_run": {
                    "content": match.group(1),
                    "text_element_style": style,
                }
            }
        )
        cursor = match.end()
    if cursor < len(text) or not elements:
        style = {"bold": True} if header else {}
        elements.append(
            {
                "text_run": {
                    "content": text[cursor:],
                    "text_element_style": style,
                }
            }
        )
    return elements


def _list_document_blocks(document_id: str, token: str) -> list[dict[str, Any]]:
    """Read all document blocks, including nested table-cell paragraphs."""
    blocks: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        query: dict[str, Any] = {
            "page_size": 500,
            "document_revision_id": -1,
        }
        if page_token:
            query["page_token"] = page_token
        result = _json_request(
            "GET",
            f"/docx/v1/documents/{quote(document_id)}/blocks",
            token=token,
            query=query,
        )
        data = result.get("data") or {}
        blocks.extend(data.get("items") or [])
        if not data.get("has_more"):
            return blocks
        page_token = data.get("page_token")
        if not page_token:
            return blocks


def _append_native_table(
    document_id: str,
    rows: list[list[str]],
    token: str,
    insertion_index: int,
) -> None:
    """Create one native Feishu table and populate every cell with rich text."""
    if not rows or not rows[0]:
        raise FeishuApiError("Markdown 表格没有可写入的行或列。")
    column_count = len(rows[0])
    if any(len(row) != column_count for row in rows):
        raise FeishuApiError("Markdown 表格各行的列数不一致。")

    create_result = _json_request(
        "POST",
        f"/docx/v1/documents/{quote(document_id)}/blocks/"
        f"{quote(document_id)}/children",
        token=token,
        query={"document_revision_id": -1},
        body={
            "children": [
                {
                    "block_type": TABLE_BLOCK_TYPE,
                    "table": {
                        "property": {
                            "row_size": len(rows),
                            "column_size": column_count,
                            "column_width": _table_column_widths(rows),
                        }
                    },
                }
            ],
            "index": insertion_index,
        },
    )
    children = (create_result.get("data") or {}).get("children") or []
    table_block = children[0] if children else {}
    table_block_id = str(table_block.get("block_id") or "")
    if not table_block_id:
        raise FeishuApiError("飞书创建原生表格后没有返回 block_id。")

    try:
        table = table_block.get("table") or {}
        cell_ids = list(table.get("cells") or [])
        if len(cell_ids) != len(rows) * column_count:
            get_result = _json_request(
                "GET",
                f"/docx/v1/documents/{quote(document_id)}/blocks/"
                f"{quote(table_block_id)}",
                token=token,
                query={"document_revision_id": -1},
            )
            table = ((get_result.get("data") or {}).get("block") or {}).get("table") or {}
            cell_ids = list(table.get("cells") or [])
        if len(cell_ids) != len(rows) * column_count:
            raise FeishuApiError("飞书原生表格的单元格数量与 Markdown 表格不一致。")

        all_blocks = _list_document_blocks(document_id, token)
        paragraph_by_cell: dict[str, str] = {}
        for block in all_blocks:
            parent_id = str(block.get("parent_id") or "")
            if parent_id in cell_ids and block.get("block_type") == TEXT_BLOCK_TYPE:
                paragraph_by_cell.setdefault(parent_id, str(block.get("block_id") or ""))
        if any(str(cell_id) not in paragraph_by_cell for cell_id in cell_ids):
            raise FeishuApiError("飞书原生表格的默认单元格段落回读不完整。")

        update_requests: list[dict[str, Any]] = []
        for row_index, row in enumerate(rows):
            for column_index, value in enumerate(row):
                cell_id = str(cell_ids[row_index * column_count + column_index])
                update_requests.append(
                    {
                        "block_id": paragraph_by_cell[cell_id],
                        "update_text_elements": {
                            "elements": _table_cell_elements(
                                value,
                                header=row_index == 0,
                            )
                        },
                    }
                )
        for start in range(0, len(update_requests), BLOCK_UPDATE_BATCH_SIZE):
            _json_request(
                "PATCH",
                f"/docx/v1/documents/{quote(document_id)}/blocks/batch_update",
                token=token,
                query={"document_revision_id": -1},
                body={
                    "requests": update_requests[
                        start : start + BLOCK_UPDATE_BATCH_SIZE
                    ]
                },
            )

        verified_blocks = _list_document_blocks(document_id, token)
        verified_content: dict[str, str] = {}
        for block in verified_blocks:
            parent_id = str(block.get("parent_id") or "")
            if parent_id not in cell_ids or block.get("block_type") != TEXT_BLOCK_TYPE:
                continue
            content = "".join(
                (element.get("text_run") or {}).get("content") or ""
                for element in (block.get("text") or {}).get("elements") or []
            )
            verified_content[parent_id] = content
        expected_values = [value.replace("`", "") for row in rows for value in row]
        actual_values = [verified_content.get(str(cell_id), "") for cell_id in cell_ids]
        if actual_values != expected_values:
            raise FeishuApiError("飞书原生表格创建后单元格内容回读校验失败。")
    except Exception:
        try:
            _delete_root_range(
                document_id,
                insertion_index,
                insertion_index + 1,
                token,
            )
        except FeishuApiError:
            pass
        raise


def _append_blocks(
    document_id: str,
    blocks: list[dict[str, Any]],
    token: str,
    *,
    index: int | None = None,
) -> int:
    if not blocks:
        return 0
    insertion_index = (
        _root_child_count(document_id, token)
        if index is None
        else index
    )
    created = 0
    pending: list[dict[str, Any]] = []

    def flush_pending() -> None:
        nonlocal created, insertion_index
        if not pending:
            return
        _json_request(
            "POST",
            f"/docx/v1/documents/{quote(document_id)}/blocks/"
            f"{quote(document_id)}/children",
            token=token,
            query={"document_revision_id": -1},
            body={"children": list(pending), "index": insertion_index},
        )
        insertion_index += len(pending)
        created += len(pending)
        pending.clear()

    for position, block in enumerate(blocks):
        mermaid_source = block.get(MERMAID_SOURCE_KEY)
        table_rows = block.get(TABLE_ROWS_KEY)
        if table_rows is not None:
            flush_pending()
            _append_native_table(
                document_id,
                table_rows,
                token,
                insertion_index,
            )
            insertion_index += 1
            created += 1
        elif mermaid_source is not None:
            flush_pending()
            _append_mermaid_image(
                document_id,
                str(mermaid_source),
                token,
                insertion_index,
            )
            insertion_index += 1
            created += 1
        else:
            pending.append(block)
            if len(pending) >= BLOCK_BATCH_SIZE:
                flush_pending()
        if position + 1 < len(blocks) and not pending:
            time.sleep(EDIT_INTERVAL_SECONDS)
    flush_pending()
    return created


def _delete_root_children(
    document_id: str,
    child_count: int,
    token: str,
) -> int:
    """Delete the first root children from the end toward the beginning."""
    deleted = 0
    end_index = child_count
    while end_index > 0:
        start_index = max(0, end_index - DELETE_BATCH_SIZE)
        _json_request(
            "DELETE",
            f"/docx/v1/documents/{quote(document_id)}/blocks/"
            f"{quote(document_id)}/children/batch_delete",
            token=token,
            query={"document_revision_id": -1},
            body={
                "start_index": start_index,
                "end_index": end_index,
            },
        )
        deleted += end_index - start_index
        end_index = start_index
        if end_index > 0:
            time.sleep(EDIT_INTERVAL_SECONDS)
    return deleted


def _document_url(document_id: str) -> str:
    domain = os.environ.get("FEISHU_TENANT_DOMAIN", "").strip().rstrip("/")
    if domain:
        if not domain.startswith(("http://", "https://")):
            domain = f"https://{domain}"
        return f"{domain}/docx/{document_id}"
    return f"https://feishu.cn/docx/{document_id}"


def _add_content_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--content", help="直接提供要写入的 UTF-8 文本")
    parser.add_argument("--content-file", help="读取 UTF-8 文本或 Markdown 文件")
    parser.add_argument("--stdin", action="store_true", help="从标准输入读取内容")


def command_configure(_: argparse.Namespace) -> dict[str, Any]:
    """Persist the OAuth settings for the current Windows user."""
    if os.name != "nt":
        raise FeishuApiError(
            "configure 当前只支持 Windows；macOS/Linux 请按 references/setup.md 设置环境变量。"
        )

    app_id = _config_value("FEISHU_APP_ID") or input("请输入飞书应用的 App ID：").strip()
    if not app_id:
        raise FeishuApiError("App ID 不能为空。")
    redirect_uri = _config_value("FEISHU_REDIRECT_URI")
    app_secret = _config_value("FEISHU_APP_SECRET")
    if not app_secret:
        app_secret = getpass.getpass(
            "请输入飞书应用的 App Secret（输入不会回显）："
        ).strip()
    if not app_secret:
        raise FeishuApiError("App Secret 不能为空。")

    try:
        import winreg

        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            values = {
                "FEISHU_APP_ID": app_id,
                "FEISHU_APP_SECRET": app_secret,
                "FEISHU_REDIRECT_URI": redirect_uri,
                "FEISHU_OAUTH_SCOPES": " ".join(DEFAULT_OAUTH_SCOPES),
            }
            for name, value in values.items():
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
    except (ImportError, OSError) as error:
        raise FeishuApiError(f"无法保存当前 Windows 用户的飞书配置：{error}") from error

    return {
        "configured": True,
        "app_id": app_id,
        "redirect_uri": redirect_uri,
        "required_oauth_scopes": DEFAULT_OAUTH_SCOPES,
        "app_secret_saved": True,
        "app_secret_exposed": False,
        "next_command": "authorize --open-browser",
    }


def _authorization_url(
    redirect_uri: str,
    state: str,
    scopes: tuple[str, ...],
) -> str:
    app_id = _required_env("FEISHU_APP_ID")
    return f"{AUTH_URL}?{urlencode({'app_id': app_id, 'redirect_uri': redirect_uri, 'scope': ' '.join(scopes), 'state': state})}"


def command_auth_url(args: argparse.Namespace) -> dict[str, Any]:
    redirect_uri = args.redirect_uri or _required_env("FEISHU_REDIRECT_URI")
    state = args.state or secrets.token_urlsafe(18)
    scopes = _required_oauth_scopes(args.scopes)
    url = _authorization_url(redirect_uri, state, scopes)
    return {"authorization_url": url, "state": state, "requested_scopes": scopes}


def _exchange_code(
    code: str,
    requested_scopes: tuple[str, ...] | None = None,
) -> dict[str, Any]:
    if not code:
        raise FeishuApiError("授权码不能为空。")
    app_token = _get_app_access_token()
    result = _json_request(
        "POST",
        "/authen/v1/access_token",
        token=app_token,
        body={"grant_type": "authorization_code", "code": code},
    )
    token_data = result.get("data") or {}
    token_data["requested_scopes"] = list(
        requested_scopes or DEFAULT_OAUTH_SCOPES
    )
    _save_token_cache(token_data)
    return {
        "authorized": True,
        "token_cache": str(TOKEN_CACHE),
        "access_token_saved": True,
        "refresh_token_saved": True,
        "expires_in": token_data.get("expires_in"),
        "refresh_expires_in": token_data.get("refresh_expires_in"),
    }


def command_exchange_code(args: argparse.Namespace) -> dict[str, Any]:
    code = args.code or getpass.getpass("请输入回调 URL 中的一次性 code：").strip()
    return _exchange_code(code, _required_oauth_scopes(args.scopes))


def command_authorize(args: argparse.Namespace) -> dict[str, Any]:
    """Complete OAuth through a temporary loopback callback server."""
    if args.timeout_seconds <= 0:
        raise FeishuApiError("--timeout-seconds 必须大于 0。")
    _required_env("FEISHU_APP_SECRET")

    redirect_uri = args.redirect_uri or _required_env("FEISHU_REDIRECT_URI")
    parsed_redirect = urlparse(redirect_uri)
    if parsed_redirect.scheme != "http" or parsed_redirect.hostname not in {
        "localhost",
        "127.0.0.1",
    }:
        raise FeishuApiError(
            "authorize 仅接受 http://localhost 或 http://127.0.0.1 回调地址。"
        )
    if not parsed_redirect.port:
        raise FeishuApiError("OAuth 本地回调地址必须明确包含端口号。")

    expected_path = parsed_redirect.path or "/"
    expected_state = secrets.token_urlsafe(24)
    scopes = _required_oauth_scopes(args.scopes)
    authorization_url = _authorization_url(redirect_uri, expected_state, scopes)
    callback_result: dict[str, str] = {}

    class OAuthCallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - inherited HTTP handler name
            request_url = urlparse(self.path)
            if request_url.path != expected_path:
                self.send_error(404)
                return

            query = parse_qs(request_url.query)
            returned_state = (query.get("state") or [""])[0]
            if not secrets.compare_digest(returned_state, expected_state):
                callback_result["error"] = "OAuth state 校验失败，授权结果已拒绝。"
            elif query.get("error"):
                description = (query.get("error_description") or query["error"])[0]
                callback_result["error"] = f"飞书拒绝了授权：{description}"
            else:
                callback_result["code"] = (query.get("code") or [""])[0]
                if not callback_result["code"]:
                    callback_result["error"] = "OAuth 回调中没有 code。"

            success = "code" in callback_result
            title = "飞书授权成功" if success else "飞书授权失败"
            message = (
                "授权信息已安全接收，可以关闭此页面。"
                if success
                else "授权结果未通过校验，请返回终端查看原因。"
            )
            html = (
                "<!doctype html><html><head><meta charset='utf-8'>"
                f"<title>{title}</title></head><body><h2>{title}</h2>"
                f"<p>{message}</p></body></html>"
            ).encode("utf-8")
            self.send_response(200 if success else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)

        def log_message(self, _: str, *__: Any) -> None:
            # The default log includes the callback URL and one-time code.
            return

    try:
        server = HTTPServer(("127.0.0.1", parsed_redirect.port), OAuthCallbackHandler)
    except OSError as error:
        raise FeishuApiError(
            f"无法监听 OAuth 回调端口 {parsed_redirect.port}：{error}"
        ) from error

    print(
        json.dumps(
            {
                "authorization_required": True,
                "authorization_url": authorization_url,
                "requested_scopes": scopes,
                "timeout_seconds": args.timeout_seconds,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    if args.open_browser:
        webbrowser.open(authorization_url)

    deadline = time.monotonic() + args.timeout_seconds
    try:
        while not callback_result and time.monotonic() < deadline:
            server.timeout = min(1.0, max(0.1, deadline - time.monotonic()))
            server.handle_request()
    except KeyboardInterrupt:
        raise FeishuApiError("OAuth 授权已取消。") from None
    finally:
        server.server_close()

    if not callback_result:
        raise FeishuApiError("等待飞书 OAuth 回调超时，请重新运行 authorize。")
    if callback_result.get("error"):
        raise FeishuApiError(callback_result["error"])
    return _exchange_code(callback_result["code"], scopes)


def command_status(_: argparse.Namespace) -> dict[str, Any]:
    """Report token availability without exposing token values."""
    cached = _load_token_cache()
    now = int(time.time())
    cached_host = str(cached.get("host_fingerprint") or "")
    host_matches = bool(cached_host) and secrets.compare_digest(
        cached_host,
        _host_fingerprint(),
    )
    required_scopes = set(_required_oauth_scopes())
    recorded_scopes = set(cached.get("requested_scopes") or [])
    scopes_satisfied = required_scopes.issubset(recorded_scopes)
    expires_at = int(cached.get("expires_at") or 0)
    refresh_expires_at = int(cached.get("refresh_expires_at") or 0)
    return {
        "app_id_configured": bool(_config_value("FEISHU_APP_ID")),
        "app_secret_configured": bool(_config_value("FEISHU_APP_SECRET")),
        "redirect_uri_configured": bool(_config_value("FEISHU_REDIRECT_URI")),
        "token_cache": str(TOKEN_CACHE),
        "token_cache_exists": TOKEN_CACHE.exists(),
        "token_bound_to_current_device": host_matches,
        "required_oauth_scopes": sorted(required_scopes),
        "recorded_oauth_scopes": sorted(recorded_scopes),
        "required_oauth_scopes_satisfied": scopes_satisfied,
        "access_token_saved": bool(cached.get("access_token")),
        "refresh_token_saved": bool(cached.get("refresh_token")),
        "access_token_valid": host_matches
        and scopes_satisfied
        and bool(cached.get("access_token"))
        and (not expires_at or now < expires_at - 60),
        "access_token_seconds_remaining": max(0, expires_at - now)
        if expires_at
        else None,
        "refresh_token_valid": host_matches
        and scopes_satisfied
        and bool(cached.get("refresh_token"))
        and (not refresh_expires_at or now < refresh_expires_at - 60),
        "refresh_token_seconds_remaining": max(0, refresh_expires_at - now)
        if refresh_expires_at
        else None,
    }


def command_refresh(_: argparse.Namespace) -> dict[str, Any]:
    cached = _load_token_cache()
    _require_current_host(cached)
    _require_oauth_scopes(cached)
    refresh_token = str(cached.get("refresh_token") or "")
    if not refresh_token:
        raise FeishuApiError("令牌缓存中没有 refresh_token，请重新完成 OAuth 授权。")
    token_data = _refresh_user_token(
        refresh_token,
        cached.get("requested_scopes") or DEFAULT_OAUTH_SCOPES,
    )
    return {
        "refreshed": True,
        "token_cache": str(TOKEN_CACHE),
        "expires_in": token_data.get("expires_in"),
    }


def command_create(args: argparse.Namespace) -> dict[str, Any]:
    content = _read_content(args, optional=True)
    blocks = _content_to_blocks(content)
    folder_token = _extract_folder_token(args.folder)
    preview = {
        "action": "create",
        "title": args.title,
        "folder_token": folder_token,
        "content_chars": len(content),
        "planned_blocks": len(blocks),
        "planned_heading_blocks": _count_heading_blocks(blocks),
        "planned_list_blocks": _count_list_blocks(blocks),
        "planned_code_blocks": _count_code_blocks(blocks),
        "planned_mermaid_images": _count_mermaid_blocks(blocks),
        "planned_table_blocks": _count_table_blocks(blocks),
        "planned_table_cells": _count_table_cells(blocks),
    }
    if args.dry_run:
        return {"dry_run": True, **preview}

    token = _resolve_user_token()
    body: dict[str, Any] = {"title": args.title}
    if folder_token:
        body["folder_token"] = folder_token
    result = _json_request("POST", "/docx/v1/documents", token=token, body=body)
    document = (result.get("data") or {}).get("document") or {}
    document_id = str(document.get("document_id") or "")
    if not document_id:
        raise FeishuApiError("飞书创建文档成功响应中没有 document_id。")
    created_blocks = _append_blocks(document_id, blocks, token)
    return {
        "created": True,
        "document_id": document_id,
        "url": _document_url(document_id),
        "title": document.get("title") or args.title,
        "created_blocks": created_blocks,
    }


def command_append(args: argparse.Namespace) -> dict[str, Any]:
    document_id = _extract_document_id(args.document)
    content = _read_content(args)
    blocks = _content_to_blocks(content)
    preview = {
        "action": "append",
        "document_id": document_id,
        "content_chars": len(content),
        "planned_blocks": len(blocks),
        "planned_heading_blocks": _count_heading_blocks(blocks),
        "planned_list_blocks": _count_list_blocks(blocks),
        "planned_code_blocks": _count_code_blocks(blocks),
        "planned_mermaid_images": _count_mermaid_blocks(blocks),
        "planned_table_blocks": _count_table_blocks(blocks),
        "planned_table_cells": _count_table_cells(blocks),
    }
    if args.dry_run:
        return {"dry_run": True, **preview}

    token = _resolve_user_token()
    before = _root_child_count(document_id, token)
    created = _append_blocks(document_id, blocks, token)
    after = _root_child_count(document_id, token)
    if after < before + created:
        raise FeishuApiError("写入请求已返回成功，但块数量校验未通过，请打开文档核对。")
    return {
        "appended": True,
        "document_id": document_id,
        "url": _document_url(document_id),
        "created_blocks": created,
        "root_blocks_before": before,
        "root_blocks_after": after,
    }


def command_replace(args: argparse.Namespace) -> dict[str, Any]:
    """Replace all root content blocks while keeping the document itself."""
    document_id = _extract_document_id(args.document)
    content = _read_content(args)
    blocks = _content_to_blocks(content)
    preview = {
        "action": "replace",
        "document_id": document_id,
        "content_chars": len(content),
        "planned_blocks": len(blocks),
        "planned_heading_blocks": _count_heading_blocks(blocks),
        "planned_list_blocks": _count_list_blocks(blocks),
        "planned_code_blocks": _count_code_blocks(blocks),
        "planned_mermaid_images": _count_mermaid_blocks(blocks),
        "planned_table_blocks": _count_table_blocks(blocks),
        "planned_table_cells": _count_table_cells(blocks),
        "requires_confirmation": True,
    }
    if args.dry_run:
        return {"dry_run": True, **preview}
    if not args.confirm_replace:
        raise FeishuApiError(
            "替换会删除文档现有正文。请先执行 --dry-run 核对，"
            "确认后添加 --confirm-replace。"
        )

    token = _resolve_user_token()
    before = _root_child_count(document_id, token)

    # Append and verify the complete replacement first. If this phase fails, the
    # original content remains intact and a later retry can safely replace both.
    created = _append_blocks(document_id, blocks, token, index=before)
    after_append = _root_child_count(document_id, token)
    expected_after_append = before + created
    if after_append != expected_after_append:
        raise FeishuApiError(
            "新正文已尝试写入，但追加后的块数量校验未通过。"
            "为保护原文，本次没有删除旧正文；请打开文档核对后重试。"
        )

    deleted = _delete_root_children(document_id, before, token)
    after_replace = _root_child_count(document_id, token)
    if after_replace != created:
        raise FeishuApiError(
            "替换请求已完成，但最终块数量校验未通过，请打开文档核对。"
        )

    return {
        "replaced": True,
        "document_id": document_id,
        "url": _document_url(document_id),
        "created_blocks": created,
        "deleted_blocks": deleted,
        "root_blocks_before": before,
        "root_blocks_after": after_replace,
    }


def _read_sensitive_value(environment_name: str, prompt: str) -> str:
    value = os.environ.get(environment_name, "")
    if not value:
        value = getpass.getpass(prompt)
    if not value:
        raise FeishuApiError(f"{environment_name} 对应的敏感值不能为空。")
    return value


def command_write_credentials(args: argparse.Namespace) -> dict[str, Any]:
    document_id = _extract_document_id(args.document)
    if args.dry_run:
        return {
            "dry_run": True,
            "action": "write_credentials",
            "document_id": document_id,
            "fields": ["App Secret", "Token"],
            "values_exposed": False,
        }
    if not args.confirm_sensitive_upload:
        raise FeishuApiError(
            "写入真实凭证前必须添加 --confirm-sensitive-upload，"
            "并确认目标文档的分享范围和历史版本风险。"
        )

    app_secret = _read_sensitive_value(
        "FEISHU_CREDENTIAL_APP_SECRET",
        "请输入要写入文档的 App Secret（输入不会回显）：",
    )
    credential_token = _read_sensitive_value(
        "FEISHU_CREDENTIAL_TOKEN",
        "请输入要写入文档的 Token（输入不会回显）：",
    )
    blocks = _content_to_blocks(
        f"App Secret\n{app_secret}\n\nToken\n{credential_token}"
    )
    token = _resolve_user_token()
    created = _append_blocks(document_id, blocks, token)
    return {
        "credentials_written": True,
        "document_id": document_id,
        "url": _document_url(document_id),
        "created_blocks": created,
        "values_exposed": False,
    }


def command_check(args: argparse.Namespace) -> dict[str, Any]:
    document_id = _extract_document_id(args.document)
    token = _resolve_user_token()
    result = _json_request(
        "GET",
        f"/docx/v1/documents/{quote(document_id)}",
        token=token,
    )
    document = (result.get("data") or {}).get("document") or {}
    return {
        "accessible": True,
        "document_id": document_id,
        "url": _document_url(document_id),
        "title": document.get("title"),
        "revision_id": document.get("revision_id"),
        "root_block_count": _root_child_count(document_id, token),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="使用飞书用户身份创建、追加、替换和检查新版文档。"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    configure = subparsers.add_parser(
        "configure",
        help="安全输入 App Secret 并保存本项目 OAuth 配置",
    )
    configure.set_defaults(handler=command_configure)

    auth_url = subparsers.add_parser("auth-url", help="生成用户 OAuth 授权链接")
    auth_url.add_argument("--redirect-uri", help="覆盖 FEISHU_REDIRECT_URI")
    auth_url.add_argument("--state", help="可选的 OAuth state")
    auth_url.add_argument(
        "--scopes",
        help="空格或逗号分隔的附加用户权限；文档编辑和图片上传权限始终包含",
    )
    auth_url.set_defaults(handler=command_auth_url)

    authorize = subparsers.add_parser(
        "authorize",
        help="启动本地回调并一次完成用户 OAuth 授权",
    )
    authorize.add_argument("--redirect-uri", help="覆盖 FEISHU_REDIRECT_URI")
    authorize.add_argument(
        "--scopes",
        help="空格或逗号分隔的附加用户权限；文档编辑和图片上传权限始终包含",
    )
    authorize.add_argument(
        "--timeout-seconds",
        type=int,
        default=300,
        help="等待浏览器授权回调的秒数，默认 300",
    )
    authorize.add_argument(
        "--open-browser",
        action="store_true",
        help="使用系统默认浏览器自动打开授权页面",
    )
    authorize.set_defaults(handler=command_authorize)

    exchange = subparsers.add_parser("exchange-code", help="用一次性 code 换取用户令牌")
    exchange.add_argument("--code", help="一次性授权码；省略时安全提示输入")
    exchange.add_argument(
        "--scopes",
        help="记录授权码请求的附加权限；文档编辑和图片上传权限始终包含",
    )
    exchange.set_defaults(handler=command_exchange_code)

    refresh = subparsers.add_parser("refresh", help="立即刷新用户令牌")
    refresh.set_defaults(handler=command_refresh)

    status = subparsers.add_parser(
        "status",
        help="检查 OAuth 配置和令牌缓存，不显示令牌内容",
    )
    status.set_defaults(handler=command_status)

    create = subparsers.add_parser("create", help="在个人云盘创建新版文档")
    create.add_argument("--title", required=True, help="文档标题")
    create.add_argument("--folder", help="个人文件夹 URL 或 folder_token")
    create.add_argument("--dry-run", action="store_true", help="只预览，不调用飞书 API")
    _add_content_arguments(create)
    create.set_defaults(handler=command_create)

    append = subparsers.add_parser("append", help="追加内容到指定新版文档")
    append.add_argument("--document", required=True, help="新版文档 URL 或 document_id")
    append.add_argument("--dry-run", action="store_true", help="只预览，不调用飞书 API")
    _add_content_arguments(append)
    append.set_defaults(handler=command_append)

    replace = subparsers.add_parser(
        "replace",
        help="保留文档本身，替换指定新版文档的全部正文",
    )
    replace.add_argument(
        "--document",
        required=True,
        help="新版文档 URL 或 document_id",
    )
    replace.add_argument(
        "--confirm-replace",
        action="store_true",
        help="确认删除现有正文并替换为新内容",
    )
    replace.add_argument(
        "--dry-run",
        action="store_true",
        help="只预览新正文结构，不调用飞书 API",
    )
    _add_content_arguments(replace)
    replace.set_defaults(handler=command_replace)

    credentials = subparsers.add_parser(
        "write-credentials",
        help="安全输入并写入真实 App Secret 和 Token",
    )
    credentials.add_argument(
        "--document",
        required=True,
        help="目标新版文档 URL 或 document_id",
    )
    credentials.add_argument(
        "--confirm-sensitive-upload",
        action="store_true",
        help="确认已经核对目标文档分享范围和在线保存风险",
    )
    credentials.add_argument(
        "--dry-run",
        action="store_true",
        help="只显示字段名称和目标，不读取或写入敏感值",
    )
    credentials.set_defaults(handler=command_write_credentials)

    check = subparsers.add_parser("check", help="检查指定文档及根块数量")
    check.add_argument("--document", required=True, help="新版文档 URL 或 document_id")
    check.set_defaults(handler=command_check)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        result = args.handler(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except FeishuApiError as error:
        details = {"error": str(error)}
        if error.code is not None:
            details["code"] = error.code
        if error.status is not None:
            details["http_status"] = error.status
        print(json.dumps(details, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
