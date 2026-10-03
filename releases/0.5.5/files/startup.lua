local ok = shell.run("/atlasos/boot.lua")
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  print("AtlasOS boot failed. CraftOS recovery shell active.")
end
