#!/bin/bash
# update_imported_to_lightroom_hashes.sh
# Fast, truly incremental hashing for Lightroom import folder.
# CSV columns: sha1sum,absolute_path,original_filename,created_date,import_date,mtime,size

set -e

# Source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!"
  exit 1
fi
source "$CONFIG_FILE"

IMPORT_DIR="$IMPORTED_TO_LR"
CSV_FILE="$LIGHTROOM_HASH_CSV"
DEVICE_HASHES="$DEVICE_HASH_LOG"

start_time=$(date +%s)
echo "[INFO] Start: $(date)"

# Build hash -> original filename map from device_copied_hashes.txt
# (hash, path)
declare -A hash_to_orig
if [ -f "$DEVICE_HASHES" ]; then
  while read -r hash path; do
    hash_to_orig["$hash"]="$(basename "$path")"
  done < "$DEVICE_HASHES"
fi

# Build path+mtime+size -> hash map from existing CSV
# (path, mtime, size, hash, orig, created_date, import_date)
declare -A filekey_to_row
if [ -f "$CSV_FILE" ]; then
  {
    read # skip header
    while IFS=, read -r hash path orig created_date import_date mtime size; do
      path_unquoted=$(echo "$path" | sed 's/^"\(.*\)"$/\1/')
      filekey="${path_unquoted}|${mtime}|${size}"
      filekey_to_row["$filekey"]="$hash,$path,$orig,$created_date,$import_date,$mtime,$size"
    done
  } < "$CSV_FILE"
fi

mid_time=$(date +%s)
echo "[INFO] Finished loading CSV and device hashes: $(date) (Elapsed: $((mid_time-start_time))s)"

# Prepare output
TMP_CSV="${CSV_FILE}.tmp"
echo "sha1sum,absolute_path,original_filename,created_date,import_date,mtime,size" > "$TMP_CSV"

# Cache for parent folder import date
declare -A folder_import_date

count=0
skipped=0
hashed=0

set -x
trap 'echo "[ERROR] at line $LINENO: $BASH_COMMAND"' ERR

find "$IMPORT_DIR" -type f -print0 || true | while IFS= read -r -d '' f; do
  ((count++))
  mtime=$(stat -c '%Y' "$f")
  size=$(stat -c '%s' "$f")
  filekey="$f|$mtime|$size"
  hash=""
  orig=""
  created_date=$(stat -c '%W' "$f")
  [ "$created_date" = "0" ] && created_date=$(stat -c '%Y' "$f")
  created_date_fmt=$(date -d "@$created_date" '+%Y-%m-%d %H:%M:%S')
  parent_dir=$(dirname "$f")
  if [[ -z "${folder_import_date[$parent_dir]}" ]]; then
    import_date=$(stat -c '%W' "$parent_dir")
    [ "$import_date" = "0" ] && import_date=$(stat -c '%Y' "$parent_dir")
    import_date_fmt=$(date -d "@$import_date" '+%Y-%m-%d %H:%M:%S')
    folder_import_date["$parent_dir"]="$import_date_fmt"
  fi
  import_date_fmt="${folder_import_date[$parent_dir]}"
  # Check if we can reuse hash
  if [[ -n "${filekey_to_row[$filekey]}" ]]; then
    row="${filekey_to_row[$filekey]}"
    echo "$row" >> "$TMP_CSV"
    ((skipped++))
    continue
  fi
  hash=$(sha1sum "$f" | awk '{print $1}')
  orig="${hash_to_orig[$hash]}"
  safe_f="${f//\"/\"\"}"
  echo "$hash,\"$safe_f\",$orig,$created_date_fmt,$import_date_fmt,$mtime,$size" >> "$TMP_CSV"
  ((hashed++))
done

wait

end_time=$(date +%s)
echo "[INFO] Finished hashing: $(date) (Elapsed: $((end_time-mid_time))s)"
echo "[INFO] Total files: $count, Skipped (cache hit): $skipped, Hashed: $hashed"

mv "$TMP_CSV" "$CSV_FILE"
echo "Done. CSV updated: $CSV_FILE"
echo "[INFO] Total elapsed: $((end_time-start_time))s"
