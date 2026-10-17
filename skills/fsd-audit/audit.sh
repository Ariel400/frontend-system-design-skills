#!/usr/bin/env bash
# Grille projet × pratique « Frontend System Design ».
# Usage : audit.sh [dossier_projet ...]   (sans argument : chaque sous-dossier du répertoire courant qui contient un package.json)
# Chaque colonne est un SIGNAL issu de greps, à confirmer avec le skill fsd-* correspondant avant d'affirmer quoi que ce soit.
set -uo pipefail

EXCL=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist --exclude-dir=build --exclude-dir=.expo
      --exclude-dir=android --exclude-dir=ios --exclude-dir=coverage --exclude-dir=.turbo)
INC=(--include=*.ts --include=*.tsx --include=*.js --include=*.jsx)

files()  { grep -rlE "$2" "$1" "${EXCL[@]}" "${INC[@]}" 2>/dev/null | wc -l | tr -d ' '; }
lines()  { grep -rhE "$2" "$1" "${EXCL[@]}" "${INC[@]}" 2>/dev/null | wc -l | tr -d ' '; }
pkgs()   { find "$1" -name package.json -not -path '*/node_modules/*' -maxdepth 4 2>/dev/null; }
hasdep() { pkgs "$1" | xargs grep -lqE "\"$2\"" 2>/dev/null && echo 1 || echo 0; }

if [ $# -eq 0 ]; then
  set -- $(for d in */; do [ -f "$d/package.json" ] || [ -n "$(pkgs "$d" | head -1)" ] && echo "${d%/}"; done)
fi

echo "| projet | pile | req: queryFn sans signal | err: error.tsx / global | perf: pages use client | perf: mounted | perf: vitals | a11y: axe / lint | a11y: div onClick | rt: setInterval refetch | rt: sockets | pag: infini sur page | ent: rôle comparé en UI | cache: ETag/Cache-Control (API) |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"

for p in "$@"; do
  [ -d "$p" ] || continue
  stack=""
  [ "$(hasdep "$p" next)" = 1 ] && stack+="next "
  [ "$(hasdep "$p" vite)" = 1 ] && stack+="vite "
  [ "$(hasdep "$p" expo)" = 1 ] && stack+="expo "
  [ "$(hasdep "$p" '@nestjs/core')" = 1 ] && stack+="nest "
  [ "$(hasdep "$p" '@tanstack/react-query')" = 1 ] && stack+="RQ "
  [ "$(hasdep "$p" '@reduxjs/toolkit')" = 1 ] && stack+="RTK "
  [ -z "$stack" ] && stack="?"

  if [[ "$stack" == *nest* && "$stack" != *next* && "$stack" != *vite* && "$stack" != *expo* ]]; then
    etag=$( [ "$(hasdep "$p" '@fastify/etag')" = 1 ] && echo "etag" || echo "-" )
    cc=$(lines "$p" "Cache-Control")
    echo "| $p | $stack | | | | | | | | | | | | $etag / $cc |"
    continue
  fi

  # RTK Query transmet le signal tout seul : la colonne ne concerne que React Query
  qf="n/a"; [[ "$stack" == *RQ* ]] && qf=$(grep -rhE "queryFn" "$p" "${EXCL[@]}" "${INC[@]}" 2>/dev/null | grep -vc signal)
  errp=$(find "$p" -name 'error.tsx' -not -path '*/node_modules/*' -not -path '*/.next/*' | wc -l | tr -d ' ')
  errg=$(find "$p" -name 'global-error.tsx' -not -path '*/node_modules/*' | wc -l | tr -d ' ')
  pages=$(find "$p" -name 'page.tsx' -path '*/app/*' -not -path '*/node_modules/*' -not -path '*/.next/*' | wc -l | tr -d ' ')
  ucp=$(find "$p" -name 'page.tsx' -path '*/app/*' -not -path '*/node_modules/*' -not -path '*/.next/*' -print0 | xargs -0 grep -lE "^['\"]use client['\"]" 2>/dev/null | wc -l | tr -d ' ')
  mnt=$(files "$p" "set(Is)?(Mounted|Hydrated)\(true\)")
  vit=$(files "$p" "useReportWebVitals|web-vitals")
  axe=$( { [ "$(hasdep "$p" '@axe-core/playwright')" = 1 ] || [ "$(hasdep "$p" 'jest-axe')" = 1 ] || [ "$(hasdep "$p" 'vitest-axe')" = 1 ]; } && echo "axe" || echo "-")
  lint=$( [ "$(hasdep "$p" 'eslint-plugin-jsx-a11y')" = 1 ] && echo "jsx-a11y" || echo "-")
  divc=$(grep -rhE "<(div|span)[^>]*onClick=" "$p" "${EXCL[@]}" --include=*.tsx --include=*.jsx 2>/dev/null | grep -v 'role=' | grep -vc 'stopPropagation')
  poll=$(grep -rhE -A3 "setInterval\(" "$p" "${EXCL[@]}" "${INC[@]}" 2>/dev/null | grep -ciE "refetch|fetch\(|load|refresh")
  sock=$(files "$p" "from ['\"]socket\.io-client['\"]|new WebSocket\(|new EventSource\(")
  pag=$(grep -rhE -A6 "useInfiniteQuery" "$p" "${EXCL[@]}" "${INC[@]}" 2>/dev/null | grep -cE "nextPage|page \+ 1|pageParam \+ 1")
  acc=$(lines "$p" "setAccumulated|new Set\(prev\.map")
  ent=$(grep -rhE "(role|profile|_profile|planType|plan)\s*[!=]==?\s*['\"][A-Za-z_]+['\"]" "$p" "${EXCL[@]}" --include=*.tsx 2>/dev/null | wc -l | tr -d ' ')
  isx=$(lines "$p" "\bis(Admin|Administrator|SuperAdmin|Premium|Owner)\w*\(")

  ucol="-"; [ "$pages" -gt 0 ] && ucol="$ucp/$pages"
  echo "| $p | $stack | $qf | $errp / $errg | $ucol | $mnt | $vit | $axe / $lint | $divc | $poll | $sock | $pag (+$acc accum.) | $ent (+$isx is*()) | |"
done
