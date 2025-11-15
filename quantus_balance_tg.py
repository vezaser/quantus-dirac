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
# etykieta, ile minut wstecz
TIMEFRAMES = [
    ("30m", 30),
    ("1h", 60),
    ("4h", 240),
    ("12h", 720),
    ("24h", 1440),
]

# liczby + jednostka QU lub QNT
NUM_RE = r"(\d{1,3}(?:[ \u00A0,]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)"
Q_RE   = re.compile(NUM_RE + r"\s*(?:QU|QNT)\b", re.IGNORECASE)


# ----------------- POMOCNICZE -----------------
def normalize_num(txt: str) -> Optional[str]:
    """Zamienia 1 234,56 / 1,234.56 -> 1234.56"""
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
    """
    Czyta plik:
      LABEL qADRES
    Zwraca listę (label, address).
    Jeśli plik nie istnieje -> [].
    """
    p = Path(path)
    if not p.exists():
        return []
    pairs: List[Tuple[str, str]] = []
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
    """
    Szuka nodes*.txt w katalogu i zwraca listę:
      [(owner_name, [(label, addr)...]), ...]

    owner_name nadawany wg:
        nodes.txt      -> "Cerveza"
        nodes2.txt     -> "Baku"
        nodes3.txt     -> "3-Nodes"
        nodes4.txt     -> "4-Nodes"
        nodes5.txt     -> "5-Nodes"
        ...
    Pokazuje tylko sekcje dla plików, które istnieją.
    """
    groups: List[Tuple[str, List[Tuple[str, str]]]] = []

    paths = sorted(glob("nodes*.txt"))

    special = {
        "nodes":  "Cerveza",
        "nodes2": "Baku",
    }

    for path in paths:
        pairs = read_pairs_from_file(path)
        if not pairs:
            continue

        stem = Path(path).stem  # nodes, nodes2, nodes3, ...

        if stem in special:
            owner = special[stem]
        else:
            m = re.match(r"nodes(\d+)", stem)
            if m:
                num = m.group(1)
                owner = f"{num}-Nodes"
            else:
                owner = stem  # fallback

        groups.append((owner, pairs))

    return groups


def parse_q_amount(text: str) -> Optional[str]:
    """Zwraca 'X.Y QU' lub 'X.Y QNT' z tekstu bota."""
    if not text:
        return None
    m = Q_RE.search(text)
    if not m:
        return None
    val = normalize_num(m.group(1))
    unit = "QU" if "QU" in m.group(0).upper() else "QNT"
    return f"{val} {unit}" if val else None


def looks_like_placeholder(text: str) -> bool:
    """Ignoruje echo '/balance', 'Checking balance...' itd."""
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
    """Konwertuje '1234.56 QU' -> 1234.56 (float)."""
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
    except Exception:
        return 0.0


# ----------------- HISTORIA -----------------
def load_history(path: str = HISTORY_PATH) -> List[dict]:
    """Wczytuje historię: listę wpisów {ts: ISO, balances: {node: float}}."""
    try:
        with open(path, "r") as f:
            data = json.load(f)
        entries = data.get("entries", [])
        return entries if isinstance(entries, list) else []
    except Exception:
        return []


def save_history(entries: List[dict], path: str = HISTORY_PATH):
    """Zapisuje historię z pruningiem do ~3 dni wstecz."""
    now = datetime.now()
    cutoff = now - timedelta(days=3)
    pruned = []
    for e in entries:
        try:
            dt = datetime.fromisoformat(e["ts"])
            if dt >= cutoff:
                pruned.append(e)
        except Exception:
            continue
    with open(path, "w") as f:
        json.dump({"entries": pruned}, f, indent=2)


def append_current_to_history(now_vals: Dict[str, float], path: str = HISTORY_PATH):
    entries = load_history(path)
    entry = {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "balances": now_vals,
    }
    entries.append(entry)
    save_history(entries, path)


def compute_deltas(
    now_vals: Dict[str, float],
    history: List[dict],
    now_ts: datetime,
) -> Dict[str, Dict[str, Optional[float]]]:
    """
    Zwraca: {node: { '30m': delta, '1h': delta, ... }}.
    Jeśli brak danych dla danego okna czasowego -> None.
    """
    parsed = []
    for e in history:
        try:
            dt = datetime.fromisoformat(e["ts"])
            balances = e.get("balances", {})
            parsed.append((dt, balances))
        except Exception:
            continue
    parsed.sort(key=lambda x: x[0])

    baselines: Dict[str, Optional[dict]] = {}
    for label, minutes in TIMEFRAMES:
        target = now_ts - timedelta(minutes=minutes)
        candidate = None
        for dt, balances in parsed:
            if dt <= target:
                candidate = balances
        baselines[label] = candidate

    deltas: Dict[str, Dict[str, Optional[float]]] = {}
    for node, curr_val in now_vals.items():
        node_deltas: Dict[str, Optional[float]] = {}
        for label, _mins in TIMEFRAMES:
            base_balances = baselines.get(label)
            if not base_balances or node not in base_balances:
                node_deltas[label] = None
            else:
                prev_val = float(base_balances.get(node, 0.0))
                node_deltas[label] = round(curr_val - prev_val, 6)
        deltas[node] = node_deltas
    return deltas


# ----------------- FORMATOWANIE RAPORTU -----------------
def make_discord_text(
    groups_with_rows: List[Tuple[str, List[Tuple[str, str, str]]]],
    now_vals: Dict[str, float],
    deltas: Dict[str, Dict[str, Optional[float]]],
) -> str:
    """Buduje raport z sekcjami per właściciel + TOTAL (ALL)."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")

    headers = ["NODE", "BAL"] + [label for label, _ in TIMEFRAMES]
    widths = [24, 10] + [8] * len(TIMEFRAMES)

    def fmt_row(cols: List[str]) -> str:
        line = f"{cols[0]:<{widths[0]}}{cols[1]:>{widths[1]}}"
        for i in range(2, len(cols)):
            line += f"{cols[i]:>{widths[i]}}"
        return line

    def fmt_delta(x: Optional[float]) -> str:
        if x is None:
            return "-"
        if abs(x) < 1e-9:
            return "0"
        sign = "+" if x > 0 else ""
        return f"{sign}{x:.1f}"

    total_now_all: float = sum(now_vals.values())
    totals_delta_all: Dict[str, float] = {label: 0.0 for label, _ in TIMEFRAMES}
    for node, _val in now_vals.items():
        for tf_label, _ in TIMEFRAMES:
            v = deltas.get(node, {}).get(tf_label)
            if v is not None:
                totals_delta_all[tf_label] += v

    lines = [f"**Quantus — Balances (@QuantusFaucetBot)**  \n*{ts}*"]
    lines.append("```")

    for owner_name, rows in groups_with_rows:
        lines.append(f"{owner_name}:")
        lines.append(fmt_row(headers))
        lines.append("-" * sum(widths))

        owner_total_now = 0.0
        owner_totals_delta: Dict[str, float] = {label: 0.0 for label, _ in TIMEFRAMES}

        for label, _addr, _bal_str in rows:
            val_now = now_vals.get(label, 0.0)
            d = deltas.get(label, {})

            owner_total_now += val_now
            for tf_label, _ in TIMEFRAMES:
                v = d.get(tf_label)
                if v is not None:
                    owner_totals_delta[tf_label] += v

            cols = [label, f"{val_now:.1f}"]
            for tf_label, _ in TIMEFRAMES:
                cols.append(fmt_delta(d.get(tf_label)))
            lines.append(fmt_row(cols))

        lines.append("-" * sum(widths))
        total_cols = [f"TOTAL ({owner_name})", f"{owner_total_now:.1f}"]
        for tf_label, _ in TIMEFRAMES:
            td = owner_totals_delta[tf_label]
            if abs(td) < 1e-9:
                total_cols.append("0")
            else:
                sign = "+" if td > 0 else ""
                total_cols.append(f"{sign}{td:.1f}")
        lines.append(fmt_row(total_cols))
        lines.append("")

    lines.append("-" * sum(widths))
    all_cols = ["TOTAL (ALL)", f"{total_now_all:.1f}"]
    for tf_label, _ in TIMEFRAMES:
        td = totals_delta_all[tf_label]
        if abs(td) < 1e-9:
            all_cols.append("0")
        else:
            sign = "+" if td > 0 else ""
            all_cols.append(f"{sign}{td:.1f}")
    lines.append(fmt_row(all_cols))

    lines.append("```")
    return "\n".join(lines)


def send_to_discord(webhook_url: str, content: str):
    if not webhook_url:
        return
    try:
        resp = requests.post(webhook_url, json={"content": content})
        if resp.status_code not in (200, 204):
            console.print(f"[red]Discord webhook błąd: {resp.status_code}[/red]")
    except Exception as e:
        console.print(f"[red]Nie udało się wysłać na Discord: {e}[/red]")


def print_table(rows: List[Tuple[str, str, str]], title: str):
    tb = Table(title=title, box=box.SIMPLE_HEAVY)
    tb.add_column("Nazwa noda", style="cyan", no_wrap=True)
    tb.add_column("q-adres", style="green")
    tb.add_column("Balance", justify="right")
    for label, addr, bal in rows:
        tb.add_row(label or "-", addr, bal)
    console.print(tb)


# ----------------- TELEGRAM / BOT -----------------
async def ask_bot_for_balance(client: TelegramClient, bot_username: str, address: str) -> str:
    """Wysyła /balance <address> i czyta odpowiedzi bota."""
    entity = await client.get_entity(bot_username)
    cmd = CMD_TEMPLATE.format(address)

    try:
        sent = await client.send_message(entity, cmd)
        sent_id = sent.id
        if DEBUG:
            console.log(f"CMD id={sent_id}: {cmd}")

        deadline = time.time() + REPLY_TIMEOUT

        while time.time() < deadline:
            msgs = await client.get_messages(entity, limit=12)
            for m in msgs:
                if m.sender_id != entity.id or m.id <= sent_id:
                    continue
                t = (m.message or "").strip()
                if not t:
                    continue
                if DEBUG:
                    console.log(f"BOT[{m.id}]: {t}")
                if looks_like_placeholder(t):
                    continue
                got = parse_q_amount(t)
                if got:
                    return got
            await asyncio.sleep(STEP_WAIT)

        msgs = await client.get_messages(entity, limit=30)
        msgs = [m for m in msgs if m.sender_id == entity.id and m.id > sent_id]
        msgs.sort(key=lambda x: x.id)
        for m in msgs:
            t = (m.message or "").strip()
            if looks_like_placeholder(t):
                continue
            got = parse_q_amount(t)
            if got:
                return got

        return "—"

    except FloodWaitError as e:
        wait_s = int(getattr(e, "seconds", 10))
        console.print(f"[yellow]FloodWait – pauza {wait_s}s[/yellow]")
        await asyncio.sleep(wait_s)
        return "FloodWait"
    except Exception as e:
        if DEBUG:
            console.log(f"ERROR ask_bot_for_balance: {e}")
        return f"ERROR: {e}"


async def fetch_balances(client: TelegramClient, pairs: List[Tuple[str, str]]) -> List[Tuple[str, str, str]]:
    rows: List[Tuple[str, str, str]] = []
    for label, addr in pairs:
        bal = await ask_bot_for_balance(client, BOT_USERNAME, addr)
        rows.append((label, addr, bal))
        await asyncio.sleep(DELAY_BETWEEN)
    return rows


# ----------------- MAIN -----------------
async def main():
    load_dotenv()
    api_id = int(os.getenv("API_ID", "0"))
    api_hash = os.getenv("API_HASH")
    phone = os.getenv("PHONE")
    discord_url = os.getenv("DISCORD_WEBHOOK", "")
    session_name = os.getenv("SESSION_NAME", "quantus_balance_session")

    if not api_id or not api_hash or not phone:
        console.print("[red]Brakuje API_ID/API_HASH/PHONE w .env[/red]")
        return

    groups = read_groups()
    if not groups:
        console.print("[red]Brak plików nodes*.txt z adresami[/red]")
        return

    client = TelegramClient(session_name, api_id, api_hash)
    await client.connect()
    if not await client.is_user_authorized():
        await client.send_code_request(phone)
        code = input("Wpisz kod z Telegrama: ")
        try:
            await client.sign_in(phone=phone, code=code)
        except SessionPasswordNeededError:
            pw = input("Masz 2FA – wpisz hasło: ")
            await client.sign_in(password=pw)

    try:
        groups_with_rows: List[Tuple[str, List[Tuple[str, str, str]]]] = []
        for owner, pairs in groups:
            rows = await fetch_balances(client, pairs)
            groups_with_rows.append((owner, rows))
            print_table(rows, f"Nody: {owner}")

        all_rows = [row for _owner, rows in groups_with_rows for row in rows]
        now_vals = {label: parse_balance_float(bal) for label, _addr, bal in all_rows}

        history = load_history()
        now_ts = datetime.now()
        deltas = compute_deltas(now_vals, history, now_ts)

        content = make_discord_text(groups_with_rows, now_vals, deltas)
        send_to_discord(discord_url, content)

        append_current_to_history(now_vals)

    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
