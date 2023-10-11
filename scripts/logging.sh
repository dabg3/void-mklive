#!/bin/bash

# TODO: solve duplication with same function in lib.sh
info_msg() {
    printf "\033[1m$@\n\033[m"
}

print_step() {
    CURRENT_STEP=$((CURRENT_STEP+1))
    info_msg "[${CURRENT_STEP}/${STEP_COUNT}] $@"
}

CURRENT_STEP=0
STEP_COUNT=10
[ "${#INCLUDE_DIRS[@]}" -gt 0 ] && STEP_COUNT=$((STEP_COUNT+1))

