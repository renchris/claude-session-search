# shellcheck shell=bash
# Validates and edits Claude Code's settings.json. install.sh and uninstall.sh both use it, so the
# lock binds them both. Bash 3.2. Sourcing it has no side effects.
#
# It sets no trap: progress-ui.sh owns EXIT, and replacing that trap is defect B16.3. So an interrupt
# during a patch can leave the lock directory behind; the timeout message names it and says how to
# clear it. Failures return 1 rather than exit, so the caller chooses how to report them.

# Attempts, at 0.1s plus a python3 start each: at least 30 seconds, because a loaded machine can take
# seconds per patch and a queue of them must not read as a stuck lock. Tests shorten it.
_CSS_SETTINGS_LOCK_TRIES="${__SESSION_SEARCH_LOCK_TRIES:-300}"
_CSS_SETTINGS_WRITE_ATTEMPTS=3 # Claude Code takes no lock, so it can write at any moment

# True when the file holds exactly one JSON object. `jq empty` alone passes an empty file, `{} {}`
# and a bare array, and each of those is what a bad filter writes or what the next filter breaks on.
_css_settings_is_one_object() {
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

# css_settings_validate FILE: returns 0, or prints "<path>: <why>" on stderr and returns 1, with jq's
# line and column for a parse error (R138, R303). It never writes.
css_settings_validate() {
    local file="$1" why
    if [ ! -f "$file" ]; then
        printf '%s: no such file\n' "$file" >&2
        return 1
    fi
    if ! why="$(jq empty "$file" 2>&1)"; then
        printf '%s: %s\n' "$file" "${why#jq: error (at *): }" >&2
        return 1
    fi
    if ! _css_settings_is_one_object "$file"; then
        printf '%s: expected one JSON object\n' "$file" >&2
        return 1
    fi
}

# One read-modify-write. Returns 0 written, 1 failed, 3 the file changed underneath, 4 nothing to do.
_css_settings_write() {
    local target="$1" filter="$2" backup="$3" tmp="$4" before after why
    if ! before="$(cksum <"$target")" || ! cp -p "$target" "$backup"; then
        printf '%s: could not back up the file\n' "$target" >&2
        return 1
    fi
    # cp -p first: mktemp creates 0600, and jq's redirect below keeps whatever mode tmp has.
    if ! cp -p "$target" "$tmp"; then
        printf '%s: could not write a temporary copy\n' "$target" >&2
        return 1
    fi
    # An explicit `if !`, never `jq ... && mv`: a failed left side of && does not trip errexit.
    if ! why="$(jq "$filter" "$target" 2>&1 >"$tmp")"; then
        printf '%s: edit failed, file not changed: %s\n' "$target" "${why#jq: error (at *): }" >&2
        return 1
    fi
    if ! _css_settings_is_one_object "$tmp"; then
        printf '%s: edit did not produce one JSON object, file not changed\n' "$target" >&2
        return 1
    fi
    if ! after="$(cksum <"$target")"; then
        printf '%s: could not read the file\n' "$target" >&2
        return 1
    fi
    if [ "$before" != "$after" ]; then
        return 3
    fi
    # Re-running an install must not add a backup per run for an edit that changes nothing.
    if cmp -s "$tmp" "$target"; then
        return 4
    fi
    if ! mv "$tmp" "$target"; then
        printf '%s: could not replace the file\n' "$target" >&2
        return 1
    fi
}

# Runs with the lock held. Called from an `if`, so errexit is off here and the lock always comes back.
_css_settings_patch_locked() {
    local target="$1" filter="$2" attempt=0 backup tmp rc
    while [ "$attempt" -lt "$_CSS_SETTINGS_WRITE_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        # Inside the loop: a concurrent writer may have just broken the file.
        if ! css_settings_validate "$target"; then
            return 1
        fi
        if ! backup="$(mktemp "$target.bak.XXXXXX")"; then
            printf '%s: could not create a backup file\n' "$target" >&2
            return 1
        fi
        if ! tmp="$(mktemp "$(dirname "$target")/.settings.json.XXXXXX")"; then
            printf '%s: could not create a temporary file\n' "$target" >&2
            rm -f "$backup"
            return 1
        fi
        if _css_settings_write "$target" "$filter" "$backup" "$tmp"; then
            # A unique name per run, so a later run cannot overwrite this good backup.
            CSS_SETTINGS_BACKUP="$backup"
            return 0
        else
            rc=$?
        fi
        rm -f "$tmp" "$backup"
        case "$rc" in
            3) sleep 0.1 ;;
            4) return 0 ;;
            *) return 1 ;;
        esac
    done
    printf '%s: kept changing while being edited, not written; close Claude Code and re-run\n' "$target" >&2
    return 1
}

# css_settings_patch FILE FILTER: applies a jq filter to FILE. Follows a symlink and keeps it, keeps
# the mode, and leaves no temporary file or lock on any return path. After a write,
# CSS_SETTINGS_BACKUP names the backup of the previous contents; otherwise it is empty.
css_settings_patch() {
    local file="$1" filter="$2" target lock tries=0
    # shellcheck disable=SC2034 # read by the calling script
    CSS_SETTINGS_BACKUP=""
    # python3 because BSD readlink has no -f. Without this, mv would replace a symlink with a file.
    if ! target="$(python3 -I -c 'import os, sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$file")"; then
        printf '%s: could not resolve the path\n' "$file" >&2
        return 1
    fi
    if [ ! -f "$target" ]; then
        printf '%s: no such file\n' "$file" >&2
        return 1
    fi
    # A directory because flock is absent on macOS. os.mkdir, not the mkdir command: uutils mkdir
    # (ubuntu-latest) exits 0 when it loses the race, so two holders would both proceed (measured).
    # Another holder's lock is never removed here.
    lock="$target.lock.d"
    until python3 -I -c 'import os, sys; os.mkdir(sys.argv[1])' "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge "$_CSS_SETTINGS_LOCK_TRIES" ]; then
            printf '%s: another install holds the lock; if none is running: rmdir %s\n' "$target" "$lock" >&2
            return 1
        fi
        sleep 0.1
    done
    if _css_settings_patch_locked "$target" "$filter"; then
        rmdir "$lock" || true
        return 0
    fi
    rmdir "$lock" || true
    return 1
}
