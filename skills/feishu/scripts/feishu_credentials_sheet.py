"""Create or extend a private Feishu credential sheet with hidden credential input."""

import argparse
import getpass
import importlib.util
import json
import re
import unicodedata
from pathlib import Path


DOCS_SCRIPT = Path(__file__).with_name("feishu_docs.py")
spec = importlib.util.spec_from_file_location("feishu_docs", DOCS_SCRIPT)
feishu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feishu)


def request(method, path, token, *, body=None, query=None):
    return feishu._json_request(method, path, token=token, body=body, query=query).get("data", {})


def spreadsheet_token(value):
    match = re.search(r"(?:/sheets/)?([A-Za-z0-9]{20,})", value)
    if not match:
        raise ValueError("Invalid spreadsheet URL or token")
    return match.group(1)


def cell_text(value):
    if isinstance(value, list) and value and isinstance(value[0], dict):
        return value[0].get("text", "")
    return value or ""


def pixel_width(value, minimum):
    units = sum(2 if unicodedata.east_asian_width(character) in "FW" else 1 for character in value)
    width = max(minimum, units * 8 + 48)
    if width > 1000:
        raise ValueError("A cell is too long to display in a 1000px column")
    return width


def sheets(book, token):
    return request("GET", f"/sheets/v2/spreadsheets/{book}/metainfo", token)["sheets"]


def sheet_update(book, sheet_id, properties, token):
    request("POST", f"/sheets/v2/spreadsheets/{book}/sheets_batch_update", token, body={
        "requests": [{"updateSheet": {"properties": {"sheetId": sheet_id, **properties}}}],
    })


def configure_sheet(book, sheet_id, token):
    base = f"/sheets/v2/spreadsheets/{book}"
    for index, width in enumerate((190, 300, 330), start=1):
        request("PUT", f"{base}/dimension_range", token, body={
            "dimension": {"sheetId": sheet_id, "majorDimension": "COLUMNS", "startIndex": index, "endIndex": index},
            "dimensionProperties": {"visible": True, "fixedSize": width},
        })
    request("PUT", f"{base}/dimension_range", token, body={
        "dimension": {"sheetId": sheet_id, "majorDimension": "ROWS", "startIndex": 1, "endIndex": 1},
        "dimensionProperties": {"visible": True, "fixedSize": 42},
    })
    request("PUT", f"{base}/style", token, body={
        "appendStyle": {"range": f"{sheet_id}!A1:C1", "style": {
            "font": {"bold": True, "fontSize": "12pt/1.5"},
            "foreColor": "#FFFFFF", "backColor": "#704D8A", "hAlign": 1, "vAlign": 1,
        }},
    })
    sheet_update(book, sheet_id, {"frozenRowCount": 1}, token)


def prepare_sheet(book, title, token, *, first=False):
    existing = sheets(book, token)
    matched = next((item for item in existing if item["title"] == title), None)
    if matched:
        return matched["sheetId"], False
    if first and len(existing) == 1 and existing[0]["title"] == "Sheet1":
        sheet_id = existing[0]["sheetId"]
        sheet_update(book, sheet_id, {"title": title}, token)
    else:
        reply = request("POST", f"/sheets/v2/spreadsheets/{book}/sheets_batch_update", token, body={
            "requests": [{"addSheet": {"properties": {"title": title}}}],
        })
        sheet_id = reply["replies"][0]["addSheet"]["properties"]["sheetId"]
    request("PUT", f"/sheets/v2/spreadsheets/{book}/values", token, body={
        "valueRange": {"range": f"{sheet_id}!A1:C1", "values": [["标题", "账户", "密码"]]},
    })
    configure_sheet(book, sheet_id, token)
    return sheet_id, True


def rows_in_sheet(book, sheet_id, token):
    row_count = next(item["rowCount"] for item in sheets(book, token) if item["sheetId"] == sheet_id)
    values = request("GET", f"/sheets/v2/spreadsheets/{book}/values/{sheet_id}!A1:C{row_count}", token)
    rows = [[cell_text(cell) for cell in row] for row in values["valueRange"].get("values", [])]
    while rows and not any(rows[-1]):
        rows.pop()
    return rows, row_count


def normalize_layout(book, sheet_id, last_row, group_rows, token):
    base = f"/sheets/v2/spreadsheets/{book}"

    def style(cell_range, properties):
        request("PUT", f"{base}/style", token, body={
            "appendStyle": {"range": f"{sheet_id}!{cell_range}", "style": properties},
        })

    style(f"A1:C{last_row}", {"hAlign": 1, "vAlign": 1})
    style("A1:C1", {
        "font": {"bold": True, "fontSize": "12pt/1.5"},
        "foreColor": "#FFFFFF", "backColor": "#704D8A", "hAlign": 1, "vAlign": 1,
    })
    for row in group_rows:
        style(f"A{row}:A{row}", {
            "font": {"bold": True, "fontSize": "12pt/1.5"},
            "foreColor": "#000000", "backColor": "#E9DDF0",
            "hAlign": 1, "vAlign": 1,
        })


def add_credential(book, sheet_id, group_title, account, password, token):
    base = f"/sheets/v2/spreadsheets/{book}"
    rows, capacity = rows_in_sheet(book, sheet_id, token)
    if not rows or rows[0] != ["标题", "账户", "密码"]:
        raise RuntimeError("Target worksheet does not have the required three-column header")
    widths = [max(pixel_width(str(row[index]) if index < len(row) else "", minimum)
                  for row in [*rows, [group_title, account, password]])
              for index, minimum in enumerate((190, 300, 330))]
    last_group_start = next((index + 1 for index in range(len(rows) - 1, 0, -1) if rows[index][0]), None)
    same_group = last_group_start is not None and rows[last_group_start - 1][0] == group_title
    separator_row = len(rows) + 1 if len(rows) > 1 and not same_group else None
    next_row = len(rows) + (2 if separator_row else 1)
    if next_row > capacity:
        request("POST", f"{base}/dimension_range", token, body={
            "dimension": {"sheetId": sheet_id, "majorDimension": "ROWS", "length": 50},
        })

    if separator_row:
        request("PUT", f"{base}/values", token, body={
            "valueRange": {"range": f"{sheet_id}!A{separator_row}:C{separator_row}",
                           "values": [["", "", ""]]},
        })
        request("PUT", f"{base}/dimension_range", token, body={
            "dimension": {"sheetId": sheet_id, "majorDimension": "ROWS",
                          "startIndex": separator_row, "endIndex": separator_row},
            "dimensionProperties": {"visible": True, "fixedSize": 20},
        })
    if same_group and last_group_start < len(rows):
        request("POST", f"{base}/unmerge_cells", token, body={
            "range": f"{sheet_id}!A{last_group_start}:A{len(rows)}",
        })
    first_value = "" if same_group else group_title
    request("PUT", f"{base}/values", token, body={
        "valueRange": {"range": f"{sheet_id}!A{next_row}:C{next_row}",
                       "values": [[first_value, account, password]]},
    })
    if same_group:
        request("POST", f"{base}/merge_cells", token, body={
            "range": f"{sheet_id}!A{last_group_start}:A{next_row}", "mergeType": "MERGE_ALL",
        })
    for index, width in enumerate(widths, start=1):
        request("PUT", f"{base}/dimension_range", token, body={
            "dimension": {"sheetId": sheet_id, "majorDimension": "COLUMNS",
                          "startIndex": index, "endIndex": index},
            "dimensionProperties": {"visible": True, "fixedSize": width},
        })
    request("PUT", f"{base}/style", token, body={
        "appendStyle": {"range": f"{sheet_id}!A{next_row}:C{next_row}", "style": {
            "font": {"fontSize": "12pt/1.5"}, "backColor": "#F6F1F8",
            "hAlign": 1, "vAlign": 1,
        }},
    })
    if not same_group:
        request("PUT", f"{base}/style", token, body={
            "appendStyle": {"range": f"{sheet_id}!A{next_row}:A{next_row}", "style": {
                "font": {"bold": True, "fontSize": "12pt/1.5"},
                "foreColor": "#000000", "backColor": "#E9DDF0",
                "hAlign": 1, "vAlign": 1,
            }},
        })
    request("PUT", f"{base}/dimension_range", token, body={
        "dimension": {"sheetId": sheet_id, "majorDimension": "ROWS",
                      "startIndex": next_row, "endIndex": next_row},
        "dimensionProperties": {"visible": True, "fixedSize": 40},
    })
    group_rows = [index + 1 for index, row in enumerate(rows) if index > 0 and row and row[0]]
    if not same_group:
        group_rows.append(next_row)
    normalize_layout(book, sheet_id, next_row, group_rows, token)
    actual = request("GET", f"{base}/values/{sheet_id}!A{next_row}:C{next_row}", token)["valueRange"]["values"][0]
    if [cell_text(cell) for cell in actual][1:] != [account, password]:
        raise RuntimeError("Credential verification failed")
    return next_row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--folder", help="Target folder URL or token when creating a workbook")
    target.add_argument("--spreadsheet", help="Existing workbook URL or token")
    parser.add_argument("--title", help="Workbook title for --folder")
    parser.add_argument("--sheet", required=True, help="Worksheet name")
    parser.add_argument("--group-title", required=True, help="Value for the title column")
    args = parser.parse_args()
    if args.folder and not args.title:
        parser.error("--title is required with --folder")
    account = getpass.getpass("Account (hidden): ").strip()
    password = getpass.getpass("Password (hidden): ")
    if not account or not password:
        parser.error("Account and password must not be empty")
    for value, minimum in zip((args.group_title, account, password), (190, 300, 330)):
        pixel_width(value, minimum)

    token = feishu._resolve_user_token()
    if args.folder:
        folder = feishu._extract_folder_token(args.folder)
        files = request("GET", "/drive/v1/files", token, query={"folder_token": folder, "page_size": 200}).get("files", [])
        if any(item.get("name") == args.title for item in files):
            raise RuntimeError("A file with that title already exists in the target folder")
        created = request("POST", "/sheets/v3/spreadsheets", token, body={"title": args.title, "folder_token": folder})["spreadsheet"]
        book = created["spreadsheet_token"]
        url = created["url"]
    else:
        book = spreadsheet_token(args.spreadsheet)
        url = args.spreadsheet if args.spreadsheet.startswith("https://") else f"https://feishu.cn/sheets/{book}"
    sheet_id, _ = prepare_sheet(book, args.sheet, token, first=bool(args.folder))
    row = add_credential(book, sheet_id, args.group_title, account, password, token)
    print(json.dumps({"url": url, "sheet": args.sheet, "row": row, "verified": True}, ensure_ascii=False))


if __name__ == "__main__":
    main()
