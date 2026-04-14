#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

CONFIG="${NG_DEPS_CONFIG:-$NG_ROOT/config/dependencies.json}"
OUT="${1:-$NG_VAR_DIR/dependency-catalog.json}"
UPLOAD="${NG_DEPS_UPLOAD:-0}"
require_cmd jq

tmp="$(mktemp)"
jq -n '{generatedAt: now | todateiso8601, platforms: {}}' > "$tmp"

platforms="$(jq -r '.platforms | keys[]' "$CONFIG")"
for platform in $platforms; do
  platform_json="$(jq -c --arg platform "$platform" '.platforms[$platform]' "$CONFIG")"
  items="$(jq -c '.items[]?' <<<"$platform_json")"
  item_array="$(mktemp)"
  printf '[]' > "$item_array"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    kind="$(jq -r '.kind' <<<"$item")"
    id="$(jq -r '.id' <<<"$item")"
    if [[ "$kind" == "local-file" ]]; then
      path="$(jq -r '.path' <<<"$item")"
      if [[ -f "$path" ]]; then
        size="$(stat -c %s "$path")"
        sha="$(sha256sum "$path" | awk '{print $1}')"
        s3_uri=""
        if [[ "$UPLOAD" == "1" ]]; then
          bucket="$(jq -r '.artifactBucket' "$CONFIG")/$platform/$id"
          s3_uri="$("$SCRIPT_DIR/upload-artifact.sh" "$path" "$bucket" | tail -1)"
        fi
        jq --arg id "$id" --arg kind "$kind" --arg path "$path" --arg sha "$sha" --argjson size "$size" --arg s3 "$s3_uri" \
          '. += [{id:$id, kind:$kind, path:$path, size:$size, sha256:$sha, s3:$s3}]' "$item_array" > "$item_array.next"
        mv "$item_array.next" "$item_array"
      else
        jq --arg id "$id" --arg kind "$kind" --arg path "$path" \
          '. += [{id:$id, kind:$kind, path:$path, missing:true}]' "$item_array" > "$item_array.next"
        mv "$item_array.next" "$item_array"
      fi
    elif [[ "$kind" == "s3-prefix" ]]; then
      uri="$(jq -r '.uri' <<<"$item")"
      jq --arg id "$id" --arg kind "$kind" --arg uri "$uri" \
        '. += [{id:$id, kind:$kind, uri:$uri}]' "$item_array" > "$item_array.next"
      mv "$item_array.next" "$item_array"
    fi
  done <<<"$items"

  jq --arg platform "$platform" --argjson meta "$platform_json" --slurpfile items "$item_array" \
    '.platforms[$platform] = ($meta + {catalogedItems: $items[0]})' "$tmp" > "$tmp.next"
  mv "$tmp.next" "$tmp"
  rm -f "$item_array"
done

mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
cat "$OUT"

