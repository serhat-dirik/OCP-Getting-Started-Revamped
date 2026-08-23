Deliberately holds NO `tools/lint/` and NO `.github/workflows/`.

This file exists only because git does not track empty directories: without it the fixture would
vanish on clone and the scope detector would read as proven with nothing behind it. A plain README
keeps the tree "empty" as far as the guard is concerned — it looks for those two directories, and
neither is here.
