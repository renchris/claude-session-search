#!/usr/bin/env bash
# Renders the text for the Open Graph social card (assets/og-card.png).
# Driven by og-card.tape via VHS. Kept deliberately sparse so it stays legible
# when GitHub/Slack/X shrink the card to a thumbnail.
GOLD='\033[1;38;2;212;175;55m'
GRAY='\033[0;38;2;180;182;196m'
GREEN='\033[1;38;2;34;197;94m'
WHITE='\033[1;38;2;235;236;240m'
DIM='\033[0;38;2;120;122;134m'
RESET='\033[0m'

printf '\033[3J\033[2J\033[H'   # clear screen + scrollback (drop the setup command line)
printf '\033[?25l'              # hide cursor
printf '\n\n'
printf "  ${GOLD}claude-session-search${RESET}\n\n"
printf "  ${GRAY}Search every Claude Code session in milliseconds —${RESET}\n"
printf "  ${GRAY}full-text, ranked, with an fzf picker to resume.${RESET}\n\n\n"
printf "  ${GREEN}\$${RESET} ${WHITE}claude-search${RESET} ${GOLD}\"rum latency\"${RESET}\n"
printf "  ${DIM}    3 results · 2ms · press Enter to resume${RESET}\n"
