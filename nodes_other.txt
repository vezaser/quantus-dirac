#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
import os
import re
import time
import json
from datetime import datetime
from pathlib import Path
from typing import List, Tuple, Optional

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

# nazwy plików z nodami
MAIN_NODES_FILE  = "nodes.txt"         # Twoje nody
OTHER_NODES_FILE = "nodes_other.txt"   # nody drugiej osoby (opcjonalnie)

# nazwę osoby można zmienić jak chcesz
MAIN_OWNER_NAME  = "YOU"
OTHER_OWNER_NAME = "FRIEND"

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

def load_last_balances(path: str = "last_balances.json") -> dict:
    """Wczytuje poprzednie salda (nazwa -> bal_str)."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return {}

def save_current_balances(all_rows: List[Tuple[str, str, str]], path: str = "last_balances.json"):
    """Zapisuje aktualne salda (nazwa -> bal_str) do pliku."""
    data = {label: bal for label, _, bal in all_rows}
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def compute_deltas(all_rows: List[Tuple[str, str, str]], last: dict):
    """
    Zwraca:
      now_vals: dict label -> float
      deltas:   dict label -> float (Δ od poprzedniego pomiaru)
      total_now, delta_total
    """
    now_vals = {label: parse_balance_float(bal) for label, _, bal in all_rows}

    if not last:
        deltas = {label: 0.0 for label in now_vals.keys()}
        total_now = sum(now_vals.values())
        delta_total = 0.0
    else:
        deltas = {}
        for label, val in now_vals.items():
            prev = parse_balance_float(last.get(label, "0"))
            deltas[label] = round(val - prev, 6)
        total_now = sum(now_vals.values())
        total_prev = sum(parse_balance_float(v) for v in last.values())
        delta_total = round(total_now - total_prev, 6)

    return now_vals, deltas, total_now, delta_total

def make_table_text(
    rows_main: List[Tuple[str, str, str]],
    rows_other: List[Tuple[str, str, str]],
    last: dict
) -> str:
    """
    Tekst do Discorda:
    - najpierw Twoje nody + TOTAL (YOU)
    - separator
    - nody drugiej osoby + TOTAL (FRIEND) (jeśli są)
    - na końcu TOTAL (ALL)
    """
    all_rows = rows_main + rows_other
    now_vals, deltas, total_now_all, delta_total_all = compute_deltas(all_rows, last)

    ts = datetime.now().strftime("%Y-%m-%d %H:%M")

    lines = [f"**Quantus — Balances (@QuantusFaucetBot)**  \n*{ts}*"]
    lines.append("```")
    lines.append(f"{'NODE':<20}{'BALANCE':>12}{'Δ (30 min)':>12}")
    lines.append("-" * 44)

    # --- Twoje nody ---
    total_main = 0.0
    delta_main = 0.0
    for label, _, _ in rows_main:
        bal_val = now_vals.get(label, 0.0)
        delta   = deltas.get(label, 0.0)
        total_main += bal_val
        delta_main += delta
        sign = "+" if delta > 0 else ""
        lines.append(f"{label:<20}{bal_val:>12.3f}{sign}{delta:>11.3f}")

    lines.append("-" * 44)
    sign_main = "+" if delta_main > 0 else ""
    lines.append(f"{f'TOTAL ({MAIN_OWNER_NAME})':<20}{total_main:>12.3f}{sign_main}{delta_main:>11.3f}")

    # --- nody drugiej osoby (opcjonalne) ---
    if rows_other:
        lines.append("")  # pusta linia wizualnie
        lines.append(f"{'NODE':<20}{'BALANCE':>12}{'Δ (30 min)':>12}")
        lines.append("-" * 44)

        total_other = 0.0
        delta_other = 0.0
        for label, _, _ in rows_other:
            bal_val = now_vals.get(label, 0.0)
            delta   = deltas.get(label, 0.0)
            total_other += bal_val
            delta_other += delta
            sign = "+" if delta > 0 else ""
            lines.append(f"{label:<20}{bal_val:>12.3f}{sign}{delta:>11.3f}")

        lines.append("-" * 44)
        sign_other = "+" if delta_other > 0 else ""
        lines.append(f"{f'TOTAL ({OTHER_OWNER_NAME})':<20}{total_other:>12.3f}{sign_other}{delta_other:>11.3f}")

        # --- TOTAL wszystkich razem ---
        lines.append("-" * 44)
        sign_all = "+" if delta_total_all > 0 else ""
        lines.append(f"{'TOTAL (ALL)':<20}{total_now_all:>12.3f}{sign_all}{delta_total_all:>11.3f}")

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

        # fallback
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

    main_pairs  = read_pairs_from_file(MAIN_NODES_FILE)
    other_pairs = read_pairs_from_file(OTHER_NODES_FILE)

    if not main_pairs and not other_pairs:
        console.print("[red]Brak adresów w nodes.txt / nodes_other.txt[/red]")
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
        rows_main  = await fetch_balances(client, main_pairs)  if main_pairs  else []
        rows_other = await fetch_balances(client, other_pairs) if other_pairs else []

        if rows_main:
            print_table(rows_main, "Twoje nody")
        if rows_other:
            print_table(rows_other, "Nody drugiej osoby")

        last = load_last_balances()
        content = make_table_text(rows_main, rows_other, last)
        send_to_discord(discord_url, content)

        # zapisujemy stan dla WSZYSTKICH razem
        save_current_balances(rows_main + rows_other)

    finally:
        await client.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
