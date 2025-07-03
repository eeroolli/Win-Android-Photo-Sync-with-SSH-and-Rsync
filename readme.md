# Android Photo Sync Script

## Purpose

This repository provides an interactive Bash script to safely sync or move photos from an Android phone (via SSH) to a local folder on your computer.  
It is designed for workflows where the local folder is a temporary staging area (e.g., for importing into Lightroom), and includes robust options for filtering, logging, and safe deletion of files on the phone only after they have been imported.

## Features

- Interactive selection of photo subfolders (e.g., Camera, Screenshots, etc.)
- Filter files by date, since last copy, or all
- Option to copy or move files
- Optionally delete files from the phone only after they have been imported
- Configurable exclusions and logging
- Colorful, user-friendly prompts

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
   cp import_config.example.conf import_config.conf
   ```
2. Edit `import_config.conf` with your own phone, SSH, and folder details.
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
7. The following script will create a .bashrc on your phone, so that you do not need to start termux-wake-lock and sshd everytime. Edit it (note same info as in the import_config file.) Run it from WSL:
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

## Use
1. Start Termux on your phone. It automatically now runs the ssh deamon listeing for ssh connections.
2. Start a WSL terminal on your computer and run the import_from_device_to_comp.sh
