#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
import os
import re
import time
import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Tuple, Optional, Dict
from glob import glob

import requests
from telethon import TelegramClient
from telethon.errors.rpcerrorlist import FloodWaitError, SessionPasswordNeededError
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table
from rich import box

console = Console()

# ----------------- USTAWIENIA -----------------
BOT_USERNAME   = "QuantusFaucetBot"
CMD_TEMPLATE   = "/balance {}"

REPLY_TIMEOUT  = int(os.getenv("REPLY_TIMEOUT", "45"))
STEP_WAIT      = float(os.getenv("STEP_WAIT", "0.8"))
DELAY_BETWEEN  = float(os.getenv("DELAY_BETWEEN", "1.8"))
DEBUG          = os.getenv("DEBUG", "0") == "1"

HISTORY_PATH   = "balances_history.json"

# Okna czasowe – TYLKO 12h i 24h
TIMEFRAMES = [
    ("12h", 720),
    ("24h", 1440),
]

# liczby + jednostka QU lub QNT
NUM_RE = r"(\d{1,3}(?:[ \u00A0,]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)"
Q_RE   = re.compile(NUM_RE + r"\s*(?:QU|QNT)\b", re.IGNORECASE)


# ----------------- UTILS -----------------
def normalize_num(txt: str) -> Optional[str]:
    if not txt:
        return None
    t = txt.replace("\u00A0", " ").strip()
    if "." in t and "," in t:
        t = t.replace(",", "")
    else:
        if "," in t and "." not in t:
            t = t.replace(",", ".")
        t = t.replace(" ", "")
    return t


def read_pairs_from_file(path: str) -> List[Tuple[str, str]]:
    p = Path(path)
    if not p.exists():
        return []
    pairs = []
    with open(p, "r") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split()
            if len(parts) == 1:
                pairs.append(("", parts[0]))
            else:
                pairs.append((parts[0], parts[-1]))
    return pairs


def read_groups() -> List[Tuple[str, List[Tuple[str, str]]]]:
    groups = []
    paths = sorted(glob("nodes*.txt"))

    special = {
        "nodes":  "Cerveza",
        "nodes2": "Baku",
    }

    for path in paths:
        pairs = read_pairs_from_file(path)
        if not pairs:
            continue

        stem = Path(path).stem

        if stem in special:
            owner = special[stem]
        else:
            m = re.match(r"nodes(\d+)", stem)
            if m:
                owner = f"{m.group(1)}-Nodes"
            else:
                owner = stem

        groups.append((owner, pairs))

    return groups


def parse_q_amount(text: str) -> Optional[str]:
    if not text:
        return None
    m = Q_RE.search(text)
    if not m:
        return None
    val = normalize_num(m.group(1))
    unit = "QU" if "QU" in m.group(0).upper() else "QNT"
    return f"{val} {unit}"


def looks_like_placeholder(text: str) -> bool:
    if not text:
        return True
    t = text.strip().lower()
    if t.startswith("/balance"):
        return True
    if "checking balance" in t or "sprawdzam" in t:
        return True
    if "balance" in t and ("qnt" not in t and " qu" not in t):
        return True
    return False


def parse_balance_float(bal: str) -> float:
    if not bal or bal in ("—", "ERROR", "FloodWait"):
        return 0.0
    x = bal.replace(" QNT", "").replace(" QU", "").replace("\u00A0", " ").strip()
    if "." in x and "," in x:
        x = x.replace(",", "")
    else:
        if "," in x and "." not in x:
            x = x.replace(",", ".")
        x = x.replace(" ", "")
    try:
        return float(x)
    except:
        return 0.0


# ----------------- HISTORIA -----------------
def load_history(path=HISTORY_PATH):
    try:
        with open(path, "r") as f:
            data = json.load(f)
        return data.get("entries", [])
    except:
        return []


def save_history(entries, path=HISTORY_PATH):
    now = datetime.now()
    cutoff = now - timedelta(days=3)
    pruned = []
    for e in entries:
        try:
            dt = datetime.fromisoformat(e["ts"])
            if dt >= cutoff:
                pruned.append(e)
        except:
            pass
    with open(path, "w") as f:
        json.dump({"entries": pruned}, f, indent=2)


def append_current_to_history(now_vals: Dict[str, float]):
    entries = load_history()
    entry = {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "balances": now_vals,
    }
    entries.append(entry)
    save_history(entries)


def find_baseline(parsed, target: datetime):
    baseline = None
    for dt, balances in parsed:
        if dt <= target:
            baseline = balances
        else:
            break
    return baseline or {}


def compute_deltas(now_vals: Dict[str, float], history, now_ts):
    parsed = []
    earliest_seen = {}

    for e in history:
        try:
            dt = datetime.fromisoformat(e["ts"])
            balances = {k: float(v) for k, v in e.get("balances", {}).items()}
            parsed.append((dt, balances))
            for addr in balances:
                if addr not in earliest_seen or dt < earliest_seen[addr]:
                    earliest_seen[addr] = dt
        except:
            pass

    parsed.sort(key=lambda x: x[0])

    baselines = {}
    for label, mins in TIMEFRAMES:
        target = now_ts - timedelta(minutes=mins)
        baselines[label] = find_baseline(parsed, target)

    deltas: Dict[str, Dict[str, Optional[float]]] = {}

    for addr, now_val in now_vals.items():
        node_deltas = {}

        first_seen = earliest_seen.get(addr)
        for label, mins in TIMEFRAMES:

            if not first_seen or (now_ts - first_seen) < timedelta(minutes=mins):
                node_deltas[label] = None
                continue

            base_balances = baselines.get(label, {})
            if addr not in base_balances:
                node_deltas[label] = None
            else:
                prev_val = float(base_balances[addr])
                node_deltas[label] = round(now_val - prev_val, 6)

        deltas[addr] = node_deltas

    return deltas


# ----------------- DISCORD FORMAT -----------------
def make_discord_messages(groups_with_rows, now_vals, deltas):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")

    headers = ["NODE", "BAL"] + [label for label, _ in TIMEFRAMES]
    widths = [24, 10] + [8] * len(TIMEFRAMES)

    def fmt_row(cols):
        line = f"{cols[0]:<{widths[0]}}{cols[1]:>{widths[1]}}"
        for i in range(2, len(cols)):
            line += f"{cols[i]:>{widths[i]}}"
        return line

    def fmt_delta(x):
        if x is None:
            return "-"
        if abs(x) < 1e-9:
            return "0"
        sign = "+" if x > 0 else ""
        return f"{sign}{x:.1f}"

    messages = []

    for owner, rows in groups_with_rows:

        lines = []
        lines.append(f"**Quantus — Balances (@QuantusFaucetBot)**  \n*{ts}*")
        lines.append(f"{owner}")
        lines.append("```")
        lines.append(fmt_row(headers))
        lines.append("-" * sum(widths))

        owner_total_now = 0
        owner_delta_total = {label: 0.0 for label, _ in TIMEFRAMES}

        for label, addr, _bal_str in rows:
            val_now = now_vals.get(addr, 0.0)
            d = deltas.get(addr, {})

            owner_total_now += val_now
            for tf_label, _ in TIMEFRAMES:
                v = d.get(tf_label)
                if v is not None:
                    owner_delta_total[tf_label] += v

            cols = [label, f"{val_now:.1f}"]
            for tf_label, _ in TIMEFRAMES:
                cols.append(fmt_delta(d.get(tf_label)))

            lines.append(fmt_row(cols))

        lines.append("-" * sum(widths))

        total_cols = [f"TOTAL ({owner})", f"{owner_total_now:.1f}"]
        for tf_label, _ in TIMEFRAMES:
            v = owner_delta_total[tf_label]
            if abs(v) < 1e-9:
                total_cols.append("0")
            else:
                sign = "+" if v > 0 else ""
                total_cols.append(f"{sign}{v:.1f}")

        lines.append(fmt_row(total_cols))
        lines.append("```")

        messages.append("\n".join(lines))

    return messages


def send_to_discord(webhook_url, content):
    if not webhook_url:
        return
    try:
        r = requests.post(webhook_url, json={"content": content})
        if r.status_code not in (200, 204):
            console.print(f"[red]Discord error: {r.status_code}[/red]")
    except Exception as e:
        console.print(f"[red]Błąd wysyłki Discord: {e}[/red]")


def print_table(rows, title):
    tb = Table(title=title, box=box.SIMPLE_HEAVY)
    tb.add_column("Nazwa noda", style="cyan", no_wrap=True)
    tb.add_column("q-adres", style="green")
    tb.add_column("Balance", justify="right")
    for label, addr, bal in rows:
        tb.add_row(label or "-", addr, bal)
    console.print(tb)


# ----------------- TELEGRAM -----------------
async def ask_bot_for_balance(client, bot_username, address):
    entity = await client.get_entity(bot_username)
    cmd = CMD_TEMPLATE.format(address)

    try:
        sent = await client.send_message(entity, cmd)
        sent_id = sent.id

        deadline = time.time() + REPLY_TIMEOUT

        while time.time() < deadline:
            msgs = await client.get_messages(entity, limit=12)

            for m in msgs:
                if m.sender_id != entity.id or m.id <= sent_id:
                    continue

                t = (m.message or "").strip()
                if not t:
                    continue

                if looks_like_placeholder(t):
                    continue

                got = parse_q_amount(t)
                if got:
                    return got

            await asyncio.sleep(STEP_WAIT)

        return "—"

    except FloodWaitError as e:
        await asyncio.sleep(int(getattr(e, "seconds", 10)))
        return "FloodWait"

    except Exception:
        return "ERROR"


async def fetch_balances(client, pairs):
    rows = []
    for label, addr in pairs:
        bal = await ask_bot_for_balance(client, BOT_USERNAME, addr)
        rows.append((label, addr, bal))
        await asyncio.sleep(DELAY_BETWEEN)
    return rows


# ----------------- MAIN -----------------
async def main():
    load_dotenv()
    api_id     = int(os.getenv("API_ID", "0"))
    api_hash   = os.getenv("API_HASH")
    phone      = os.getenv("PHONE")
    discord_url = os.getenv("DISCORD_WEBHOOK", "")
    session_name = os.getenv("SESSION_NAME", "quantus_balance_session")

    if not api_id or not api_hash or not phone:
        console.print("[red]Brakuje API_ID/API_HASH/PHONE w .env[/red]")
        return

    groups = read_groups()
    if not groups:
        console.print("[red]Brak plików nodes*.txt[/red]")
        return

    client = TelegramClient(session_name, api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        await client.send_code_request(phone)
        code = input("Kod z Telegrama: ")
        try:
            await client.sign_in(phone=phone, code=code)
        except SessionPasswordNeededError:
            pw = input("Hasło 2FA: ")
            await client.sign_in(password=pw)

    try:
        groups_with_rows = []
        for owner, pairs in groups:
            rows = await fetch_balances(client, pairs)
            groups_with_rows.append((owner, rows))
            print_table(rows, f"Nody: {owner}")

        # mapowanie addr → balance
        all_rows = [r for _owner, rows in groups_with_rows for r in rows]
        now_vals = {addr: parse_balance_float(bal) for _label, addr, bal in all_rows}

        history = load_history()
        now_ts = datetime.now()
        deltas = compute_deltas(now_vals, history, now_ts)

        messages = make_discord_messages(groups_with_rows, now_vals, deltas)
        for msg in messages:
            send_to_discord(discord_url, msg)

        append_current_to_history(now_vals)

    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
