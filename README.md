# Deploy Agent - Student Attendance Tracker

`deploy_agent.sh` is a shell script that bootstraps, runs and archives the logs of the Student Attendance Tracker (`attendance_checker.py`). The Python application is never modified; everything here is shell scripting around it.

## Repository layout

```
deploy_agent_<GithubUsername>/
├── deploy_agent.sh
├── README.md
└── templates/
    ├── attendance_checker.py
    ├── assets.csv
    └── config.json
```

A deployed project looks like this:

```
attendance_tracker_<name>/
├── attendance_checker.py
├── Helpers/
│   ├── assets.csv
│   └── config.json
├── reports/              (empty until the app runs)
│   ├── attendance.log
│   └── absent.log
└── archives/             (created by Feature 3)
    ├── attendance/
    └── absent/
```

## Requirements

- Linux or macOS with `bash`
- `python3`
- `zip`

Deploy checks for `python3`, `zip` and the three template files, and stops with a clear message if anything is missing.

## How to run and select a feature

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh            # interactive menu
```

The menu offers:

| Option | Feature                  |
|--------|--------------------------|
| 1      | Deploy the application   |
| 2      | Run the application      |
| 3      | Archive the log files    |
| 4      | Exit                     |

You can also skip the menu with a command-line argument:

```bash
./deploy_agent.sh deploy
./deploy_agent.sh run
./deploy_agent.sh archive
```

The script always changes into its own directory first, so projects are created next to `deploy_agent.sh` and `templates/` is always found, wherever you launch it from.

## Feature 1: Deploy

1. **Pre-flight checks** for `python3`, `zip` and the template files.
2. **Project name:** you enter a name (letters, digits, `_` and `-` only) and the script creates `attendance_tracker_<name>/`. If it already exists you are asked whether to overwrite it; answering no aborts with an error and nothing is touched.
3. **Files:** `attendance_checker.py` and `config.json` are copied unmodified from `templates/`. The roster is built one of two ways:
   - **Option A (copy from template):** you choose how many students, and that many rows plus the header are copied from `templates/assets.csv`. These rows carry 4 prior sessions each.
   - **Option B (generate fresh):** you choose how many students (1-100), and the script builds the rows from built-in arrays of names and emails with `Attendance Count` and `Absence Count` at 0. If you ask for more students than the arrays hold, a number is added to the name and email to keep rows unique.
4. **Permissions:** `attendance_checker.py` gets `chmod +x` and `Helpers/config.json` gets `chmod 600` (owner read/write only, because it holds the grading thresholds). The script prints the resulting permissions.
5. **Threshold update (optional):** see below.
6. **Verification:** deployment ends by running the application (Feature 2). If it starts, the structure, roster and config work together.

### How `total_sessions` stays consistent with the roster

`total_sessions` in `config.json` must always be one more than the prior sessions recorded in the roster. If it is not, attendance percentages can go above 100% (for example 6 present out of `total_sessions: 5` is 120%).

The script handles this in two places:

- **At deploy time:** Option A keeps the template value of 5 (the sample rows have 4 prior sessions). Option B sets it to 1 with `sed` (fresh roster, first session).
- **Before every run:** `sync_sessions` reads `assets.csv`, finds the highest `Attendance Count + Absence Count`, and sets `total_sessions` to that value plus 1. This keeps the value correct when the app is run several times.

### How the threshold update works

After the permissions step, the script asks whether you want to update the alert thresholds.

- If you answer **yes**, it prompts for `warning` (default 75) and `failure` (default 50). Pressing Enter accepts the default.
- Values must be whole numbers from 0 to 100, and `failure` must be lower than `warning`. Invalid input is asked again.
- The file is then edited in place with `sed`, targeting only the `"warning": <number>` and `"failure": <number>` lines. The rest of the file is not reformatted or reordered, and `chmod 600` is re-applied afterwards.

Result in `config.json`:

```json
"thresholds": {
    "warning": 80,
    "failure": 60
},
```

## Feature 2: Run

Asks for the project name and runs:

```bash
cd attendance_tracker_<name>
python3 attendance_checker.py
```

The app is interactive: the instructor marks each student present or absent, the roster counts in `Helpers/assets.csv` are updated, and logs are written to `reports/`. Before launching, the script runs `sync_sessions` (described above). If the project does not exist, it prints an error and returns to the menu.

## Feature 3: Archive logs

Asks for the project name, then checks for `reports/attendance.log` and `reports/absent.log`. Each log that exists is **copied** into its own archive directory with a timestamp in the filename:

```
attendance_tracker_<name>/archives/
├── attendance/
│   └── attendance_20260927_143022.log
└── absent/
    └── absent_20260927_143022.log
```

- The timestamp format is `YYYYMMDD_HHMMSS`, so every archived copy is unique and traceable.
- The script prints each archived log and its final path.
- If a log does not exist (for example nobody was absent, so no `absent.log`), the script reports it and continues without crashing. If neither log exists, it tells you to run the application first.
- Archiving copies rather than moves, so the originals stay in `reports/`.

## Signal handling: Ctrl+C and Ctrl+Z

Both `SIGINT` (Ctrl+C) and `SIGTSTP` (Ctrl+Z) are trapped from the start of Feature 1 until deployment finishes. The traps are removed before the application launches, so they do not affect a live marking session.

When either signal arrives, the script:

1. prints a message that the deployment was interrupted,
2. zips whatever exists of `attendance_tracker_<name>/` into `attendance_tracker_<name>_archive.zip` using the `zip` command,
3. removes the incomplete project directory,
4. exits cleanly with status 130.

If the signal arrives before any directory has been created (for example at the project-name prompt), the script reports that there is nothing to archive and exits. If you decline to overwrite an existing project, that directory is never touched by the handler.

### How to test it

1. Run `./deploy_agent.sh deploy`.
2. Enter a project name such as `demo`.
3. At the roster prompt (Option A/B), press **Ctrl+C**. Repeat the test with **Ctrl+Z**.
4. Check the results:

```bash
ls attendance_tracker_demo_archive.zip     # the zip exists
unzip -l attendance_tracker_demo_archive.zip
ls attendance_tracker_demo 2>&1            # should say: No such file or directory
```

### What the zip contains

Whatever had been created when the interrupt happened. Interrupting at the roster prompt gives a zip with the directory skeleton, `attendance_checker.py` and `Helpers/config.json`, but no `assets.csv` yet:

```
attendance_tracker_demo/
attendance_tracker_demo/Helpers/
attendance_tracker_demo/Helpers/config.json
attendance_tracker_demo/reports/
attendance_tracker_demo/attendance_checker.py
```

## How the deployed structure was tested

After a normal deploy, check the structure, permissions and config:

```bash
ls -R attendance_tracker_demo                      # files and folders match the required layout
ls -l attendance_tracker_demo/attendance_checker.py   # executable bit set (-rwx...)
ls -l attendance_tracker_demo/Helpers/config.json     # -rw------- (600)
cat attendance_tracker_demo/Helpers/config.json       # thresholds and total_sessions
wc -l attendance_tracker_demo/Helpers/assets.csv      # header + the number of students chosen
```

Then verify the behavior:

- The verification run at the end of deploy starts successfully, which confirms structure, roster and config work together.
- After marking a session, `reports/attendance.log` (and `absent.log` if anyone was absent) exist.
- Run Feature 3 and confirm the timestamped files appear in `archives/attendance/` and `archives/absent/`.
- Run Feature 2 a second time and confirm `total_sessions` in `config.json` increased by one, so percentages stay at or below 100%.
- Re-run deploy with an existing project name and confirm the overwrite prompt appears, and that answering `n` aborts without changing anything.
- Run deploy on a machine without `zip` or `python3` (or temporarily rename it) and confirm it fails early with a clear message.
