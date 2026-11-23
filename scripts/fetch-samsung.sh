#!/usr/bin/env bash
# Downloads one file from opensource.samsung.com.
#
#   fetch-samsung.sh <upload id> <attach id> <output file>
#
# The site has no direct links. The download is a form POST with a CSRF
# token from the search page and a one-time token from the download popup,
# so every file needs a fresh popup. No account or captcha is involved.
set -euo pipefail

UPLOAD=${1:?upload id}
ATTACH=${2:?attach id}
OUT=${3:?output file}

SITE=https://opensource.samsung.com
UA='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
JAR=$TMP/cookies

curl -sSf -c "$JAR" -b "$JAR" -A "$UA" \
    "$SITE/uploadSearch?searchValue=SM-R870" -o "$TMP/search.html"
csrf=$(grep -oP 'X-CSRF-TOKEN", "\K[^"]+' "$TMP/search.html" | head -1)
[ -n "$csrf" ] || { echo "no CSRF token on the search page" >&2; exit 1; }

curl -sSf -c "$JAR" -b "$JAR" -A "$UA" -e "$SITE/uploadSearch?searchValue=SM-R870" \
    -H "X-CSRF-TOKEN: $csrf" -H 'X-Requested-With: XMLHttpRequest' \
    --data-urlencode "uploadId=$UPLOAD" "$SITE/downSrcMPop" -o "$TMP/popup.html"
form_csrf=$(grep -oP 'name="_csrf" value="\K[^"]+' "$TMP/popup.html")
token=$(grep -oP 'name="token" value="\K[^"]+' "$TMP/popup.html")
[ -n "$form_csrf" ] && [ -n "$token" ] || { echo "no download token in the popup" >&2; exit 1; }

curl -sSf -c "$JAR" -b "$JAR" -A "$UA" -e "$SITE/uploadSearch?searchValue=SM-R870" \
    --data-urlencode "_csrf=$form_csrf" --data-urlencode "uploadId=$UPLOAD" \
    --data-urlencode "attachIds=$ATTACH" --data-urlencode "downloadPurpose=ETC" \
    --data-urlencode "token=$token" -D "$TMP/headers" -o "$OUT.part" \
    "$SITE/downSrcCode"

if ! grep -qi '^content-disposition: attachment' "$TMP/headers"; then
    echo "server did not send a file for $UPLOAD/$ATTACH" >&2
    rm -f "$OUT.part"
    exit 1
fi
mv "$OUT.part" "$OUT"
