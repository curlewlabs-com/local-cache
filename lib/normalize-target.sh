#!/bin/sh
# The action's normalize step: write the target path's one canonical spelling
# to the step's outputs, so the per-target lock name is derived from it.
# INPUT_PATH arrives in the environment from action.yml.
set -eu
# shellcheck source=cache-common.sh
. "$GITHUB_ACTION_PATH/lib/cache-common.sh"
printf 'path=%s\n' "$(normalize_path "$INPUT_PATH")" >>"$GITHUB_OUTPUT"
