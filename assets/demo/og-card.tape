# Source of truth for assets/og-card.png (the GitHub social-preview card).
# Regenerate with:
#   vhs assets/demo/og-card.tape
#   ffmpeg -y -i /tmp/og-card.gif -update 1 assets/og-card.png
# (VHS 0.11's Screenshot command no-ops here, so we grab the gif's final frame.)
# Then upload it once at: repo Settings -> General -> Social preview.

Output "/tmp/og-card.gif"

Set Shell "bash"
Set FontSize 30
Set Width 1280
Set Height 640
Set Padding 72
Set Theme "Catppuccin Mocha"

Hide
Type "export PS1=''"
Enter
Show
Type "bash assets/demo/og-card.sh"
Enter
Sleep 800ms
