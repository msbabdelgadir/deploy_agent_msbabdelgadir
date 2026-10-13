#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

TEMPLATES_DIR="templates"
PROJECT_DIR=""        


check_user_input() {
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

read_name() {
    while true; do
        read -r -p "Enter project name (used as attendance_tracker_<name>): " NAME
        if [[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
            return 0
        fi
        echo "Use only letters, digits, '_' or '-' (no spaces, not empty)."
    done
}


sed_inplace() {
    local expr="$1" file="$2"
    sed -i.bak -E "$expr" "$file" && rm -f "${file}.bak"
}

handle_interpted_signal() {
    local sig="$1"
    trap '' INT TSTP        
    echo
    echo "[!] Deployment interrupted by $sig."

    if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
        local zipfile="${PROJECT_DIR}_archive.zip"
        echo "[!] Archiving the incomplete project to $zipfile ..."
        if zip -rq "$zipfile" "$PROJECT_DIR"; then
            echo "Archive created: $SCRIPT_DIR/$zipfile"
        else
            echo "Error: Failed to create the archive." >&2
        fi
        rm -rf "$PROJECT_DIR"
        echo "Removed the incomplete directory $PROJECT_DIR."
    else
        echo "Nothing had been created yet, so there is nothing to archive."
    fi

    echo "Session closed cleanly."
    exit 130
}

arm_traps()    {
    trap 'handle_interpted_signal SIGINT'  INT
    trap 'handle_interpted_signal SIGTSTP' TSTP
}
disarm_traps() { trap - INT TSTP; }


sync_sessions() {
    local dir="$1"
    local roster="$dir/Helpers/assets.csv"
    local config="$dir/Helpers/config.json"
    local prior

    [[ -f "$roster" && -f "$config" ]] || return 0

    prior=$(awk -F',' 'NR>1 { t=$3+$4; if (t>m) m=t } END { print m+0 }' "$roster")
    sed_inplace "s/(\"total_sessions\":[[:space:]]*)[0-9]+/\1$((prior + 1))/" "$config"
    chmod 600 "$config"
    echo "total_sessions set to $((prior + 1)) (prior sessions recorded: $prior)"
}

preflight() {
    local missing=0
    for tool in python3 zip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: Required tool '$tool' is not installed." >&2
            missing=1
        fi
    done
    for f in attendance_checker.py assets.csv config.json; do
        if [[ ! -f "$TEMPLATES_DIR/$f" ]]; then
            echo "Error: Missing template file: $TEMPLATES_DIR/$f" >&2
            missing=1
        fi
    done
    if (( missing )); then
        echo "Error: Pre-flight checks failed. Fix the problems above and try again." >&2
        exit 1
    fi
    echo "Pre-flight checks passed (python3, zip, templates found)."
}


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
        if (( round > 0 )); then           
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


    sed_inplace "s/(\"warning\":[[:space:]]*)[0-9]+/\1${warning}/" "$config"
    sed_inplace "s/(\"failure\":[[:space:]]*)[0-9]+/\1${failure}/" "$config"
    chmod 600 "$config"
    echo "Thresholds updated: warning=${warning}, failure=${failure}"
}

deploy() {
    echo "=== Feature 1: Deploy the application ==="
    preflight

    arm_traps                     

    read_name
    local target="attendance_tracker_${NAME}"

    if [[ -e "$target" ]]; then
        echo "Directory '$target' already exists."
        if check_user_input "Overwrite it (existing contents will be deleted)?"; then
            rm -rf "$target"
        else
            echo "Error: Aborted: refusing to overwrite '$target'." >&2
            disarm_traps
            exit 1
        fi
    fi

    PROJECT_DIR="$target"         

    echo "Creating directory structure..."
    mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports" || {
        echo "Error: Could not create directories." >&2; exit 1; }

    echo "Copying application files..."
    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py"
    cp "$TEMPLATES_DIR/config.json"           "$PROJECT_DIR/Helpers/config.json"

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

                echo "Copied $REPLY_INT student(s) from template (total_sessions stays 5)."
                break ;;
            [Bb])
                read_int "How many students to generate (1-100)? " 1 100
                generate_roster "$REPLY_INT" "$roster"
                # fresh roster = first session, so total_sessions must be 1
                sed_inplace 's/("total_sessions":[[:space:]]*)[0-9]+/\11/' \
                    "$PROJECT_DIR/Helpers/config.json"
                echo "Generated $REPLY_INT student(s) (total_sessions set to 1)."
                break ;;
            *) echo "Please enter A or B." ;;
        esac
    done

    
    chmod +x "$PROJECT_DIR/attendance_checker.py"
    chmod 600 "$PROJECT_DIR/Helpers/config.json"
    echo
    echo "Permissions set:"
    ls -l "$PROJECT_DIR/attendance_checker.py" "$PROJECT_DIR/Helpers/config.json" \
        | awk '{print "        " $1 "  " $NF}'

    echo
    if check_user_input "Update the attendance alert thresholds in config.json?"; then
        update_thresholds "$PROJECT_DIR/Helpers/config.json"
    fi

    disarm_traps
    PROJECT_DIR=""

    echo
    echo "Deployment of '$target' complete."
    echo
    echo "Verifying deployment by starting the application (Feature 2)..."
    run_app "$target"
}


run_app() {
    local dir="$1"
    if [[ ! -d "$dir" || ! -f "$dir/attendance_checker.py" ]]; then
        echo "Error: '$dir' is not a deployed project (attendance_checker.py not found)." >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is not installed." >&2
        return 1
    fi
    sync_sessions "$dir"
    ( cd "$dir" && python3 attendance_checker.py )
    local status=$?
    if (( status == 0 )); then
        echo "Application finished successfully."
    else
        echo "Application exited with status $status."
    fi
    return "$status"
}

run_feature() {
    echo "=== Feature 2: Run the application ==="
    read_name
    run_app "attendance_tracker_${NAME}"
}

archive_logs() {
    echo "=== Feature 3: Archive the log files ==="
    read_name
    local dir="attendance_tracker_${NAME}"

    if [[ ! -d "$dir" ]]; then
        echo "Error: Project '$dir' does not exist. Deploy it first." >&2
        return 1
    fi

    local ts archived=0
    ts="$(date +%Y%m%d_%H%M%S)"

    local logs=("attendance" "absent")
    local log src dest_dir dest
    for log in "${logs[@]}"; do
        src="$dir/reports/${log}.log"
        dest_dir="$dir/archives/${log}"
        dest="$dest_dir/${log}_${ts}.log"

        if [[ -f "$src" ]]; then
            mkdir -p "$dest_dir"
            if cp "$src" "$dest"; then
                echo "Archived ${log}.log -> $dest"
                archived=$(( archived + 1 ))
            else
                echo "Error: Failed to archive $src" >&2
            fi
        else
            echo "reports/${log}.log not found - nothing to archive for '${log}'."
        fi
    done

    if (( archived == 0 )); then
        echo "No logs were archived. Run the application first (option 2)."
    else
        echo "$archived log file(s) archived with timestamp $ts."
    fi
}

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
