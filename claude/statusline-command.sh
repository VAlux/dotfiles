#!/usr/bin/env bash
# Claude Code status line — inspired by Spaceship prompt style
# Receives JSON on stdin from Claude Code

input=$(cat)

# --- Directory ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
dir=$(basename "$cwd")

# --- Git branch ---
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)

# --- Model ---
model=$(echo "$input" | jq -r '.model.display_name // ""')

# --- Context usage ---
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# --- Rate limits (Claude.ai subscription) ---
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Build output — dir [branch] · model · ctx · rate limits
printf "\033[34m%s\033[0m" "$dir"

if [ -n "$branch" ]; then
  printf " \033[36m(%s)\033[0m" "$branch"
fi

if [ -n "$model" ]; then
  printf " \033[35m%s\033[0m" "$model"
fi

if [ -n "$used" ]; then
  printf " \033[33mctx:%.0f%%\033[0m" "$used"
fi

if [ -n "$five_pct" ]; then
  printf " \033[31m5h:%.0f%%\033[0m" "$five_pct"
fi

if [ -n "$week_pct" ]; then
  printf " \033[31m7d:%.0f%%\033[0m" "$week_pct"
fi

echo ""
