# Project-wide Nim configuration.
switch("path", "$projectDir/src")
switch("styleCheck", "hint")
when defined(release):
  switch("opt", "speed")
