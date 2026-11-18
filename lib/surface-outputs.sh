#!/bin/sh
# Copy the outputs local-mutex captured from a locked step (its output-file)
# into this step's GITHUB_OUTPUT, so they resolve across the composite action's
# boundary. OUTPUT_FILE arrives in the environment, never pasted into the
# script, so a path is never read as shell.
set -eu
cat "$OUTPUT_FILE" >>"$GITHUB_OUTPUT"
