#!/usr/bin/env bash
# exec-wrapper.sh
# Wrapper inside the agy container. Responsibilities:
#   1) Receive `agy auth-wait` (or compatible) command
#   2) Map the historical `agy auth-wait` wrapper command to agy's current
#      non-interactive print mode, which prints the OAuth URL when no
#      credential is present.
#   3) Run agy under expect with TERM=dumb so the auth prompt stays
#      line-oriented, while a pseudo-terminal remains available for the auth
#      code prompt.
#   4) Forward the authorization code from $AGY_LOGIN_CODE_FIFO into agy.
#   5) Pipe stdout/stderr through unchanged so the host can scrape the URL.
#
# Environment:
#   AGY_LOGIN_PROMPT          - sentinel prompt used by some agy builds
#   AGY_LOGIN_PRINT_TIMEOUT   - timeout passed to agy in print mode
#   AGY_LOGIN_CODE_FIFO       - FIFO inside container for code injection
#   AGY_LOGIN_CODE_FILE       - non-blocking code handoff file; preferred

set -u

export PATH="/root/.local/bin:${PATH}"

CMD="${1:-agy}"
shift || true

RESOLVED_CMD="$(command -v "${CMD}" 2>/dev/null || true)"
if [[ -z "${RESOLVED_CMD}" ]]; then
  # Binary không tồn tại trong image (thường do build agy hỏng nhưng vẫn tạo
  # image — xem services/agy-dev/Dockerfile). Thay vì exec một path không tồn
  # tại (đẩy lỗi mơ hồ "no such file" cho host), in ra một sentinel rõ ràng để
  # backend nhận diện và báo lỗi đúng nguyên nhân cho người dùng.
  echo "__AGY_BINARY_MISSING__ command not found in container: ${CMD}" >&2
  echo "__AGY_BINARY_MISSING__ PATH=${PATH}" >&2
  exit 127
fi

# `auth-wait` was the old wrapper-facing command. The current agy CLI does not
# expose it as a real subcommand; print mode is the stable way to trigger auth
# and emit the OAuth URL.
if [[ "${CMD}" == "agy" && "${1:-}" == "auth-wait" ]]; then
  shift || true
  set -- \
    "--print-timeout" "${AGY_LOGIN_PRINT_TIMEOUT:-5s}" \
    "--print" "${AGY_LOGIN_PROMPT:-__antigravity_auth_check__}" \
    "$@"
fi

# Ensure FIFO exists (best-effort; the host also creates it)
if [[ -n "${AGY_LOGIN_CODE_FIFO:-}" && ! -p "${AGY_LOGIN_CODE_FIFO}" ]]; then
  mkfifo "${AGY_LOGIN_CODE_FIFO}" 2>/dev/null || true
fi

if command -v expect >/dev/null 2>&1; then
  exec expect -f - -- "${RESOLVED_CMD}" "$@" <<'EXPECT'
set timeout -1
log_user 1

set cmd [lindex $argv 0]
set args [lrange $argv 1 end]

set fifo ""
if {[info exists env(AGY_LOGIN_CODE_FIFO)]} {
  set fifo $env(AGY_LOGIN_CODE_FIFO)
}
set code_file ""
if {[info exists env(AGY_LOGIN_CODE_FILE)]} {
  set code_file $env(AGY_LOGIN_CODE_FILE)
}

if {$fifo ne ""} {
  catch {exec sh -lc "test -p '$fifo' || { rm -f '$fifo'; mkfifo '$fifo'; }"}
  set code_pipe [open $fifo {RDWR NONBLOCK}]
  fconfigure $code_pipe -blocking 0 -buffering line -translation lf

  proc forward_code {} {
    global code_pipe
    set line ""
    set n [gets $code_pipe line]
    if {$n >= 0 && [string length $line] > 0} {
      send -- "$line\r"
    }
  }

  fileevent $code_pipe readable forward_code
}

proc poll_code_file {} {
  global code_file
  if {$code_file ne "" && [file exists $code_file]} {
    set fp [open $code_file r]
    set code [string trim [read $fp]]
    close $fp
    file delete -force -- $code_file
    if {[string length $code] > 0} {
      send -- "$code\r"
    }
  }
  after 250 poll_code_file
}

spawn -noecho env TERM=dumb $cmd {*}$args
poll_code_file
expect eof
EXPECT
fi

# Fallback for images built without expect. This can print the URL, but cannot
# keep the process alive for later FIFO input on current agy releases.
exec "${RESOLVED_CMD}" "$@"
