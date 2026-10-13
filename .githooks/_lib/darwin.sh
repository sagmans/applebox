#!/bin/sh
# Shared platform guard for project hooks, sourced (not executed).
#
# AppleBox builds only with the macOS SDK (AppKit, Swift toolchain from
# Xcode), so its checks cannot run elsewhere. Skipping with a notice keeps
# commits possible on Linux bot machines while making the gap visible.
REQUIRED_OS='Darwin'
require_darwin() {
	if [ "$(uname -s)" != "$REQUIRED_OS" ]; then
		echo "$1: skipped, needs macOS (uname=$(uname -s))" >&2
		exit 0
	fi
}
