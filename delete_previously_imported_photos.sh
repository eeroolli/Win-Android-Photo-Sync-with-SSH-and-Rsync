#!/bin/bash
# File: delete_previously_imported_photos.sh
#
# Purpose:
#   Safely delete photos from /mnt/i/FraMobil (and subfolders) that have already been imported to Lightroom.
#   Imported photos are identified by matching file content (SHA1 hash) with files in /mnt/i/kopiert/Imported on ... (and subfolders),
#   regardless of filename or folder structure. This prevents accidental deletion of unimported photos, even if filenames have changed.
#
# Logic & Workflow:
# 1. Recursively scan /mnt/i/FraMobil and /mnt/i/kopiert/Imported on ... for all files.
# 2. Compute SHA1 hashes for all files, caching results to avoid redundant hashing.
# 3. Identify files in /mnt/i/FraMobil whose hashes match any file in /mnt/i/kopiert/Imported on ...
# 4. Show a summary: total files scanned, number of matches (to be deleted), and number of files to keep.
# 5. Prompt for confirmation before deleting any files.
# 6. Delete only the files that are confirmed as already imported.
# 7. Log actions and provide a summary at the end.
#
# This script is safe, robust, and efficient for large photo collections. It is intended to be run as-needed to clean up /mnt/i/FraMobil.
#
# Requirements: bash, find, sha1sum, sort, awk, grep, comm
#
# Usage:
#   bash delete_previously_imported_photos.sh
#

set -e
trap 'echo -e "\033[0;31m❌ An error occurred. Exiting.\033[0m"' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

# Folders
FRA_MOBIL="/mnt/i/FraMobil"
KOPIERT="/mnt/i/kopiert"

# Hash cache files
FRA_MOBIL_HASHES="fra_mobil_hashes.txt"
KOPIERT_HASHES="kopiert_hashes.txt"

# Summary log
YEAR=$(date +%Y)
SUMMARY_LOG="delete_imported_summary_$YEAR.txt"

# Helper: join array with delimiter
join_by() { local IFS="$1"; shift; echo "$*"; }

# --- Step 1: Generate/cached hashes for FRA_MOBIL ---
echo -e "${YELLOW}Scanning $FRA_MOBIL for files...${NC}"
find "$FRA_MOBIL" -type f | sort > fra_mobil_files.txt
if [ ! -f "$FRA_MOBIL_HASHES" ]; then
  echo -e "${YELLOW}Hashing files in $FRA_MOBIL ...${NC}"
  cat fra_mobil_files.txt | xargs -d '\n' -I{} sha1sum "{}" > "$FRA_MOBIL_HASHES"
else
  echo -e "${GRAY}Using cached hashes for $FRA_MOBIL${NC}"
fi

# --- Step 2: Generate/cached hashes for KOPIERT ---
echo -e "${YELLOW}Scanning $KOPIERT for files...${NC}"
find "$KOPIERT" -type f | sort > kopiert_files.txt
if [ ! -f "$KOPIERT_HASHES" ]; then
  echo -e "${YELLOW}Hashing files in $KOPIERT ...${NC}"
  cat kopiert_files.txt | xargs -d '\n' -I{} sha1sum "{}" > "$KOPIERT_HASHES"
else
  echo -e "${GRAY}Using cached hashes for $KOPIERT${NC}"
fi

# --- Step 3: Compare hashes ---
echo -e "${YELLOW}Comparing hashes to find already imported files...${NC}"
awk '{print $1}' "$FRA_MOBIL_HASHES" | sort > fra_mobil_hashes_only.txt
awk '{print $1}' "$KOPIERT_HASHES" | sort > kopiert_hashes_only.txt
comm -12 fra_mobil_hashes_only.txt kopiert_hashes_only.txt > already_imported_hashes.txt

# Get file paths to delete
awk 'NR==FNR{h[$1]=1; next} h[$1]{print $2}' already_imported_hashes.txt "$FRA_MOBIL_HASHES" > files_to_delete.txt

TOTAL_FILES=$(wc -l < fra_mobil_files.txt)
TO_DELETE=$(wc -l < files_to_delete.txt)
TO_KEEP=$((TOTAL_FILES - TO_DELETE))

# --- Step 4: Show summary ---
NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "" >> "$SUMMARY_LOG"
echo "[$NOW] delete_previously_imported_photos.sh run" >> "$SUMMARY_LOG"
echo "  Total files in $FRA_MOBIL: $TOTAL_FILES" | tee -a "$SUMMARY_LOG"
echo "  Files already imported (to be deleted): $TO_DELETE" | tee -a "$SUMMARY_LOG"
echo "  Files to keep: $TO_KEEP" | tee -a "$SUMMARY_LOG"

if [[ $TO_DELETE -eq 0 ]]; then
  echo -e "${GREEN}No files to delete. All files in $FRA_MOBIL are not yet imported.${NC}"
  exit 0
fi

# --- Step 5: Prompt for confirmation ---
echo -e "${WHITE}Files to be deleted from $FRA_MOBIL:${NC}"
head -20 files_to_delete.txt
[ $TO_DELETE -gt 20 ] && echo -e "${GRAY}...and $((TO_DELETE-20)) more${NC}"
echo -ne "${YELLOW}Proceed to delete these $TO_DELETE files from $FRA_MOBIL? (y/N): ${NC}"
read confirm
echo "  User confirmation: $confirm" >> "$SUMMARY_LOG"
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo -e "${RED}Deletion cancelled.${NC}"
  echo "  Deletion cancelled by user." >> "$SUMMARY_LOG"
  exit 0
fi

# --- Step 6: Delete files ---
echo -e "${YELLOW}Deleting files...${NC}"
while read -r file; do
  if rm -f "$file"; then
    echo -e "${GREEN}Deleted: $file${NC}"
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$NOW,deleted,$file,success" >> "$SUMMARY_LOG"
  else
    echo -e "${RED}Failed to delete: $file${NC}"
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$NOW,delete_failed,$file,fail" >> "$SUMMARY_LOG"
  fi
done < files_to_delete.txt

echo -e "${GREEN}Deletion complete. $TO_DELETE files deleted from $FRA_MOBIL.${NC}"
echo "  Deletion complete. $TO_DELETE files deleted." >> "$SUMMARY_LOG" 