#!/bin/sh
# Remakes the pictures a group made from a preset starts with
# (`PotokIde.Social.GroupPresets.picture/1`): the preset's icon from the
# Create sub-group menu (`CreateMenu.presets/0`), white on Potok's blue, the
# light theme's primary. Needs ImageMagick. Run it from this folder after
# changing an icon or the colour; groups keep the picture they were made with.
set -e

icons=../../deps/heroicons/optimized/24/solid
blue='#0a5bc4'

for pair in chat:chat-bubble-left-right folder:folder feed:newspaper polls:chart-bar \
  questionnaire:clipboard-document-list map:map orders:shopping-bag site:window page:document-text; do
  key=${pair%%:*}
  icon=${pair#*:}
  paths=$(tr '\n' ' ' < "$icons/$icon.svg" | sed -e 's/<svg[^>]*>//' -e 's#</svg>##')

  # The glyph takes half the picture, so it stays clear of a round crop.
  cat > "$key.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
<rect width="256" height="256" fill="$blue"/>
<g transform="translate(64 64) scale(5.333333)" fill="#ffffff">$paths</g>
</svg>
SVG

  magick -background none "$key.svg" -strip -define png:compression-level=9 "$key.png"
  rm "$key.svg"
done
