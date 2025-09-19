#!/bin/bash

# Set the directory you want to back up
LOCAL_DIR="../public_html/gocozyhomes/uploads/"
# Set the remote Box directory
REMOTE_DIR="box_backup:/backups/gocozyhomes/$(date +\%Y\%m\%d)"

# Create a new directory on Box with today's date
rclone mkdir $REMOTE_DIR

# Sync local directory with Box remote
rclone sync $LOCAL_DIR $REMOTE_DIR --delete-excluded --progress --log-file=rclone_backup_${date}.log

# Optionally, log the backup completion
echo "Backup completed at $(date)" >> rclone_backup_${date}.log

