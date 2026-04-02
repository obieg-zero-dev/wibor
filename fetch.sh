#!/bin/bash
# Pobiera nowe stawki WIBOR z GPW Benchmark i dopisuje do istniejących JSON-ów
# Źródło: https://gpwbenchmark.pl/dane-opoznione (oficjalny administrator WIBOR)
# Uruchamiane przez GitHub Action (cron) lub ręcznie

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

HTML=$(curl -sf "https://gpwbenchmark.pl/dane-opoznione")

if [ -z "$HTML" ]; then
  echo "ERROR: nie udało się pobrać strony GPW Benchmark"
  exit 1
fi

# Parsuj tabelę HTML → TSV: data, wibor_1m, wibor_3m, wibor_6m
PARSED=$(echo "$HTML" | python3 -c "
import sys
from html.parser import HTMLParser

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = self.in_cell = False
        self.rows, self.row, self.cell = [], [], ''
    def handle_starttag(self, tag, attrs):
        if tag == 'table': self.in_table = True
        elif self.in_table and tag == 'tr': self.row = []
        elif self.in_table and tag in ('td','th'): self.in_cell = True; self.cell = ''
    def handle_endtag(self, tag):
        if tag == 'table': self.in_table = False
        elif self.in_table and tag == 'tr' and self.row: self.rows.append(self.row)
        elif tag in ('td','th'): self.in_cell = False; self.row.append(self.cell.strip())
    def handle_data(self, data):
        if self.in_cell: self.cell += data

p = P()
p.feed(sys.stdin.read())
# Kolumny: 0=data, 7=WIBOR 1M, 8=WIBOR 3M, 9=WIBOR 6M
for row in p.rows[2:]:  # pomijamy 2 wiersze nagłówka
    if len(row) >= 10 and row[0][:2] == '20':
        r = row[0].replace(',','.')
        print(f'{row[0]}\t{row[7].replace(\",\",\".\")}\t{row[8].replace(\",\",\".\")}\t{row[9].replace(\",\",\".\")}')
")

if [ -z "$PARSED" ]; then
  echo "ERROR: nie udało się sparsować tabeli"
  exit 1
fi

for TENOR_IDX in "1m:1" "3m:2" "6m:3"; do
  TENOR="${TENOR_IDX%%:*}"
  COL="${TENOR_IDX##*:}"
  FILE="${DIR}/wibor-${TENOR}.json"

  # Ostatnia znana data
  if [ -f "$FILE" ] && [ -s "$FILE" ]; then
    LAST_DATE=$(jq -r '.[-1].d' "$FILE")
  else
    LAST_DATE="1999-12-31"
  fi

  # Filtruj tylko nowe rekordy (data > LAST_DATE), odwróć (najstarsze pierwsze)
  NEW=$(echo "$PARSED" | awk -F'\t' -v last="$LAST_DATE" -v col="$COL" \
    '$1 > last {print $1 "\t" $(col+1)}' | sort -t$'\t' -k1,1 \
    | jq -Rsc '
      split("\n") | map(select(length>0) | split("\t") | {d:.[0], r:(.[1]|tonumber)})
    ')

  NEW_COUNT=$(echo "$NEW" | jq length)
  if [ "$NEW_COUNT" -eq 0 ]; then
    echo "SKIP $TENOR — dane aktualne do ${LAST_DATE}"
    continue
  fi

  # Dopisz nowe rekordy
  jq -s '.[0] + .[1]' "$FILE" <(echo "$NEW") > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"

  COUNT=$(jq length "$FILE")
  LAST=$(jq -r '.[-1].d' "$FILE")
  echo "OK wibor-${TENOR}: +${NEW_COUNT} nowych, razem ${COUNT}, ostatnia ${LAST}"
done

# Metadane
jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{updated: $ts}' > "${DIR}/meta.json"
echo "Done — $(cat ${DIR}/meta.json)"
