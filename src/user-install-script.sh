#!/bin/bash

# if a password was set by EmuSync, this will run when the program closes
temp_pass_cleanup() {
  echo $PASS | sudo -S -k passwd -d deck
}

# removes unhelpful GTK warnings
zen_nospam() {
  zenity 2> >(grep -v 'Gtk' >&2) "$@"
}

# check if JQ is installed
if ! command -v jq &> /dev/null
then
    echo "JQ could not be found, please install it"
    echo "Info on how to install it can be found at https://stedolan.github.io/jq/download/"
    exit 1
fi

# check if github.com is reachable
if ! curl -Is https://github.com | head -1 | grep 200 > /dev/null
then
    echo "Github appears to be unreachable, you may not be connected to the internet"
    exit 1
fi

# if the script is not root yet, get the password and rerun as root
if (( $EUID != 0 )); then
    PASS_STATUS=$(passwd -S deck 2> /dev/null)
    if [ "$PASS_STATUS" = "" ]; then
        echo "Deck user not found. Continuing anyway, as it probably just means user is on a non-steamos system."
    fi

    if [ "${PASS_STATUS:5:2}" = "NP" ]; then # if no password is set
        if ( zen_nospam --title="EmuSync Installer" --width=300 --height=200 --question --text="You appear to have not set an admin password.\nEmuSync can still install by temporarily setting your password to 'EmuSync!' and continuing, then removing it when the installer finishes\nAre you okay with that?" ); then
            yes "EmuSync!" | passwd deck # set password to EmuSync!
            trap temp_pass_cleanup EXIT # make sure that password is removed when application closes
            PASS="EmuSync!"
        else exit 1; fi
    else
        # get password
        FINISHED="false"
        while [ "$FINISHED" != "true" ]; do
            PASS=$(zen_nospam --title="EmuSync Installer" --width=300 --height=100 --entry --hide-text --text="Enter your sudo/admin password")
            if [[ $? -eq 1 ]] || [[ $? -eq 5 ]]; then
                exit 1
            fi
            if ( echo "$PASS" | sudo -S -k true ); then
                FINISHED="true"
            else
                zen_nospam --title="EmuSync Installer" --width=150 --height=40 --info --text "Incorrect Password"
            fi
        done
    fi

    if ! [ $USER = "deck" ]; then
        zen_nospam --title="EmuSync Installer" --width=300 --height=100 --warning --text "You appear to not be on a deck.\nEmuSync should still mostly work, but you may not get full functionality."
    fi
    
    echo "$PASS" | sudo -E -S -k bash "$0" "$@" # rerun script as root
    exit 1
fi

# all code below should be run as root
USER_DIR="$(getent passwd $SUDO_USER | cut -d: -f6)"
EMUSYNC_FOLDER="${USER_DIR}/EmuSync"
DESKTOP_FILE="/home/$SUDO_USER/Desktop/EmuSync.desktop"

# if EmuSync is already installed, then add 'uninstall' and 'wipe' option
if [[ -f "${EMUSYNC_FOLDER}/EmuSync.AppImage" ]] ; then
    OPTION=$(zen_nospam --title="EmuSync Installer" --width=750 --height=400 --list --radiolist --text "Select an option:" --hide-header --column "Buttons" --column "Choice" --column "Info" \
    TRUE "(update)" "Update EmuSync" \
    FALSE "(uninstall)" "Uninstall EmuSync, but keep config" \
    FALSE "(wipe)" "Uninstall EmuSync and delete config")
else
    OPTION=$(zen_nospam --title="EmuSync Installer" --width=750 --height=300 --list --radiolist --text "Select an option:" --hide-header --column "Buttons" --column "Choice" --column "Info" \
    TRUE "(install)" "Install EmuSync")
fi

if [[ $? -eq 1 ]] || [[ $? -eq 5 ]]; then
    exit 1
fi

SERVICE_NAME="emusync.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

# uninstall if uninstall option was selected
if [[ "$OPTION" == "(uninstall)" || "$OPTION" == "(wipe)"|| "$OPTION" == "(update)" ]] ; then
    (

    # Step 1: Stop service if running
    sudo systemctl stop $SERVICE_NAME 2>/dev/null

    # Step 2: Disable service
    sudo systemctl disable $SERVICE_NAME 2>/dev/null

    # Step 3: Remove service file
    if [ -f "$SERVICE_PATH" ]; then
        sudo rm "$SERVICE_PATH"
        echo "Removed $SERVICE_PATH"
    else
        echo "Service file not found at $SERVICE_PATH"
    fi

    # Step 4: Reload systemd
    sudo systemctl daemon-reload

    # Step 5: Clean logs
    sudo journalctl --vacuum-time=1s >/dev/null 2>&1

    rm -rf "${EMUSYNC_FOLDER}"

    if [ "$OPTION" == "wipe EmuSync" ]; then    
        rm -rf "${USER_DIR}/.emusync-data"
    fi

    if [[ "$OPTION" != "(update)" ]]; then

        if [ -f "$DESKTOP_FILE" ]; then
            sudo -u $SUDO_USER rm "$DESKTOP_FILE"
        fi

        echo "100" ; echo "# Uninstall finished, installer can now be closed";
    else
        echo "100" ; echo "# Uninstall complete, please continue to install the update";
    fi
        
    
    ) |
    zen_nospam --progress \
  --title="EmuSync Installer" \
  --width=300 --height=100 \
  --text="Uninstalling..." \
  --percentage=0 \
  --no-cancel
  
      # uninstall + wipe exit, update continues
    if [[ "$OPTION" != "(update)" ]]; then
        exit 0
    fi

fi

# otherwise, install EmuSync
(
echo "20" ; echo "# Creating file structure" ;
rm -rf "${EMUSYNC_FOLDER}"
sudo -u $SUDO_USER  mkdir -p "${EMUSYNC_FOLDER}"

echo "40" ; echo "# Finding latest release";
RELEASE=$(curl -s 'https://api.github.com/repos/emu-sync/EmuSync/releases' | jq -r "first(.[] | select(.prerelease == "false"))")
VERSION=$(jq -r '.tag_name' <<< ${RELEASE} )
DOWNLOADURL=$(jq -r '.assets[].browser_download_url | select(endswith("EmuSync-Linux-x64.zip"))' <<< ${RELEASE})
ZIP_PATH="${EMUSYNC_FOLDER}/EmuSync-Linux-x64.zip"

echo "60" ; echo "# Installing version $VERSION" ;
# make another zenity prompt while downloading the PluginLoader file, I do not know how this works
curl -L $DOWNLOADURL -o ${ZIP_PATH} 2>&1 | stdbuf -oL tr '\r' '\n' | sed -u 's/^ *\([0-9][0-9]*\).*\( [0-9].*$\)/\1\n#Download Speed\:\2/' | zen_nospam --progress --title "Downloading EmuSync" --text="Download Speed: 0" --width=300 --height=100 --auto-close --no-cancel
unzip -o "$ZIP_PATH" -d "$EMUSYNC_FOLDER"
rm "$ZIP_PATH"

echo "80" ; echo "# Setting up systemd" ;
# Step 2: Create systemd service
cat <<EOF | sudo tee $SERVICE_PATH > /dev/null
[Unit]
Description=EmuSync Agent
After=network.target

[Service]
User=${SUDO_USER}
Group=${SUDO_USER}
Restart=always
ExecStart=${EMUSYNC_FOLDER}/agent/EmuSync.Agent
WorkingDirectory=${EMUSYNC_FOLDER}
Environment=HOME=${USER_DIR}
Environment=UNPRIVILEGED_PATH=${EMUSYNC_FOLDER}
Environment=PRIVILEGED_PATH=${EMUSYNC_FOLDER}
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Step 3: Reload and enable/start the service
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl start $SERVICE_NAME

# this (retroactively) fixes a bug where users who ran the installer would have emusync folder owned by root instead of their user
# will likely be removed at some point in the future
if [ "$SUDO_USER" =  "deck" ]; then
  sudo chown -R deck:deck "${EMUSYNC_FOLDER}"
fi

if [ ! -f "$DESKTOP_FILE" ]; then
    sudo -u $SUDO_USER bash -c "cat > \"$DESKTOP_FILE\" <<EOF
[Desktop Entry]
Type=Application
Name=EmuSync
Comment=Launch EmuSync
Exec=\"${EMUSYNC_FOLDER}/EmuSync.AppImage\"
Icon=${EMUSYNC_FOLDER}/emu-sync-icon.png
Terminal=false
Categories=Game;
EOF"

    chmod +x "$DESKTOP_FILE"
    update-desktop-database ~/.local/share/applications 2>/dev/null || true
fi

echo "100" ; echo "# Install finished, installer can now be closed";
) |
zen_nospam --progress \
  --title="EmuSync Installer" \
  --width=300 --height=100 \
  --text="Installing..." \
  --percentage=0 \
  --no-cancel # not actually sure how to make the cancel work properly, so it's just not there unless someone else can figure it out

if [ "$?" = -1 ] ; then
        zen_nospam --title="EmuSync Installer" --width=150 --height=70 --error --text="Download interrupted."
fi
