#!/usr/bin/env bash
# =============================================================================
# deploy_agent.sh - Student Attendance Tracker bootstrapper
#
# Features:
#   1) deploy  - build attendance_tracker_{name}/ from templates/, configure it,
#                then verify by launching the app
#   2) run     - run attendance_checker.py on an already deployed project
#   3) archive - archive reports/*.log into timestamped files under archives/
#
# Usage:
#   ./deploy_agent.sh              -> interactive menu
#   ./deploy_agent.sh deploy       -> Feature 1
#   ./deploy_agent.sh run          -> Feature 2
#   ./deploy_agent.sh archive      -> Feature 3
#
# Signal handling: Ctrl+C (SIGINT) / Ctrl+Z (SIGTSTP) during deployment zips
# the partial project to attendance_tracker_{name}_archive.zip, removes the
# half-built directory and exits cleanly.
# =============================================================================

# Always work from the script's own directory so templates/ and projects
# resolve consistently no matter where the script is launched from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

TEMPLATES_DIR="templates"
PROJECT_DIR=""        # set only once we have decided to create a directory

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
err()   { echo "[ERROR] $*" >&2; }

# ask_yes_no "prompt" -> returns 0 for yes, 1 for no
ask_yes_no() {
    local answer
    while true; do
        read -r -p "$1 [y/n]: " answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# read_int "prompt" min max -> result stored in $REPLY_INT
read_int() {
    local prompt="$1" min="$2" max="$3" value
    while true; do
        read -r -p "$prompt" value
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            REPLY_INT="$value"
            return 0
        fi
        echo "Enter a whole number between $min and $max."
    done
}

# read_name -> asks for the project suffix, stores it in $NAME
read_name() {
    while true; do
        read -r -p "Enter project name (used as attendance_tracker_<name>): " NAME
        if [[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
            return 0
        fi
        echo "Use only letters, digits, '_' or '-' (no spaces, not empty)."
    done
}

# Portable in-place sed (works with GNU and BSD/macOS sed)
sed_inplace() {
    local expr="$1" file="$2"
    sed -i.bak -E "$expr" "$file" && rm -f "${file}.bak"
}

# ----------------------------------------------------------------------------
# Signal handling (active only during deployment)
# ----------------------------------------------------------------------------
handle_interrupt() {
    local sig="$1"
    trap '' INT TSTP        # ignore further signals while cleaning up
    echo
    echo "[!] Deployment interrupted by $sig."

    if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
        local zipfile="${PROJECT_DIR}_archive.zip"
        echo "[!] Archiving the incomplete project to $zipfile ..."
        if zip -rq "$zipfile" "$PROJECT_DIR"; then
            ok "Archive created: $SCRIPT_DIR/$zipfile"
        else
            err "Failed to create the archive."
        fi
        rm -rf "$PROJECT_DIR"
        info "Removed the incomplete directory $PROJECT_DIR."
    else
        info "Nothing had been created yet, so there is nothing to archive."
    fi

    echo "Session closed cleanly."
    exit 130
}

arm_traps()    {
    trap 'handle_interrupt SIGINT'  INT
    trap 'handle_interrupt SIGTSTP' TSTP
}
disarm_traps() { trap - INT TSTP; }

# ----------------------------------------------------------------------------
# Feature 1: deploy
# ----------------------------------------------------------------------------
preflight() {
    local missing=0
    for tool in python3 zip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            err "Required tool '$tool' is not installed."
            missing=1
        fi
    done
    for f in attendance_checker.py assets.csv config.json; do
        if [[ ! -f "$TEMPLATES_DIR/$f" ]]; then
            err "Missing template file: $TEMPLATES_DIR/$f"
            missing=1
        fi
    done
    if (( missing )); then
        err "Pre-flight checks failed. Fix the problems above and try again."
        exit 1
    fi
    ok "Pre-flight checks passed (python3, zip, templates found)."
}

# Option B: build a fresh roster of $1 students into file $2
generate_roster() {
    local count="$1" outfile="$2"
    local names=("Alice Johnson" "Bob Smith" "Carol Davis" "David Wilson" "Emma Brown"
                 "Frank Miller" "Grace Lee" "Henry Clark" "Ivy Walker" "Jack Turner"
                 "Karen Hall" "Liam Young" "Mia King" "Noah Scott" "Olivia Adams")
    local emails=("alice@example.com" "bob@example.com" "carol@example.com" "david@example.com"
                  "emma@example.com" "frank@example.com" "grace@example.com" "henry@example.com"
                  "ivy@example.com" "jack@example.com" "karen@example.com" "liam@example.com"
                  "mia@example.com" "noah@example.com" "olivia@example.com")
    local pool=${#names[@]} i idx round name email

    echo "Email,Names,Attendance Count,Absence Count" > "$outfile"
    for (( i = 0; i < count; i++ )); do
        idx=$(( i % pool ))
        round=$(( i / pool ))
        name="${names[$idx]}"
        email="${emails[$idx]}"
        if (( round > 0 )); then            # keep rows unique if count > pool
            name="$name $((round + 1))"
            email="${email%@*}$((round + 1))@${email#*@}"
        fi
        echo "${email},${name},0,0" >> "$outfile"
    done
}

update_thresholds() {
    local config="$1" warning failure

    while true; do
        read -r -p "New WARNING threshold [default 75]: " warning
        warning="${warning:-75}"
        read -r -p "New FAILURE threshold [default 50]: " failure
        failure="${failure:-50}"

        if [[ "$warning" =~ ^[0-9]+$ && "$failure" =~ ^[0-9]+$ ]] \
           && (( warning <= 100 && failure <= 100 && failure < warning )); then
            break
        fi
        echo "Both must be whole numbers 0-100, and failure must be lower than warning."
    done

    # Target only the "warning": N and "failure": N lines; nothing else changes.
    sed_inplace "s/(\"warning\":[[:space:]]*)[0-9]+/\1${warning}/" "$config"
    sed_inplace "s/(\"failure\":[[:space:]]*)[0-9]+/\1${failure}/" "$config"
    chmod 600 "$config"
    ok "Thresholds updated: warning=${warning}, failure=${failure}"
}

deploy() {
    echo "=== Feature 1: Deploy the application ==="
    preflight

    arm_traps                      # protect everything from here on

    read_name
    local target="attendance_tracker_${NAME}"

    if [[ -e "$target" ]]; then
        warn "Directory '$target' already exists."
        if ask_yes_no "Overwrite it (existing contents will be deleted)?"; then
            rm -rf "$target"
        else
            err "Aborted: refusing to overwrite '$target'."
            disarm_traps
            exit 1
        fi
    fi

    PROJECT_DIR="$target"          # from now on an interrupt will archive it

    info "Creating directory structure..."
    mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports" || {
        err "Could not create directories."; exit 1; }

    info "Copying application files..."
    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py"
    cp "$TEMPLATES_DIR/config.json"           "$PROJECT_DIR/Helpers/config.json"

    # ---- Roster ----------------------------------------------------------
    local roster="$PROJECT_DIR/Helpers/assets.csv"
    local available choice
    available=$(tail -n +2 "$TEMPLATES_DIR/assets.csv" | grep -c .)

    echo
    echo "How should the student roster be built?"
    echo "  A) Copy from template (up to $available sample students, 4 prior sessions each)"
    echo "  B) Generate a fresh roster (all counts start at 0)"
    while true; do
        read -r -p "Choose A or B: " choice
        case "$choice" in
            [Aa])
                read_int "How many students to copy (1-$available)? " 1 "$available"
                head -n $(( REPLY_INT + 1 )) "$TEMPLATES_DIR/assets.csv" > "$roster"
                # config.json stays unmodified: total_sessions is already 5
                ok "Copied $REPLY_INT student(s) from template (total_sessions stays 5)."
                break ;;
            [Bb])
                read_int "How many students to generate (1-100)? " 1 100
                generate_roster "$REPLY_INT" "$roster"
                # fresh roster = first session, so total_sessions must be 1
                sed_inplace 's/("total_sessions":[[:space:]]*)[0-9]+/\11/' \
                    "$PROJECT_DIR/Helpers/config.json"
                ok "Generated $REPLY_INT student(s) (total_sessions set to 1)."
                break ;;
            *) echo "Please enter A or B." ;;
        esac
    done

    # ---- Permissions -----------------------------------------------------
    chmod +x "$PROJECT_DIR/attendance_checker.py"
    chmod 600 "$PROJECT_DIR/Helpers/config.json"
    echo
    info "Permissions set:"
    ls -l "$PROJECT_DIR/attendance_checker.py" "$PROJECT_DIR/Helpers/config.json" \
        | awk '{print "        " $1 "  " $NF}'

    # ---- Threshold update ------------------------------------------------
    echo
    if ask_yes_no "Update the attendance alert thresholds in config.json?"; then
        update_thresholds "$PROJECT_DIR/Helpers/config.json"
    fi

    # Deployment finished: stop treating signals as "deploy interrupted".
    disarm_traps
    PROJECT_DIR=""

    echo
    ok "Deployment of '$target' complete."
    echo
    info "Verifying deployment by starting the application (Feature 2)..."
    run_app "$target"
}

# ----------------------------------------------------------------------------
# Feature 2: run
# ----------------------------------------------------------------------------
run_app() {
    local dir="$1"
    if [[ ! -d "$dir" || ! -f "$dir/attendance_checker.py" ]]; then
        err "'$dir' is not a deployed project (attendance_checker.py not found)."
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 is not installed."
        return 1
    fi
    # Subshell so the script's own working directory is not changed.
    ( cd "$dir" && python3 attendance_checker.py )
    local status=$?
    if (( status == 0 )); then
        ok "Application finished successfully."
    else
        warn "Application exited with status $status."
    fi
    return "$status"
}

run_feature() {
    echo "=== Feature 2: Run the application ==="
    read_name
    run_app "attendance_tracker_${NAME}"
}

# ----------------------------------------------------------------------------
# Feature 3: archive
# ----------------------------------------------------------------------------
archive_logs() {
    echo "=== Feature 3: Archive the log files ==="
    read_name
    local dir="attendance_tracker_${NAME}"

    if [[ ! -d "$dir" ]]; then
        err "Project '$dir' does not exist. Deploy it first."
        return 1
    fi

    local ts archived=0
    ts="$(date +%Y%m%d_%H%M%S)"

    # log name | destination sub-directory
    local logs=("attendance" "absent")
    local log src dest_dir dest
    for log in "${logs[@]}"; do
        src="$dir/reports/${log}.log"
        dest_dir="$dir/archives/${log}"
        dest="$dest_dir/${log}_${ts}.log"

        if [[ -f "$src" ]]; then
            mkdir -p "$dest_dir"
            if cp "$src" "$dest"; then
                ok "Archived ${log}.log -> $dest"
                archived=$(( archived + 1 ))
            else
                err "Failed to archive $src"
            fi
        else
            warn "reports/${log}.log not found - nothing to archive for '${log}'."
        fi
    done

    if (( archived == 0 )); then
        warn "No logs were archived. Run the application first (option 2)."
    else
        info "$archived log file(s) archived with timestamp $ts."
    fi
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
show_menu() {
    local choice
    while true; do
        echo
        echo "======== Attendance Tracker Deploy Agent ========"
        echo "  1) Deploy the application"
        echo "  2) Run the application"
        echo "  3) Archive the log files"
        echo "  4) Exit"
        read -r -p "Select an option [1-4]: " choice
        case "$choice" in
            1) deploy ;;
            2) run_feature ;;
            3) archive_logs ;;
            4) echo "Goodbye."; exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

case "${1:-}" in
    deploy)  deploy ;;
    run)     run_feature ;;
    archive) archive_logs ;;
    "")      show_menu ;;
    *)
        echo "Usage: $0 [deploy|run|archive]"
        exit 1 ;;
esac
