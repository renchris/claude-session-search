# Source of truth for assets/fzf-demo.gif — regenerate with: ./assets/demo/build.sh
# (build.sh sets up the synthetic HOME this tape depends on, then runs `vhs` on it.)

Output assets/fzf-demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1280
Set Height 560
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

# --- setup (hidden): point HOME at the synthetic index, clean prompt ---
Hide
Type "export HOME=/tmp/claude-search-demo-home"
Enter
Type 'export PATH="$HOME/.claude/bin:$PATH"'
Enter
Type 'export PS1="\$ "'
Enter
Type "clear"
Enter
Show

# --- demo: open the picker pre-filtered, browse previews, then live re-search ---
Type "claude-search --fzf migration"
Enter
Sleep 2s
Down
Sleep 1.3s
Down
Sleep 1.5s
Ctrl+U
Sleep 500ms
Type "rum latency"
Sleep 2s
Down
Sleep 2.2s
