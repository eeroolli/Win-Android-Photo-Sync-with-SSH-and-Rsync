# Log Files Guide

This document explains all the log files created by the photo import and deletion scripts.

## Main Log Files (Most Important for Users)

### `sync_log_YYYY.txt`
- **Purpose**: Human-readable summary of all copy operations (device to computer)
- **Content**: High-level overview of each sync session with timestamps, file counts, and actions taken
- **When to check**: Review after each import session to see what was processed
- **Example**:
  ```
  [2025-07-03 23:09:26] Processing subfolder: Camera
    Selection rule: since_last
    Action: copy from /storage/emulated/0/DCIM/Camera to /mnt/i/FraMobil/Camera
    Number of files: 1
    Oldest file: 2025-06-04 08:23:42
    Newest file: 2025-07-02 13:20:25
    Sync complete for Camera.
  ```

### `delete_copied_summary_YYYY.txt`
- **Purpose**: Human-readable summary of all deletion operations (after Lightroom import)
- **Content**: Overview of files deleted from source folders after they have been imported to Lightroom
- **When to check**: Review after running the deletion script to see what was cleaned up
- **Example**:
  ```
  [2025-07-02 21:15:30] delete_previously_copied_photos.sh run for /mnt/i/FraMobil
    Total files in /mnt/i/FraMobil: 1250
    Files already copied (to be deleted): 45
    Files to keep: 1205
    Deletion complete. 45 files deleted from /mnt/i/FraMobil.
  ```

## Detailed Log Files (For Analysis)

### `device_sync_log_YYYY.csv`
- **Purpose**: Detailed CSV log of each file copied/moved (device to computer)
- **Content**: Timestamp, action, source path, destination path, status
- **When to check**: For detailed analysis or troubleshooting specific files
- **Format**: CSV with columns: datetime,action,src_path,dest_path,status

### `copied_device_files.log`
- **Purpose**: Database of all files copied from device (device to computer)
- **Content**: Full paths and modification times of copied files
- **When to check**: Used internally by scripts for filtering (don't edit manually)
- **Format**: One file path per line with modification time

## Hash Database Files (For Deduplication)

### `device_copied_hashes.txt`
- **Purpose**: SHA1 hash database for deduplication and safe deletion (device to computer)
- **Content**: SHA1 hash and file path for all copied files
- **When to check**: Used by deletion script to safely identify duplicate files
- **Format**: SHA1 hash followed by file path

## Other Files

### `imported_to_lightroom_files.txt`
- **Purpose**: List of files in the Lightroom import folder
- **Content**: All files in /mnt/i/imported_to_lightroom/Imported on... folders
- **When to check**: Used by deletion script to identify imported files

## Temporary Files

The scripts create temporary hash files during operation (e.g., `*_hashes_only.txt`, `files_to_delete.txt`). These are automatically cleaned up after each run.

## File Locations

All log files are stored in the same directory as the scripts:
- `/mnt/f/prog/sshphone/` (or wherever you cloned the repository)
- Lightroom import folder: `/mnt/i/imported_to_lightroom/`

## Year-based Rotation

Log files use year-based naming (e.g., `sync_log_2025.txt`) to keep historical data organized. Each year gets its own set of log files. 