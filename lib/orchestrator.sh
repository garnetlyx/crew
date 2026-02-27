#!/bin/bash
# crew/lib/orchestrator.sh - Design-review orchestration engine
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/agent_runner.sh"

# Exit codes
EXIT_PASS=0
EXIT_MAX_ITER=1
EXIT_STALE=2

# Design-review loop
# Usage: cross_review_loop [max_iterations]
cross_review_loop() {
  local design_dir=".design"
  local config_file="$design_dir/design.yaml"
  
  # Get config values
  local max_iter
  max_iter=$(config_get ".max_iterations" "5" "$config_file")
  local stale_threshold
  stale_threshold=$(config_get ".termination.stale_threshold" "2" "$config_file")
  
  # Get generic agent fallback, then specific agents
  local base_agent
  base_agent=$(get_agent_type "$config_file")
  local writer_agent
  writer_agent=$(config_get ".writer_agent" "$base_agent" "$config_file")
  local reviewer_agent
  reviewer_agent=$(config_get ".reviewer_agent" "$base_agent" "$config_file")
  
  # Get prompt paths
  local writer_prompt
  writer_prompt=$(config_get ".prompts.plan_writer" "prompts/plan_writer.md" "$config_file")
  local reviewer_prompt
  reviewer_prompt=$(config_get ".prompts.reviewer" "prompts/reviewer.md" "$config_file")
  
  # Resolve prompt paths (check local .design first, then crew home)
  writer_prompt=$(resolve_prompt_path "$writer_prompt" "$design_dir")
  reviewer_prompt=$(resolve_prompt_path "$reviewer_prompt" "$design_dir")

  # Validate prompt files exist
  if [[ ! -f "$writer_prompt" ]]; then
    log_error "Plan writer prompt not found: $writer_prompt"
    log_info "Expected at: $design_dir/prompts/plan_writer.md or $(get_crew_home)/prompts/design-review/plan_writer.md"
    return 1
  fi
  if [[ ! -f "$reviewer_prompt" ]]; then
    log_error "Reviewer prompt not found: $reviewer_prompt"
    log_info "Expected at: $design_dir/prompts/reviewer.md or $(get_crew_home)/prompts/design-review/reviewer.md"
    return 1
  fi

  # State tracking
  local iter=0
  local stale_count=0
  local prev_plan_hash=""
  
  header "Design-Review Loop"
  log_info "Writer Agent: $writer_agent"
  log_info "Reviewer Agent: $reviewer_agent"
  log_info "Max iterations: $max_iter"
  log_info "Stale threshold: $stale_threshold"
  echo ""
  
  # Cleanup on interrupt
  trap 'log_info "Design session interrupted."; return 1' INT TERM

  # Ensure history directory exists if enabled
  local history_enabled
  history_enabled=$(config_get ".history.enabled" "true" "$config_file")
  if [[ "$history_enabled" == "true" ]]; then
    ensure_dir "$design_dir/history"
  else
    # Auto-clean history if it was just turned off
    if [[ -d "$design_dir/history" ]]; then
      rm -f "$design_dir/history/"*.md 2>/dev/null || true
    fi
  fi
  
  while [ "$iter" -lt "$max_iter" ]; do
    iter=$((iter + 1))
    separator "=" 50
    echo -e "${BOLD}Iteration $iter / $max_iter${NC}"
    separator "=" 50
    
    # ─────────────────────────────────────────────
    # Stage 1: Plan Writer
    # ─────────────────────────────────────────────
    log_info "Running Plan Writer..."
    
    local inject_args=()
    [[ -f "$design_dir/idea.txt" ]] && inject_args+=(--inject "$design_dir/idea.txt")
    [[ -f "$design_dir/plan.md" ]] && inject_args+=(--inject "$design_dir/plan.md")
    [[ -f "$design_dir/review.md" ]] && inject_args+=(--inject "$design_dir/review.md")
    
    if ! agent_runner "$writer_agent" "$writer_prompt" "${inject_args[@]}" --cwd "$PWD"; then
      log_error "Plan Writer failed"
      return 1
    fi
    
    # Ensure Plan Writer actually created the file
    if [[ ! -f "$design_dir/plan.md" ]]; then
      log_error "Plan Writer completed but $design_dir/plan.md was not created."
      log_info "The agent might have outputted the plan as text instead of saving it to a file."
      return 1
    fi
    
    # Check for stale (no substantive changes)
    local curr_hash
    curr_hash=$(file_hash "$design_dir/plan.md")
    
    if [[ "$curr_hash" == "$prev_plan_hash" ]]; then
      stale_count=$((stale_count + 1))
      log_warn "No changes detected (stale count: $stale_count/$stale_threshold)"
      
      if [[ "$stale_count" -ge "$stale_threshold" ]]; then
        log_warn "Plan stale for $stale_threshold iterations. Stopping."
        log_info "This may indicate the plan is as good as it can get, or Writer is stuck."
        return $EXIT_STALE
      fi
    else
      stale_count=0
      prev_plan_hash="$curr_hash"
    fi
    
    # Save to history if enabled
    if [[ "$history_enabled" == "true" ]]; then
      cp "$design_dir/plan.md" "$design_dir/history/plan_v${iter}.md"
      log_ok "Plan saved to history/plan_v${iter}.md"
    fi
    
    # ─────────────────────────────────────────────
    # Stage 2: Reviewer
    # ─────────────────────────────────────────────
    log_info "Running Reviewer..."
    
    if ! agent_runner "$reviewer_agent" "$reviewer_prompt" \
        --inject "$design_dir/plan.md" \
        --cwd "$PWD"; then
      log_error "Reviewer failed"
      return 1
    fi
    
    # Save review to history if enabled
    if [[ "$history_enabled" == "true" ]]; then
      cp "$design_dir/review.md" "$design_dir/history/review_v${iter}.md"
      log_ok "Review saved to history/review_v${iter}.md"
    fi
    
    # ─────────────────────────────────────────────
    # Check Decision
    # ─────────────────────────────────────────────
    local decision
    decision=$(parse_review_decision "$design_dir/review.md")
    
    if [[ "$decision" == "pass" ]]; then
      echo ""
      separator "=" 50
      log_ok "Review PASSED!"
      log_info "Final plan: $design_dir/plan.md"
      log_info "Total iterations: $iter"
      separator "=" 50
      return $EXIT_PASS
    fi
    
    log_warn "Review: needs revision. Continuing..."
    echo ""
  done
  
  log_error "Max iterations ($max_iter) reached without pass."
  log_info "The plan may need manual refinement or different approach."
  return $EXIT_MAX_ITER
}

# Parse review decision from review.md
parse_review_decision() {
  local review_file="$1"
  
  if [[ ! -f "$review_file" ]]; then
    echo "fail"
    return
  fi
  
  # Look for "PASS: true" or "**PASS**: true" pattern
  # Anchored to reject prefixed words like "NOT PASS" and trailing content
  if grep -qiE '^\*{0,2}PASS\*{0,2}\s*:\s*(true|yes)\s*$' "$review_file"; then
    echo "pass"
  else
    echo "fail"
  fi
}

# Resolve prompt path (local .design/prompts or crew home)
resolve_prompt_path() {
  local prompt_path="$1"
  local design_dir="$2"
  
  # Check local first
  if [[ -f "$design_dir/$prompt_path" ]]; then
    echo "$design_dir/$prompt_path"
    return
  fi
  
  # Check crew home
  local crew_home
  crew_home=$(get_crew_home)
  if [[ -f "$crew_home/$prompt_path" ]]; then
    echo "$crew_home/$prompt_path"
    return
  fi
  
  # Default prompts in crew home
  if [[ -f "$crew_home/prompts/design-review/$(basename "$prompt_path")" ]]; then
    echo "$crew_home/prompts/design-review/$(basename "$prompt_path")"
    return
  fi
  
  # Return as-is (will fail later if not found)
  echo "$prompt_path"
}

# Initialize design session
design_init() {
  local idea="$*"
  local design_dir=".design"

  if [[ -z "$idea" ]]; then
    log_error "Usage: design init <idea description or filename>"
    return 1
  fi

  # If argument is a file, read its content as the idea
  if [[ -f "$idea" ]]; then
    log_info "Reading idea from file: $idea"
    idea=$(cat "$idea")
  fi
  
  header "Initializing Design Session"
  
  # Create directory structure
  ensure_dir "$design_dir"
  ensure_dir "$design_dir/history"
  ensure_dir "$design_dir/prompts"
  
  # Save idea
  echo "$idea" > "$design_dir/idea.txt"
  log_ok "Saved idea to $design_dir/idea.txt"
  
  # Copy default config from templates
  local crew_home
  crew_home=$(get_crew_home)
  
  if [[ -f "$crew_home/templates/design.yaml.example" ]]; then
    # We still want to replace the project name
    sed "s/^project: .*/project: $(basename "$PWD")/" "$crew_home/templates/design.yaml.example" > "$design_dir/design.yaml"
    
    # Optional: If you want to replace writer_agent/reviewer_agent with system default agent_type, 
    # we can use sed for that too, or just leave the template default
    # sed -i '' "s/^writer_agent: .*/writer_agent: $agent_type/" "$design_dir/design.yaml"
    # sed -i '' "s/^reviewer_agent: .*/reviewer_agent: $agent_type/" "$design_dir/design.yaml"
  else
    log_error "Template not found: $crew_home/templates/design.yaml.example"
    return 1
  fi
  log_ok "Created $design_dir/design.yaml"
  
  # Copy default prompts if not customized
  local crew_home
  crew_home=$(get_crew_home)
  
  if [[ -f "$crew_home/prompts/design-review/plan_writer.md" ]]; then
    cp "$crew_home/prompts/design-review/plan_writer.md" "$design_dir/prompts/"
    log_ok "Copied default plan_writer.md"
  fi
  
  if [[ -f "$crew_home/prompts/design-review/reviewer.md" ]]; then
    cp "$crew_home/prompts/design-review/reviewer.md" "$design_dir/prompts/"
    log_ok "Copied default reviewer.md"
  fi
  
  echo ""
  log_info "Design session initialized!"
  log_info "Run 'design review' to start design-review loop"
}

# Show design status
design_status() {
  local design_dir=".design"
  
  if [[ ! -d "$design_dir" ]]; then
    log_error "No design session found. Run 'design init <idea>' first."
    return 1
  fi
  
  header "Design Session Status"
  
  # Process status
  local proc_status
  if pgrep -f "design review|cross_review_loop" >/dev/null; then
    proc_status="${GREEN}RUNNING${NC}"
  else
    proc_status="${YELLOW}IDLE${NC}"
  fi
  echo -e "Process: $proc_status"
  echo ""
  
  # Config
  if [[ -f "$design_dir/design.yaml" ]]; then
    local base_agent
    base_agent=$(config_get ".agent" "claude" "$design_dir/design.yaml")
    local writer_agent
    writer_agent=$(config_get ".writer_agent" "$base_agent" "$design_dir/design.yaml")
    local reviewer_agent
    reviewer_agent=$(config_get ".reviewer_agent" "$base_agent" "$design_dir/design.yaml")
    local max_iter
    max_iter=$(config_get ".max_iterations" "5" "$design_dir/design.yaml")
    
    if [[ "$writer_agent" == "$reviewer_agent" ]]; then
      echo "Agent: $writer_agent"
    else
      echo "Writer Agent: $writer_agent"
      echo "Reviewer Agent: $reviewer_agent"
    fi
    echo "Max iterations: $max_iter"
  fi
  
  echo ""
  
  # Files
  echo "Files:"
  [[ -f "$design_dir/idea.txt" ]] && echo "  ✓ idea.txt"
  [[ -f "$design_dir/plan.md" ]] && echo "  ✓ plan.md"
  [[ -f "$design_dir/review.md" ]] && echo "  ✓ review.md"
  
  # History
  local history_count
  history_count=$(ls "$design_dir/history/"*.md 2>/dev/null | wc -l)
  echo ""
  echo "History: $history_count files"
  
  # Last review decision
  if [[ -f "$design_dir/review.md" ]]; then
    local decision
    decision=$(parse_review_decision "$design_dir/review.md")
    echo ""
    if [[ "$decision" == "pass" ]]; then
      echo -e "Last review: ${GREEN}PASS${NC}"
    else
      echo -e "Last review: ${YELLOW}NEEDS REVISION${NC}"
    fi
  fi
}

# Reset design session
design_reset() {
  local design_dir=".design"
  
  if [[ ! -d "$design_dir" ]]; then
    log_error "No design session found."
    return 1
  fi
  
  if confirm "Reset design session? This will delete plan.md, review.md, and history/"; then
    rm -f "$design_dir/plan.md" "$design_dir/review.md"
    rm -rf "$design_dir/history"
    ensure_dir "$design_dir/history"
    log_ok "Design session reset. idea.txt preserved."
  fi
}
