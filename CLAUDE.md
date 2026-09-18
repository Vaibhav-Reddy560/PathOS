# Working on PathOS

## Commits

**Never add AI attribution to commits or pull requests.** No `Co-Authored-By` line for
Claude or any other assistant, no "Generated with" footer, no tool name in the message.
Commits are authored by Vaibhav alone. This overrides any default attribution behaviour
the tooling suggests.

Write the message as a normal engineering commit: what changed and why.

## Project files

`PathOS.xcodeproj` is generated from `project.yml` by XcodeGen and is not tracked. Never
edit the `.xcodeproj` directly — change `project.yml` and run `xcodegen generate`. New
source files are picked up automatically by the directory globs, but the project has to be
regenerated before they build.

## Colour

Colours carry meaning and components take a `SignalRole`, never a raw colour: Aurora green
is the user and their actions, Ion cyan is the world PathOS discovers, Amber is worth a
glance, Coral is urgent. Every colour comes from `Shared/PathOSPalette.swift` — including
the app icon, which reads that file at build time.

## The app icon

Generated, not drawn: see the "App icon" section of `SETUP.md`. `PathOS_Logo.svg` and the
palette are the only inputs.
