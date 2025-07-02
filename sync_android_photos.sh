#!/bin/bash
# File: sync_android_photos.sh
#
# Interactive script to sync/move Android photos to a local temporary folder for Lightroom import.
#
# Logic & Workflow:
# 1. Loads configuration (connection, folders, exclusions, import log, etc.).
# 2. Lists subfolders on the phone (excluding those in config) and lets you select which to process.
# 3. For each selected subfolder:
#    - Prompts for copy/move, file selection criteria (all, since last, after/before date), and deletion options.
#    - Builds a file list using date filters and import log.
#    - Shows a summary (file count, oldest/newest, files to delete if chosen).
#    - Prompts for confirmation before syncing and before deleting.
#    - Performs sync with rsync.
#    - Updates the import log with files that were copied/moved.
#    - If deletion is chosen, only deletes files that are both on the phone and in the import log, after a final confirmation.
#
# This ensures you only delete files that have been safely imported into Lightroom, and gives you full control and feedback at every step.
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

# resolve script directory for config and logs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/sync_config.conf"
LOG_FILE="$SCRIPT_DIR/sync_log.txt"

echo -e "${YELLOW}🔧 Loading configuration from $CONFIG_FILE ...${NC}"
# Load config
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}❌ Config file $CONFIG_FILE not found!${NC}"
  exit 1
fi
source "$CONFIG_FILE"

# set -x

# Helper: join array with delimiter
join_by() { local IFS="$1"; shift; echo "$*"; }

# List subfolders on phone, filter with EXCLUDE_FOLDERS
IFS=',' read -ra EXCL <<< "$EXCLUDE_FOLDERS"
EXCL_PATTERN=$(join_by '|' "${EXCL[@]}")

SUBFOLDERS=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "ls -1d $REMOTE_DIR*/ 2>/dev/null | xargs -n1 basename" | grep -vE "^($EXCL_PATTERN)")

if [ -z "$SUBFOLDERS" ]; then
  echo -e "${RED}No subfolders found in $REMOTE_DIR!${NC}"
  exit 1
fi

# Prompt for subfolder selection
echo -e "${WHITE}Available subfolders on phone:${NC}"
select folder in $SUBFOLDERS "All"; do
  if [[ -n "$folder" ]]; then
    if [[ "$folder" == "All" ]]; then
      SELECTED_FOLDERS=($SUBFOLDERS)
    else
      SELECTED_FOLDERS=("$folder")
    fi
    break
  else
    echo -e "${YELLOW}Please select a valid option.${NC}"
  fi
done

echo -e "${GREEN}Selected folder(s): $(join_by ', ' "${SELECTED_FOLDERS[@]}")${NC}"

# Set up log files with year-based rotation
YEAR=$(date +%Y)
SUMMARY_LOG="$SCRIPT_DIR/sync_log_$YEAR.txt"
FILE_LOG="$SCRIPT_DIR/sync_file_log_$YEAR.csv"
IMPORT_LOG_FILE="$SCRIPT_DIR/imported_files.log"

# Write CSV header if file does not exist
if [ ! -f "$FILE_LOG" ]; then
  echo "datetime,action,src_path,dest_path,status" > "$FILE_LOG"
fi

# For each selected subfolder, prompt for options
for SUBF in "${SELECTED_FOLDERS[@]}"; do
  # --- Write summary header ---
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  echo "" >> "$SUMMARY_LOG"
  echo "[$NOW] Processing subfolder: $SUBF" >> "$SUMMARY_LOG"
  echo "  Selection rule: $FILE_FILTER" >> "$SUMMARY_LOG"
  echo "  Action: $ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF" >> "$SUMMARY_LOG"

  echo -e "\n${WHITE}--- Processing subfolder: $SUBF ---${NC}"
  # Prompt for copy or move
  echo -ne "${YELLOW}Do you want to copy or move files from $SUBF? (c/m) [c]: ${NC}"
  read cmode
  [[ -z "$cmode" ]] && cmode="c"
  if [[ "$cmode" == "m" ]]; then
    ACTION="move"
  else
    ACTION="copy"
  fi

  # Prompt for file selection criteria
  echo -e "${WHITE}File selection options:${NC}"
  echo "  1) All files"
  echo "  2) Since last copy/move (default)"
  echo "  3) After a date"
  echo "  4) Before a date"
  echo "  5) Between two dates"
  echo -ne "${YELLOW}Choose file selection [2]: ${NC}"
  read fsel
  [[ -z "$fsel" ]] && fsel=2

  # --- Determine last sync/move time from CSV log if needed ---
  LAST_SYNC_DATE=""
  if [[ "$fsel" == "2" ]]; then
    LAST_SYNC_DATE=$(awk -F, -v subf="$SUBF" 'tolower($2) ~ /copy|move/ && $3 ~ subf {print $1}' "$FILE_LOG" | sort | tail -1)
    echo "DEBUG: LAST_SYNC_DATE for $SUBF is '$LAST_SYNC_DATE'"
  fi

  case $fsel in
    1) FILE_FILTER="all";;
    3)
      echo -ne "${YELLOW}Enter start date (format: YYYY-MM-DD): ${NC}"
      read START_DATE
      FILE_FILTER="after";;
    4)
      echo -ne "${YELLOW}Enter end date (format: YYYY-MM-DD): ${NC}"
      read END_DATE
      FILE_FILTER="before";;
    5)
      echo -ne "${YELLOW}Enter start date (format: YYYY-MM-DD): ${NC}"
      read START_DATE
      echo -ne "${YELLOW}Enter end date (format: YYYY-MM-DD): ${NC}"
      read END_DATE
      FILE_FILTER="between";;
    *) FILE_FILTER="since_last";;
  esac

  # Prompt for deletion
  echo -ne "${YELLOW}Delete files on phone that have been imported? (y/N): ${NC}"
  read delopt
  [[ "$delopt" =~ ^[Yy]$ ]] && DELETE_IMPORTED=1 || DELETE_IMPORTED=0

  # --- Build file list on phone ---
  REMOTE_SUBFOLDER="$REMOTE_DIR/$SUBF"
  # List files, filter by date and EXCLUDE_BEFORE_DATE
  FIND_CMD="find '$REMOTE_SUBFOLDER' -type f"
  if [[ "$FILE_FILTER" == "after" && -n "$START_DATE" ]]; then
    # Use the later of EXCLUDE_BEFORE_DATE and START_DATE
    if [[ -n "$EXCLUDE_BEFORE_DATE" ]]; then
      if [[ "$START_DATE" < "$EXCLUDE_BEFORE_DATE" ]]; then
        FIND_CMD+=" -newermt '$EXCLUDE_BEFORE_DATE'"
      else
        FIND_CMD+=" -newermt '$START_DATE'"
      fi
    else
      FIND_CMD+=" -newermt '$START_DATE'"
    fi
  elif [[ "$FILE_FILTER" == "before" && -n "$END_DATE" ]]; then
    FIND_CMD+=" ! -newermt '$END_DATE'"
  elif [[ "$FILE_FILTER" == "between" && -n "$START_DATE" && -n "$END_DATE" ]]; then
    FIND_CMD+=" -newermt '$START_DATE' ! -newermt '$END_DATE'"
  elif [[ "$FILE_FILTER" == "since_last" && -n "$LAST_SYNC_DATE" ]]; then
    FIND_CMD+=" -newermt '$LAST_SYNC_DATE'"
  elif [[ "$FILE_FILTER" == "all" ]]; then
    if [[ -n "$EXCLUDE_BEFORE_DATE" ]]; then
      FIND_CMD+=" -newermt '$EXCLUDE_BEFORE_DATE'"
    fi
  fi
  echo "DEBUG: FIND_CMD is $FIND_CMD"
  # Get file list from phone
  FILE_LIST=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD" | sort)
  FILE_COUNT=$(echo "$FILE_LIST" | grep -c ".")

  # Get oldest and newest file dates
  if [[ $FILE_COUNT -gt 0 ]]; then
    OLDEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-")
    NEWEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-")
    OLDEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$OLDEST_FILE' | cut -d'.' -f1")
    NEWEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$NEWEST_FILE' | cut -d'.' -f1")
  else
    OLDEST_DATE="-"
    NEWEST_DATE="-"
  fi

  # --- Show summary ---
  echo -e "${WHITE}Summary for $SUBF:${NC}"
  echo -e "  ${GRAY}Number of files: ${WHITE}$FILE_COUNT${NC}"
  echo -e "  ${GRAY}Oldest file: ${WHITE}$OLDEST_DATE${NC}"
  echo -e "  ${GRAY}Newest file: ${WHITE}$NEWEST_DATE${NC}"
  echo "  Number of files: $FILE_COUNT" >> "$SUMMARY_LOG"
  echo "  Oldest file: $OLDEST_DATE" >> "$SUMMARY_LOG"
  echo "  Newest file: $NEWEST_DATE" >> "$SUMMARY_LOG"

  # --- Deletion preview ---
  if [[ $DELETE_IMPORTED -eq 1 && $FILE_COUNT -gt 0 ]]; then
    # Only delete files that are in the import log
    if [ -f "$IMPORT_LOG_FILE" ]; then
      FILES_TO_DELETE=$(comm -12 <(echo "$FILE_LIST" | sort) <(awk '{print $1}' "$IMPORT_LOG_FILE" | sort))
      DELETE_COUNT=$(echo "$FILES_TO_DELETE" | grep -c ".")
    else
      DELETE_COUNT=0
    fi
    echo -e "  ${GRAY}Files to be deleted: ${WHITE}$DELETE_COUNT${NC}"
    echo "  Files to be deleted: $DELETE_COUNT" >> "$SUMMARY_LOG"
  fi

  # --- Confirm ---
  echo -ne "${YELLOW}Proceed with sync for $SUBF? (y/N): ${NC}"
  read go
  if [[ ! "$go" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Skipping $SUBF${NC}"
    echo "  Skipped by user." >> "$SUMMARY_LOG"
    continue
  fi

  # --- Perform sync ---
  LOCAL_SUBFOLDER="$LOCAL_DIR/$SUBF"
  mkdir -p "$LOCAL_SUBFOLDER"
  RSYNC_OPTS="-av --progress"
  [[ "$ACTION" == "copy" ]] && RSYNC_OPTS+=" --ignore-existing"
  RSYNC_CMD="rsync $RSYNC_OPTS -e \"ssh -i $SSH_KEY -p $PHONE_PORT\" $PHONE_USER@$PHONE_IP:'$REMOTE_SUBFOLDER/' '$LOCAL_SUBFOLDER/'"
  echo -e "${GREEN}Starting sync for $SUBF...${NC}"
  # Log each file copied/moved
  eval "$RSYNC_CMD --out-format='%n'" | while read -r relfile; do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    src="$REMOTE_SUBFOLDER/$relfile"
    dest="$LOCAL_SUBFOLDER/$relfile"
    echo "$NOW,$ACTION,$src,$dest,success" >> "$FILE_LOG"
  done
  echo -e "${GREEN}Sync complete for $SUBF.${NC}"
  echo "  Sync complete for $SUBF." >> "$SUMMARY_LOG"

  # --- Update import log ---
  # Log all files now present in local subfolder
  find "$LOCAL_SUBFOLDER" -type f | while read -r f; do
    echo "$f" >> "$IMPORT_LOG_FILE"
  done

  # --- Deletion step ---
  if [[ $DELETE_IMPORTED -eq 1 && $DELETE_COUNT -gt 0 ]]; then
    echo -ne "${YELLOW}About to delete $DELETE_COUNT files from phone in $SUBF. Continue? (y/N): ${NC}"
    read del_confirm
    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
      echo "$FILES_TO_DELETE" | while read -r del_file; do
        ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "rm -f '$del_file'" && \
        NOW=$(date '+%Y-%m-%d %H:%M:%S'); echo "$NOW,deleted,$del_file,,success" >> "$FILE_LOG"
      done
      echo -e "${GREEN}Deleted $DELETE_COUNT files from phone in $SUBF.${NC}"
      echo "  Deleted $DELETE_COUNT files from phone in $SUBF." >> "$SUMMARY_LOG"
    else
      echo -e "${RED}Deletion cancelled for $SUBF.${NC}"
      echo "  Deletion cancelled for $SUBF." >> "$SUMMARY_LOG"
    fi
  fi

done



