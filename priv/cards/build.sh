#!/bin/sh
# Remakes the parts of a card picture. Needs rsvg-convert and ImageMagick, as in
# the release image. base.svg and mark.svg hold the mark from layouts.ex and the
# waves from home.html.heex, so run this after changing either of those.
set -e

rsvg-convert base.svg -o base.png
rsvg-convert -w 240 -h 240 mark.svg -o mark.png

magick -size 170x46 xc:none \
  '(' mark.png -resize 46x46 ')' -gravity west -geometry +0+0 -composite \
  -font Comfortaa-Bold.ttf -pointsize 30 -fill white -gravity west -annotate +56+0 potok \
  -strip lockup.png

magick -size 150x56 xc:none -fill '#0a47a3cc' -draw 'roundrectangle 0,0 149,55 28,28' \
  '(' mark.png -resize 32x32 ')' -gravity west -geometry +14+0 -composite \
  -font Comfortaa-Bold.ttf -pointsize 22 -fill white -gravity west -annotate +54+0 potok \
  -strip pill.png

magick base.png -strip -define png:compression-level=9 base.png
magick mark.png -strip -define png:compression-level=9 mark.png
