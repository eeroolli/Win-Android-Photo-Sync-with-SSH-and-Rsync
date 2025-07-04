# Android Photo Sync Script

## Purpose

This repository provides an interactive Bash script to safely copy or move photos from an Android phone (via SSH) to a local folder on your computer.  
It is designed for workflows where the local folder is a temporary staging area (e.g., for importing into Lightroom), and includes robust options for filtering, logging, and safe deletion of files on the phone only after they have been copied.

## Features

- Interactive selection of photo subfolders (e.g., Camera, Screenshots, etc.)
- Filter files by date, since last copy, or all
- Option to copy or move files
- Optionally delete files from the phone only after they have been copied
- Configurable exclusions and logging
- Colorful, user-friendly prompts
- **Centralized, incremental hash database for Lightroom import folder**

## Requirements

### On Your Computer (WSL/Linux)
- **Bash** (the script is written for bash)
- **rsync**
- **ssh** (OpenSSH client)
- **awk, grep, sort, stat** (standard GNU utilities)
- **A working SSH keypair** for passwordless login to your phone

### On Your Android Phone
- **Termux** (free from F-Droid or Play Store)
- **OpenSSH** (for SSH server)
- **rsync** (installable via Termux)
- **Storage permission** for Termux (`termux-setup-storage`)
- **The script will fail if the phone goes to sleep. Use Termux-wake-lock.


## Configuration

1. Copy the example config:
   ```sh
   cp copy_config.example.conf copy_config.conf
   ```
2. Edit `copy_config.conf` with your own phone, SSH, and folder details.
3. Install Termux on your phone.
4. In termux run
   ```
   pkg update
   pkg install openssh
   pkg install rsync
   termux-setup-storage
   sshd
   whoami
   passwd
   ```
    to install the SSH server, which runs as a deamon (sshd). whoami shows your username it should be u0_592. Finally, you give a password for yourself
5. Test SSH. In WSL terminal write
~~~
ssh -p 8022 u0_592@the-ipnumber-of-your-phone
~~~
6. Create and copy the SSH key.  (if you already have one, you can use that instead)
~~~
ssh-keygen -t ed25519
ssh-copy-id -p u0_592@the-ipnumber-of-your-phone
~~~
7. The following script will create a .bashrc on your phone, so that you do not need to start termux-wake-lock and sshd everytime. Edit it (note same info as in the copy_config file.) Run it from WSL:
~~~
ssh -i /path/to/your/private_key -p 8022 your_termux_user@your_phone_ip 'cat > ~/.bashrc' <<'EOF'
# ~/.bashrc for Termux

case $- in
  *i*)
    termux-wake-lock
    pgrep -x sshd > /dev/null || sshd
    ;;
esac
EOF
~~~ 

## Workflow Overview

1. **Copy from Device to Computer**: Use `copy_from_device_to_comp.sh` to copy or move files from your phone (via SSH/Termux) to a local folder (e.g., `/mnt/i/FraMobil`).
2. **Import to Lightroom**: Import files from the local folder into Lightroom. Lightroom may rename or move files.
3. **Update Hash Database**: Run `update_imported_to_lightroom_hashes.sh` to incrementally hash all files in `/mnt/i/imported_to_lightroom`, maintaining a persistent hash file and a CSV (`imported_to_lightroom_hashes.csv`) with hash, path, and original filename (if available).
   - Both main scripts call this update script at the start, so the hash database is always up to date.
4. **Safe Deletion**: Use `delete_previously_copied_photos.sh` to safely delete files from your local folder only if their hash is present in the Lightroom hash CSV (i.e., they are safely imported).

## Hash Database and Deduplication

- The script `update_imported_to_lightroom_hashes.sh` is the single source of truth for what has been imported to Lightroom.
- It is incremental: only new or changed files are hashed, making it efficient for large collections.
- The CSV (`imported_to_lightroom_hashes.csv`) is used by both main scripts to prevent re-copying and to ensure safe deletion.

## Use
1. Start Termux on your phone. It automatically now runs the ssh deamon listeing for ssh connections.
2. Start a WSL terminal on your computer and run the copy_from_device_to_comp.sh (this will update the Lightroom hash database automatically).
3. Import files into Lightroom as usual.
4. Run delete_previously_copied_photos.sh to safely clean up your local folder (this will also update the hash database automatically).

# To get a list of all imported file paths, use:
# awk -F, 'NR>1 {gsub(/"/, "", $2); print $2}' imported_to_lightroom_hashes.csv
