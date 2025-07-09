# Log Files Guide

This guide explains the log files created and used by the photo import and deletion scripts. All log file locations and names are set in `config.conf`.

## Main Log Files (User-Facing)

### `sync_log_YYYY.txt`
- **Purpose:** Human-readable summary of each copy/import session (device to computer)
- **Content:** Timestamps, file counts, actions, and results for each sync
- **Location:** Same directory as the scripts (see `config.conf`)
- **Check after:** Each import session

### `delete_copied_summary_YYYY.txt`
- **Purpose:** Human-readable summary of all deletion operations (after Lightroom import)
- **Content:** Timestamps, file counts, and results for each deletion session
- **Location:** Same directory as the scripts (see `config.conf`)
- **Check after:** Each deletion/cleanup session

## Detailed Log Files (For Troubleshooting/Analysis)

### `device_sync_log_YYYY.csv`
- **Purpose:** Detailed CSV log of every file copied/moved (device to computer)
- **Content:** `datetime,action,src_path,dest_path,status`
- **Location:** Same directory as the scripts (see `config.conf`)
- **Use for:** Troubleshooting, auditing, or analyzing file transfers

### `copied_device_files.log`
- **Purpose:** Internal database of all files copied from device (with mtime)
- **Content:** One file path per line, optionally with `|mtime`
- **Location:** Set in `config.conf`
- **Use for:** Internal filtering by scripts (do not edit manually)

## Hash Database Files (Deduplication & Provenance)

### `device_copied_hashes.txt`
- **Purpose:** SHA1 hash database for deduplication and safe deletion
- **Content:** `sha1sum path` for all files copied from device
- **Location:** Set in `config.conf`
- **Use for:** Internal by scripts; ensures files are not re-copied or deleted unsafely

### `imported_to_lightroom_hashes.csv`
- **Purpose:** Central, incremental CSV database of all files in the Lightroom import folder
- **Content:** `sha1sum,absolute_path,original_filename,imported_date` (quoted as needed)
- **Location:** Set in `config.conf`
- **Use for:** Deduplication, provenance, and safe deletion; used by all scripts

## Temporary Files

Scripts create temporary files (e.g., `*_hashes_only.txt`, `files_to_delete.txt`) during operation. These are automatically cleaned up after each run.

## File Locations & Configuration

All log file locations and names are set in `config.conf`. Edit this file to change where logs are stored or to match your folder structure.

## Year-based Rotation

Log files use year-based naming (e.g., `sync_log_2025.txt`) to keep historical data organized. Each year gets its own set of log files.

---

**Obsolete/Legacy Files:**
- Files like `imported_to_lightroom_files.txt` are no longer used. All path lists and provenance are now handled via `imported_to_lightroom_hashes.csv`.

