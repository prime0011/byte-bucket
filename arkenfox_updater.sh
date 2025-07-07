#!/usr/bin/env bash

# Arkenfox Installer & Updater with Uninstall Support
# Usage:
#   arkenfox --install [--nogui] [--debug]
#   arkenfox --update [--debug]
#   arkenfox --uninstall [--debug]
# Optional:
#   --nogui : Skip Automator Quick Action setup
#   --debug : Enable debug mode output to terminal

# Exit on error, undefined variables, or failed pipes
set -euo pipefail

#########################
## Configuration
#########################

# Set directories for Arkenfox installation, logs, and user data
readonly ARKENFOX_DIR="$HOME/Library/Application Support/arkenfox"
readonly REPO_DIR="$ARKENFOX_DIR/user.js"
readonly LOG_DIR="$ARKENFOX_DIR/logs"
readonly AUTOMATOR_WORKFLOW="$HOME/Library/Services/Run Arkenfox Updater.workflow"
readonly PLIST_NAME="com.arkenfox.updater"
readonly LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
readonly GIT_MARKER="$ARKENFOX_DIR/.clt-installed"

# Files to back up (user.js, prefs.js)
readonly FILES_TO_BACKUP=("user.js" "prefs.js")

# Determine overrides file path (can be overridden via env var or CLI)
readonly USER_OVERRIDES="${OVERRIDES_FILE:-${ARKENFOX_OVERRIDES:-$ARKENFOX_DIR/user-overrides.js}}"

#########################
## Argument Parsing
#########################

# Initialize variables (no need for readonly here as they will change)
MODE=""
NO_GUI=0
DEBUG_MODE=0

# Pre-scan for --debug so debug() output works during argument parsing
for arg in "$@"; do
  [[ "$arg" == "--debug" ]] && DEBUG_MODE=1 && break
done

# Function to display help message
print_help() {
  cat <<EOF
Arkenfox Installer & Updater with Uninstall Support

Usage:
  arkenfox --install [--nogui] [--debug]   Install Arkenfox (with optional no GUI automator and debug)
  arkenfox --update [--debug]              Update Arkenfox configuration
  arkenfox --uninstall [--debug]           Uninstall Arkenfox completely
  arkenfox --help                          Show this help message

Options:
  --nogui     Skip installing Automator Quick Action (useful for headless setups)
  --debug     Enable debug output to terminal

Requirements:
  - Firefox installed with at least one profile launched once
  - Xcode Command Line Tools (will be installed if missing)
  - Git (included in CLT on macOS; if missing, install via Homebrew or https://git-scm.com/)

Notes:
  - Installer will attempt to install Command Line Tools if missing
  - User configs are backed up automatically
  - Automator Quick Action can be skipped with --nogui

EOF
}

# Debug function: Outputs debug messages if DEBUG_MODE is enabled
debug() {
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message"
  fi
}

# Output debug message about argument parsing
debug "🔍 [DEBUG] Parsing arguments..."

# Parse command-line arguments
for arg in "$@"; do
  debug "🔍 [DEBUG] Processing argument '$arg'..."
  case "$arg" in
    --install) MODE="install" ;;
    --update) MODE="update" ;;
    --uninstall) MODE="uninstall" ;;
    --nogui) NO_GUI=1 ;;
    --debug) DEBUG_MODE=1 ;;  # Already set by pre-scan, harmless
    --help|-h) print_help; exit 0 ;;  # Show help and exit
    *) echo "❌ [ERROR] Unknown argument: '$arg'."; print_help; exit 1 ;;  # Handle unknown args
  esac
done

# If no mode was specified, display an error and show help
if [[ -z "$MODE" ]]; then
  echo "❌ [ERROR] No mode specified."
  print_help
  exit 1
fi

# Output final debug state after parsing arguments
debug "🔍 [DEBUG] After argument parsing: MODE='$MODE', NO_GUI='$NO_GUI', DEBUG_MODE='$DEBUG_MODE'."
 #########################
## Utility Functions
#########################

# Log function to append log messages to a file and output to console
log() {
  local message="$1"

  # Append message to the log file with timestamp
  mkdir -p "$LOG_DIR"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_DIR/arkenfox.log"
}

# Rotate logs if they exceed 1MB in size
rotate_log() {
  debug "🔍 [DEBUG] Checking log rotation..."  

  local files_to_check=("$LOG_DIR/arkenfox.log" "$LOG_DIR/arkenfox-launchd.log")

  for log_file in "${files_to_check[@]}"; do
    if [[ ! -f "$log_file" ]]; then
      debug "🔍 [DEBUG] No $log_file file to rotate."  # No file found
      continue
    fi

    local file_size
    file_size=$(stat -f%z "$log_file")
    debug "🔍 [DEBUG] Log size for $log_file is $file_size bytes."  # File size info

    if (( file_size > 1048576 )); then
      mv "$log_file" "$log_file.$(date +%Y%m%d%H%M%S)"
      log "🔄 [ACTION] Rotated log: $log_file."  # Log the rotation action
      echo "🔄 [ACTION] Rotated log: $log_file."  # Output to console separately
    fi
  done
}

# Take a system snapshot for diagnostic purposes
system_snapshot() {
  local snapshot_label="$1"
  
  # Debug message about starting the snapshot
  debug "🔍 [DEBUG] Taking system snapshot: $snapshot_label"

  # Create snapshots directory
  mkdir -p "$LOG_DIR/snapshots" || { log "❌ [ERROR] Failed to create snapshots dir."; exit 1; }

  # Log the start of the snapshot process
  log "🔄 [ACTION] === $snapshot_label system snapshot at $(date) ==="

  # Save the system snapshot details
  {
    sw_vers
    echo "Disk Usage:"
    df -h /
    echo "Memory:"
    vm_stat || echo "vm_stat failed"
    echo "Processes:"
    ps aux | head -20
    echo
  } >> "$LOG_DIR/snapshots/$snapshot_label.txt" || { log "❌ [ERROR] Failed to write snapshot."; exit 1; }

  # Log the successful completion of the snapshot
  log "✅ [SUCCESS] System snapshot '$snapshot_label' completed and saved."
}

# Exit with an error message
error_exit() {
  local message="$1"  

  # Output the error message to stderr (console)
  echo "$message" >&2  

  # Log the error message to the log file
  log "$message"       

  exit 1
}

# Check if Xcode Command Line Tools are installed
check_clt() {
  debug "🔍 [DEBUG] Checking Xcode Command Line Tools..."

  if ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; then
    echo "🔄 [ACTION] Installing Xcode Command Line Tools..."
    debug "🔍 [DEBUG] Xcode Command Line Tools not found, installing..."

    set +e
    xcode-select --install 2>/dev/null || true
    set -e

    trap 'echo; error_exit "🚨 [CRITICAL] Installation interrupted by user"' SIGINT

    local tries=0
    local max_tries=20  # Default value if not provided via environment variable
    local wait_sec=15   # Default value if not provided via environment variable

    # Override with environment variables if they are set
    max_tries="${MAX_TRIES:-$max_tries}"
    wait_sec="${WAIT_SEC:-$wait_sec}"

    echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"

    while ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; do
      (( tries++ ))

      if (( tries >= max_tries )); then
        echo
        error_exit "❌ [ERROR] Timed out waiting for Xcode Command Line Tools installation. Please install manually and rerun."
      fi

      if (( tries == 4 )); then
        echo
        echo "⚠️ [WARNING] Reminder: If you see a popup asking to install Command Line Tools, please confirm it."
        echo "⚠️ [WARNING] Please confirm the Command Line Tools installer popup to continue installation."
        echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"
      fi

      echo -n ". (${tries}/${max_tries}, ~ $((tries * wait_sec))s elapsed)"
      sleep "$wait_sec"
    done

    # Final completion message
    echo "✅ [SUCCESS] Command Line Tools installation complete."

    sudo xcode-select --switch /Library/Developer/CommandLineTools

    touch "$GIT_MARKER"
    debug "🔍 [DEBUG] Xcode Command Line Tools installed successfully."
  else
    debug "🔍 [DEBUG] Xcode Command Line Tools already installed."
  fi

  # Reset the trap after installation
  trap - SIGINT
}

# Check if Git is installed
check_git() {
  debug "🔍 [DEBUG] Checking for git command..."
  if ! command -v git &>/dev/null; then
    error_exit "❌ [ERROR] Git is not installed. Please install Git via Homebrew (brew install git) or from https://git-scm.com"
  else
    debug "🔍 [DEBUG] Git found."
  fi
}

# Find the Firefox default profile directory
find_profile() {
  debug "🔍 [DEBUG] Searching for Firefox default-release profile..."
  local firefox_profile_dir
  firefox_profile_dir=$(find "$HOME/Library/Application Support/Firefox/Profiles" -type d -name "*.default-release" | head -n 1)
  echo "ℹ️ [INFO] Firefox profile directory: $firefox_profile_dir"
}

# Backup Firefox configuration files
backup_firefox_config() {
  local user_profile_dir="$1"
  debug "🔍 [DEBUG] Backing up Firefox configuration from $user_profile_dir."

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)

  local backup_directory="$LOG_DIR/backups/$timestamp"
  mkdir -p "$backup_directory"

  local backup_manifest_file="$backup_directory/manifest.txt"
  > "$backup_manifest_file"

  for file in "${FILES_TO_BACKUP[@]}"; do
    if [[ -f "$user_profile_dir/$file" ]]; then
      cp "$user_profile_dir/$file" "$backup_directory/"
      echo "✅ [SUCCESS] Successfully backed up $file from $user_profile_dir."
      log "✅ [SUCCESS] Successfully backed up $file from $user_profile_dir."
    else
      debug "🔍 [DEBUG] The file $file does not exist. Skipping backup."
    fi
  done

  echo "ℹ️ [INFO] Backup directory created: $backup_directory" > "$ARKENFOX_DIR/.last-backup"
}

# Restore Firefox backup if possible
restore_firefox_backup() {
  if pgrep -x "firefox" >/dev/null; then
    echo "⚠️ [WARNING] Firefox is currently running. Please close it before restoring the backup."
    exit 1
  fi

  # Determine the user profile directory
  local user_profile_dir
  user_profile_dir=$(find_profile)
  debug "🔍 [DEBUG] Restoring Firefox backup to profile $user_profile_dir."

  # Find the latest backup directory
  local backup_directory
  backup_directory=$(ls -td "$LOG_DIR/backups/"*/ 2>/dev/null | head -1 || true)

  if [[ -z "$backup_directory" ]]; then
    debug "🔍 [DEBUG] No backup directory found. Skipping restore."
    return
  fi

  local backup_manifest_file="$backup_directory/manifest.txt"

  if [[ ! -f "$backup_manifest_file" ]]; then
    debug "🔍 [DEBUG] No manifest file found in backup. Skipping restore."
    return
  fi

  # Iterate over the files listed in the manifest file
  while IFS= read -r file; do
    if [[ -f "$backup_directory/$file" ]]; then
      if [[ "$file" == "prefs.js" ]]; then
        echo "⚠️ [WARNING] prefs.js is about to be restored from backup."
        read -rp "📝 [COMMAND] Restore prefs.js from backup? [y/N]: " user_confirmation_restore
        user_confirmation_restore="${user_confirmation_restore,,}"  # lowercase
        if [[ "$user_confirmation_restore" != "y" && "$user_confirmation_restore" != "yes" ]]; then
          echo "ℹ️ [INFO] User declined to restore prefs.js. Skipping restoration."
          continue
        fi
      fi
      cp "$backup_directory/$file" "$user_profile_dir/$file"
      echo "✅ [SUCCESS] Restored $file from backup."
    else
      debug "🔍 [DEBUG] $file listed in manifest but not found in backup."
    fi
  done < "$backup_manifest_file"

  # Remove any files from the profile that weren't backed up
  for file in "${FILES_TO_BACKUP[@]}"; do
    if ! grep -qx "$file" "$backup_manifest_file" && [[ -f "$user_profile_dir/$file" ]]; then
      rm -f "$user_profile_dir/$file"
      echo "⚠️ [WARNING] Removed $file as it was not backed up."
    fi
  done
}

# Merge user.js and user-overrides.js, returning the merged file path
merge_userjs() {
  local user_profile_dir="$1"                   
  local user_profile_js_path="$user_profile_dir/user.js" 
  local merge_conflicts_file="$LOG_DIR/merge-conflicts.log" 
  local temp_merge_file                        
  temp_merge_file=$(mktemp)

  mkdir -p "$LOG_DIR"                          
  log "ℹ️ [INFO] Merging Arkenfox user.js with overrides..."

  # Clear any existing merge logs or conflict files
  rm -f "$LOG_DIR"/{overrides.txt,conflicts.txt,"$merge_conflicts_file"}

  # Extract preferences from the base user.js and sort them
  grep '^user_pref' "$REPO_DIR/user.js" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/base.txt"

  # If an overrides file exists, process it
  if [[ -f "$USER_OVERRIDES" ]]; then
    # Extract preferences from the user overrides and sort them
    grep '^user_pref' "$USER_OVERRIDES" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/overrides.txt"

    # Find common preferences between base and overrides (conflicts)
    comm -12 "$LOG_DIR/base.txt" "$LOG_DIR/overrides.txt" > "$LOG_DIR/conflicts.txt"

    # If conflicts exist, notify the user and log the conflicts
    if [[ -s "$LOG_DIR/conflicts.txt" ]]; then
      echo "⚠️ [WARNING] Conflict(s) detected in user-overrides.js. Please review the conflicts."
      cp "$LOG_DIR/conflicts.txt" "$merge_conflicts_file"
      log "⚠️ [WARNING] Overridden preferences written to $merge_conflicts_file."
    else
      log "ℹ️ [INFO] No conflicts detected between user.js and user-overrides.js."
    fi

    # Merge the base user.js and user-overrides.js into the temporary merge file
    cat "$REPO_DIR/user.js" "$USER_OVERRIDES" > "$temp_merge_file"
  else
    log "ℹ️ [INFO] No user-overrides.js found. Using base user.js only."
    cat "$REPO_DIR/user.js" > "$temp_merge_file"
  fi

  # Return the path to the merged file
  echo "$temp_merge_file"
}

# Show differences between current and merged user.js, asking for confirmation to apply changes
show_diff_and_confirm() {
  local profile_user_js_path="$1/user.js"  
  local merged_user_js_path="$2"              
  local user_confirmation  
  
  # Check if diff command is available
  if ! command -v diff >/dev/null 2>&1; then
    echo "⚠️ [WARNING] Diff command not found. Skipping diff display."
    return 0
  fi

  # If no profile.js, inform and exit
  if [[ ! -f "$profile_user_js_path" ]]; then
    echo "ℹ️ [INFO] No existing user.js found. This will be added."
    return 0
  fi

  # Check for differences between the profile and merged files
  if cmp -s "$profile_user_js_path" "$merged_user_js_path"; then
    debug "ℹ️ [INFO] No differences detected between current and merged user.js."
    return 0
  fi

  # Show the differences
  echo "ℹ️ [INFO] Showing differences between current and updated user.js:"
  echo "--------------------------------------------------"
  diff -u "$profile_user_js_path" "$merged_user_js_path" | less -R || true
  echo "--------------------------------------------------"
  echo

  # Ask user for confirmation
  read -rp "📝 [COMMAND] Apply these changes to user.js? [y/N]: " user_confirmation
  user_confirmation="${user_confirmation,,}"  # Convert to lowercase

  # Apply changes based on user confirmation
  if [[ "$user_confirmation" == "y" || "$user_confirmation" == "yes" ]]; then
    echo "ℹ️ [INFO] Changes applied to user.js."
    return 0
  else
    echo "ℹ️ [INFO] Changes not applied to user.js."
    return 1
  fi
}
 #########################
## Main Functions
#########################

# Creates the update.sh script to update Arkenfox through the launchd agent and Automator Quick Action workflow
create_updater_script() {
  echo "ℹ️ [INFO] Creating script for Arkenfox Updater..."
  debug "🔍 [DEBUG] The update.sh script is being created."

  mkdir -p "$ARKENFOX_DIR"

  # Define LOG_FILE path
  readonly local LOG_FILE="$HOME/Library/Application Support/arkenfox/logs/arkenfox-launchd.log"
  mkdir -p "$(dirname "$LOG_FILE")"  # Make sure log dir exists

  cat <<EOF > "$ARKENFOX_DIR/update.sh"
#!/usr/bin/env bash
set -euo pipefail

readonly LOG_FILE="$LOG_FILE"

# Notify function to send macOS notifications and log events
notify() {
  local msg="\$1"
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"\$msg\" with title \"Arkenfox Updater\""
  fi
  # Log the message with timestamp (no icon here as the icon is passed with the message)
  echo "\$(date '+%Y-%m-%d %H:%M:%S') \$msg" >> "\$LOG_FILE"
}

main() {
  # Define profile location
  PROFILE=\$(find "\$HOME/Library/Application Support/Firefox/Profiles" -type d -name "*.default-release" | head -n 1)

  # Error if profile isn't found
  if [[ -z "\$PROFILE" ]]; then
    notify "❌ Firefox profile not found. Update failed."
    exit 1
  fi

  OLD_USERJS="\$PROFILE/user.js"
  TMP_OLD_USERJS="\$PROFILE/user.js.old.\$(date +%s)"
  TMP_NEW_USERJS="\$PROFILE/user.js.new.\$(date +%s)"

  # Backup old user.js if exists
  if [[ -f "\$OLD_USERJS" ]]; then
    cp "\$OLD_USERJS" "\$TMP_OLD_USERJS" || { notify "❌ Failed to back up user.js. Update failed."; exit 1; }
  fi

  # Merge base and overrides into temp new user.js
  cat "$REPO_DIR/user.js" "$ARKENFOX_DIR/user-overrides.js" > "\$TMP_NEW_USERJS" || { notify "❌ Failed to merge user.js. Update failed."; exit 1; }

  # If old user.js exists, diff it with the new one
  if [[ -f "\$TMP_OLD_USERJS" ]]; then
    DIFF_OUTPUT=\$(diff -u "\$TMP_OLD_USERJS" "\$TMP_NEW_USERJS" || true)
  else
    DIFF_OUTPUT="No previous user.js found. New preferences applied."
  fi

  # Apply the new user.js
  mv "\$TMP_NEW_USERJS" "\$OLD_USERJS" || { notify "❌ Failed to apply new user.js. Update failed."; exit 1; }

  # Summarize changed prefs from diff: extract lines starting with +user_pref(...) but not ++++ or --- lines
  if [[ -f "\$TMP_OLD_USERJS" ]]; then
    CHANGED_PREFS=\$(echo "\$DIFF_OUTPUT" | grep '^+user_pref' | grep -v '^+++')
    COUNT=\$(echo "\$CHANGED_PREFS" | wc -l | tr -d ' ')
  else
    COUNT=0
  fi

  # Log the full diff output for record
  echo "=== Arkenfox update diff at \$(date) ===" >> "\$LOG_FILE"
  echo "\$DIFF_OUTPUT" >> "\$LOG_FILE"
  echo "==========================================" >> "\$LOG_FILE"

  # Decide on final notification based on the update branch
  if [[ "\$COUNT" -gt 0 ]]; then
    # If preferences are updated, show the summary and restart message
    DISPLAY_COUNT=3  # Limit the number of preferences displayed in the message
    if [[ "\$COUNT" -le \$DISPLAY_COUNT ]]; then
      # Display up to DISPLAY_COUNT preferences
      SUMMARY=\$(echo "\$CHANGED_PREFS" | sed -E 's/^\+user_pref\\("([^"]+)".*/\\1/' | paste -sd ', ' -)
      notify "✅ Arkenfox update applied. \$COUNT preferences updated: \$SUMMARY. 🔄 Please restart Firefox for the changes to take effect."
    else
      # Display first DISPLAY_COUNT preferences and show how many more
      SUMMARY=\$(echo "\$CHANGED_PREFS" | head -n \$DISPLAY_COUNT | sed -E 's/^\+user_pref\\("([^"]+)".*/\\1/' | paste -sd ', ' -)
      MORE_COUNT=\$((COUNT - DISPLAY_COUNT))
      notify "✅ Arkenfox update applied. \$COUNT preferences updated: \$SUMMARY… (+\$MORE_COUNT more). 🔄 Please restart Firefox for the changes to take effect."
    fi
  elif [[ "\$COUNT" -eq 0 && "\$DIFF_OUTPUT" == "No previous user.js found. New preferences applied." ]]; then
    # If no preferences changed, notify the user about the update
    notify "✅ Arkenfox update applied. No preferences changed."
  else
    # If no updates occurred at all (up-to-date)
    notify "ℹ️ Arkenfox is already up-to-date. No updates or preferences were applied."
  fi
}

main
EOF

  chmod +x "$ARKENFOX_DIR/update.sh"
  log "ℹ️ [INFO] update.sh created and made executable."

  # Notify user of successful creation of the update script
  echo "ℹ️ [INFO] The Arkenfox Updater script has been successfully created."
}

# Installs the launchd plist to schedule the agent to run the Arkenfox update.sh script
install_launchd() {
  debug "🔍 [DEBUG] Installing launchd plist..."

  # Ensure the directories for logs and launchd plist exist
  mkdir -p "$LOG_DIR"
  
  # Define the launchd plist file path
  readonly local LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
  
  # Provide user feedback about the launchd agent installation
  echo "🔄 [ACTION] Installing Arkenfox Updater agent..."

  # Create launchd plist file
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ARKENFOX_DIR/update.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

  # Unload any existing launchd plist (in case it was previously loaded) and then load the new one
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCHD_PLIST"

  # Provide terminal feedback about scheduling the update
  echo "ℹ️ [INFO] Arkenfox Updater agent has been scheduled to run daily."
}

# Installs Automator Quick Action workflow to run the Arkenfox update.sh script from macOS Services menu
install_automator() {
  if [[ "$NO_GUI" -eq 1 ]]; then
    debug "🔍 [DEBUG] Skipping Automator installation because --nogui is set."
    log "ℹ️ [INFO] Skipping Automator installation due to --nogui flag."
    return
  fi

  echo "🔄 [ACTION] Checking if Automator Quick Action is already installed..."

  # If workflow exists, ask user if they want to overwrite
  if [[ -d "$AUTOMATOR_WORKFLOW" ]]; then
    log "ℹ️ [INFO] Automator Quick Action already installed at $AUTOMATOR_WORKFLOW"
    debug "🔍 [DEBUG] Automator Quick Action already installed."

    # Prompt user to overwrite or skip (default to "no")
    read -rp "📝 [COMMAND] Automator Quick Action already exists. Do you want to overwrite it? (y/N): " confirm
    confirm="${confirm,,}"  # lowercase the response

    # Default to "no" if no input is provided (i.e., user presses Enter)
    if [[ -z "$confirm" || "$confirm" != "y" && "$confirm" != "yes" ]]; then
      log "ℹ️ [INFO] Skipping Automator install as per user request (or default)."
      debug "🔍 [DEBUG] User opted not to overwrite the existing workflow."
      echo "⚠️ [WARNING] Skipping Automator Quick Action installation."
      return
    fi

    # If user chooses to overwrite, remove old workflow
    debug "🔍 [DEBUG] User opted to overwrite existing Automator Quick Action. Removing old workflow..."
    rm -rf "$AUTOMATOR_WORKFLOW"
  fi

  echo "🔄 [ACTION] Installing Automator Quick Action for Arkenfox Updater..."

  # Ensure update.sh exists before creating Automator workflow
  if [[ ! -f "$ARKENFOX_DIR/update.sh" ]]; then
    error_exit "❌ [ERROR] Error: update.sh script not found at $ARKENFOX_DIR."
  fi

  # Create workflow folder
  mkdir -p "$AUTOMATOR_WORKFLOW"

  # Define script path
  local script_path
  script_path="$(printf "%s/update.sh" "$ARKENFOX_DIR")"

  # Create Info.plist for Automator workflow
  cat > "$AUTOMATOR_WORKFLOW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key>
  <string>839</string>
  <key>AMApplicationVersion</key>
  <string>2.10</string>
  <key>AMDocumentType</key>
  <string>AutomatorWorkflow</string>
  <key>AMWorkflowIdentifier</key>
  <string>Run Arkenfox Updater</string>
  <key>AMWorkflowVersion</key>
  <integer>2</integer>
  <key>NSPrincipalClass</key>
  <string>AMWorkflow</string>
  <key>AMActions</key>
  <array>
    <dict>
      <key>AMActionVersion</key>
      <string>2.6</string>
      <key>AMBundleIdentifier</key>
      <string>com.apple.actions.runShellScript</string>
      <key>AMParameters</key>
      <dict>
        <key>shell</key>
        <string>/usr/bin/env bash</string>
        <key>script</key>
        <string>$script_path</string>
      </dict>
      <key>AMActionName</key>
      <string>Run Shell Script</string>
    </dict>
  </array>
</dict>
</plist>
EOF

  log "✅ [SUCCESS] Automator Quick Action installed at $AUTOMATOR_WORKFLOW"
  debug "🔍 [DEBUG] Automator Quick Action installed (direct workflow files)."
  
  # Provide final feedback
  echo "✅ [SUCCESS] Automator Quick Action successfully installed."
  echo "ℹ️ [INFO] You can now manually run the Arkenfox Updater from the macOS Services menu."
}

# Installs Arkenfox, waits for Firefox to close, creates necessary files, and installs launch agents and Automator workflows
install() {
  local merge_wrote_changes="no"  # Initialize to avoid unbound variable error

  # Provide immediate feedback in the terminal
  echo "🔄 [ACTION] Starting installation..."

  # Wait for Firefox to close before proceeding
  while pgrep -x "firefox" >/dev/null; do
    echo "⚠️ [WARNING] Firefox is running. Please close it to continue the installation."
    sleep 5
  done

  # Provide feedback when Firefox is closed and installation is proceeding
  echo "ℹ️ [INFO] Firefox is now closed. Continuing with the installation..."

  debug "🔍 [DEBUG] Starting installation..."
  
  # Check for required tools (CLT, Git)
  check_clt
  check_git

  # Create necessary directories for Arkenfox installation and logs
  mkdir -p "$ARKENFOX_DIR"
  mkdir -p "$LOG_DIR"

  # Create the updater script
  create_updater_script

  # Find the Firefox profile directory
  local profile_dir
  profile_dir=$(find_profile)
  
  if [[ -z "$profile_dir" ]]; then
    error_exit "❌ [ERROR] Could not find Firefox default-release profile. Launch Firefox at least once before installing."
  fi

  # Backup the Firefox configuration files
  backup_firefox_config "$profile_dir"

  # Create empty user-overrides.js if it does not exist
  if [[ ! -f "$ARKENFOX_DIR/user-overrides.js" ]]; then
    echo "// User overrides here" > "$ARKENFOX_DIR/user-overrides.js"
    debug "🔍 [DEBUG] Created empty user-overrides.js."
  fi

  # Merge user.js and user-overrides.js
  local merged_file
  merged_file=$(merge_userjs "$profile_dir")
  
  # Show diff and ask for confirmation
  if show_diff_and_confirm "$profile_dir" "$merged_file"; then
    cp "$merged_file" "$profile_dir/user.js"
    log "ℹ️ [INFO] user.js updated in profile."
    merge_wrote_changes="yes"
  else
    merge_wrote_changes="no"
  fi

  # Clean up merged file after use
  rm -f "$merged_file"

  # Install Automator and launchd configurations
  install_automator
  install_launchd

  # Rotate logs for the installation
  rotate_log

  # Provide final feedback in the terminal
  echo "✅ [SUCCESS] Arkenfox installed successfully"
  debug "🔍 [DEBUG] Installation complete."
}

# Updates Arkenfox by pulling the latest repo changes, merging configs, and updating Firefox user.js
update() {
  local merge_wrote_changes="no"   # Initialize to avoid unbound variable error
  local base_changed="no"

  # Check if we are running in debug mode
  if [[ "$DEBUG_MODE" == "1" ]]; then
    debug "🔍 [DEBUG] Debug mode enabled."
  fi

  # Detect if we're running from an interactive terminal
  local in_terminal=false
  if [[ -t 1 ]]; then
    in_terminal=true
  fi

  echo "🔄 [ACTION] Starting update..."

  # Check dependencies
  check_clt
  check_git

  if [[ -d "$REPO_DIR/.git" ]]; then
    cd "$REPO_DIR" || error_exit "❌ [ERROR] Failed to cd into $REPO_DIR."

    # Capture current base user.js hash before Git pull
    local old_hash
    old_hash=$(shasum -a 256 user.js | awk '{print $1}')

    local git_output
    git_output=$(git pull 2>&1) || error_exit "❌ [ERROR] Git pull failed: $git_output"
    log "ℹ️ [INFO] Git pull output: $git_output"

    # Capture base user.js hash after Git pull
    local new_hash
    new_hash=$(shasum -a 256 user.js | awk '{print $1}')
    [[ "$old_hash" != "$new_hash" ]] && base_changed="yes"

    # Find Firefox profile directory
    local profile_dir
    profile_dir=$(find_profile)
    [[ -z "$profile_dir" ]] && error_exit "❌ [ERROR] Could not find Firefox profile."

    # Merge user.js with user-overrides.js for final config
    local merged_file
    merged_file=$(merge_userjs "$profile_dir")

    # Ensure merge user.js creation was successful
    if [[ -z "$merged_file" ]]; then
      error_exit "❌ [ERROR] Failed to merge user.js with overrides."
    fi

    # Compare merged config with current profile user.js
    if cmp -s "$merged_file" "$profile_dir/user.js"; then
      # No changes in profile user.js after merge
      if [[ "$base_changed" == "yes" ]]; then
        echo "✅ [SUCCESS] Downloaded latest Arkenfox user.js; Firefox profile user.js already up to date."
      else
        echo "ℹ️ [INFO] Arkenfox is already up to date. No repo or override changes."
      fi
    else
      # Merged config differs — update profile user.js
      cp "$merged_file" "$profile_dir/user.js"
      merge_wrote_changes="yes"

      # Log and notify about the updated preferences
      if [[ -n "$CHANGED_PREFS" ]]; then
        log "✅ [SUCCESS] Updated preferences: $CHANGED_PREFS"
        echo "✅ [SUCCESS] $COUNT prefs updated: $SUMMARY"
      fi

      if [[ "$base_changed" == "yes" ]]; then
        if pgrep -x "firefox" >/dev/null; then
          echo "✅ [SUCCESS] Downloaded latest Arkenfox user.js and applied updates to Firefox profile. Please restart Firefox for the changes to take effect."
        else
          echo "✅ [SUCCESS] Downloaded latest Arkenfox user.js and applied updates to Firefox profile."
        fi
      else
        if pgrep -x "firefox" >/dev/null; then
          echo "⚙️ [CONFIG] Applied new settings from user-overrides.js to Firefox profile. Please restart Firefox for the changes to take effect."
        else
          echo "⚙️ [CONFIG] Applied new settings from user-overrides.js to Firefox profile."
        fi
      fi
    fi

    rm -f "$merged_file"

  else
    error_exit "❌ [ERROR] Repository directory missing or corrupted: $REPO_DIR"
  fi

  rotate_log
  debug "🔍 [DEBUG] Update complete."
  echo "✅ [SUCCESS] Update complete."
  log "✅ [SUCCESS] Update complete."
}


# Uninstalls Arkenfox, restores Firefox prefs, removes backups, logs, and cleanup related files
uninstall() {
  # Wait for Firefox to close before proceeding
  while pgrep -x "firefox" >/dev/null; do
    echo "⚠️ [WARNING] Firefox is running. Please close it to continue uninstalling..."
    sleep 5
  done

  debug "🔍 [DEBUG] Starting uninstall process..."
  echo "🔄 [ACTION] Uninstalling Arkenfox..."

  # Restore Firefox prefs from backup if possible
  restore_firefox_backup

  # Find Firefox profile directory
  local profile_dir
  profile_dir=$(find_profile)

  if [[ -z "$profile_dir" ]]; then
    echo "⚠️ [WARNING] Could not find Firefox profile. Skipping prefs cleanup."
  else
    # Check if any backup exists
    local backup_dir
    backup_dir=$(ls -td "$LOG_DIR/backups/"*/ 2>/dev/null | head -1 || true)

    if [[ -z "$backup_dir" ]]; then
      echo "⚠️ [WARNING] No backup found. Deleting prefs.js and other related files..."

      for file in "${FILES_TO_BACKUP[@]}"; do
        if [[ -f "$profile_dir/$file" ]]; then
          if [[ "$file" == "prefs.js" ]]; then
            echo "⚠️ [WARNING] prefs.js exists but no backup was found."
            read -rp "📝 [COMMAND] Delete prefs.js anyway? [y/N]: " confirm_delete_prefs
            confirm_delete_prefs="${confirm_delete_prefs,,}"
            if [[ "$confirm_delete_prefs" != "y" && "$confirm_delete_prefs" != "yes" ]]; then
              echo "ℹ️ [INFO] Skipping prefs.js deletion."
              log "ℹ️ [INFO] User declined to delete prefs.js."  
              continue
            fi
          fi
          rm -f "$profile_dir/$file"
          echo "✅ [SUCCESS] Removed $file from $profile_dir as no backup existed."
          log "✅ [SUCCESS] Removed $file from $profile_dir as no backup existed."  
        fi
      done
    else
      echo "ℹ️ [INFO] Backup found. No need to remove any files."
      log "ℹ️ [INFO] Backup found, no action required." 
    fi
  fi

  # Unload and remove launchd plist
  debug "🔍 [DEBUG] Unloading launchd plist..."
  echo "🔄 [ACTION] Unloading and removing launchd plist..."
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  rm -f "$LAUNCHD_PLIST"
  log "✅ [SUCCESS] Unloaded and removed launchd plist." 

  # Remove Automator Quick Action workflow
  debug "🔍 [DEBUG] Removing Automator Quick Action workflow..."
  echo "🔄 [ACTION] Removing Automator Quick Action workflow..."
  rm -rf "$AUTOMATOR_WORKFLOW"
  log "✅ [SUCCESS] Removed Automator Quick Action workflow." 

  # Refresh LaunchServices to update Services menu
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r \
    -domain local \
    -domain system \
    -domain user \
    >/dev/null 2>&1 || true

  # Prompt user to delete backups and logs
  read -rp "📝 [COMMAND] Do you want to delete Arkenfox backups and logs? [y/N]: " confirm_delete
  confirm_delete="${confirm_delete,,}" # lowercase

  if [[ "$confirm_delete" == "y" || "$confirm_delete" == "yes" ]]; then
    echo "🔄 [ACTION] Deleting backups and logs..."
    rm -rf "$LOG_DIR/backups"
    rm -rf "$LOG_DIR/snapshots"
    log "ℹ️ [INFO] User chose to delete backups and logs."  
  else
    echo "ℹ️ [INFO] Keeping backups and logs."
    log "ℹ️ [INFO] User chose to keep backups and logs."  
  fi

  # Remove main Arkenfox directory last
  rm -rf "$ARKENFOX_DIR"
  log "✅ [SUCCESS] Removed Arkenfox directory."  

  # Remove Xcode CLT if installed by this script
  if [[ -f "$GIT_MARKER" ]]; then
    debug "🔍 [DEBUG] Removing Xcode Command Line Tools installed by script..."
    echo "🔄 [ACTION] Removing Xcode Command Line Tools..."
    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --reset
    rm "$GIT_MARKER"
    echo "✅ [SUCCESS] Xcode CLT removed (installed by script)."
    log "✅ [SUCCESS] Xcode CLT removed (installed by script)."
  else
    debug "🔍 [DEBUG] No Xcode CLT removal needed."
    echo "ℹ️ [INFO] No Xcode CLT removal needed."
    log "ℹ️ [INFO] No Xcode CLT removal needed." 
  fi

  echo "✅ [SUCCESS] Arkenfox has been successfully removed."
  log "✅ [SUCCESS] Arkenfox has been successfully removed."  
}

#########################
## Main Execution
#########################

case "$MODE" in
  install) install ;;
  update) update ;;
  uninstall) uninstall ;;
  *) echo "Unknown mode: $MODE"; exit 1 ;;
esac
